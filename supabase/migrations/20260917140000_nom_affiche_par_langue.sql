-- Le nom traduit suit une préférence, au lieu d'être français en dur
--
-- **Cinq fonctions décidaient pour l'utilisateur.** `cards_by_oracle_ids`,
-- `deck_missing_cards`, `deck_suggestions`, `my_buildable_cards` et
-- `my_collection` cherchaient toutes le nom traduit par `s.lang = 'fr'`.
-- Tant que l'application est privée et francophone, c'est juste ; pour une
-- application ouverte, c'est un choix imposé à qui ne lit pas le français.
--
-- **Cinq autres fonctions portent `lang = 'fr'` et ne sont pas touchées.**
-- `my_binder_page`, `my_binder_find`, `my_unsorted_pile`,
-- `public_binder_page` et `public_spotlight` écrivent
-- `ORDER BY (p.lang = 'fr') DESC` sur `card_prints` : elles choisissent
-- **quelle impression** montrer, pas quel nom. Confondre les deux motifs
-- changerait l'édition affichée dans un classeur, ce qui n'a rien à voir avec
-- la langue de lecture. Les corps ci-dessous ont été relus un par un.
--
-- **La préférence plutôt qu'un paramètre.** Ajouter `p_lang` aux cinq
-- signatures aurait obligé PostgREST et l'application à suivre, pour une valeur
-- qui ne change pas d'un appel à l'autre. Une colonne sur `profiles` et une
-- fonction qui la lit laissent les signatures intactes : rien à redéployer
-- côté client, et la préférence vaut pour tous les écrans à la fois.
--
-- **`(SELECT …)` et non l'appel direct.** Écrire `s.lang = my_display_lang()`
-- dans une latérale exposerait la fonction à un appel par ligne. Enveloppée
-- dans un sous-select sans corrélation, elle devient un InitPlan : évaluée une
-- fois par requête.
--
-- **Le repli reste `fr`**, donc rien ne bouge pour les comptes existants :
-- la colonne naît vide et `COALESCE` rend le comportement d'avant. C'est à
-- l'application de la renseigner, au premier lancement, depuis la langue de
-- l'appareil.

BEGIN;

ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS display_lang text;

COMMENT ON COLUMN public.profiles.display_lang IS
    'Langue dans laquelle afficher le nom des cartes. NULL vaut « fr », le '
    'comportement historique. Doit être un code de card_search_names.lang.';

-- Lue par les fonctions d'affichage, jamais par l'application directement.
--
-- `STABLE` et non `IMMUTABLE` : elle dépend de `auth.uid()` et d'une ligne
-- qui peut changer. Pas de `SECURITY DEFINER` : la RLS de `profiles` laisse
-- déjà chacun lire la sienne, et un `DEFINER` ouvrirait la table entière pour
-- un besoin qui n'en a pas.
--
-- Un visiteur anonyme — page publique d'une collection partagée — n'a pas de
-- profil : il reçoit le repli, comme avant.
CREATE OR REPLACE FUNCTION public.my_display_lang()
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    SELECT COALESCE(
        (SELECT p.display_lang FROM public.profiles p WHERE p.user_id = auth.uid()),
        'fr'
    );
$function$;

COMMENT ON FUNCTION public.my_display_lang() IS
    'Langue d''affichage du lecteur courant, « fr » à défaut. Enveloppez '
    'l''appel dans (SELECT …) pour qu''il soit évalué une fois par requête.';

GRANT EXECUTE ON FUNCTION public.my_display_lang() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.cards_by_oracle_ids(p_ids uuid[], p_prints uuid[] DEFAULT NULL::uuid[])
 RETURNS TABLE(oracle_id uuid, name text, printed_name text, type_line text, price_eur numeric, legal_pauper boolean, legal_modern boolean, legal_commander boolean, art_url text, owned integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    SELECT c.oracle_id,
           c.name,
           fr.name,
           c.type_line,
           p.price_eur,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           -- L'illustration reconnue d'abord ; à défaut, celle d'origine.
           -- Le repli compte : `p_prints` est absent des appels qui ne viennent
           -- pas d'un scan (une liste de decks, un classeur), et une impression
           -- peut n'avoir aucune illustration servie.
           COALESCE(
               (SELECT pr.art_crop_url
                FROM public.card_prints pr
                WHERE pr.scryfall_id = requested.print_id
                  AND pr.art_crop_url IS NOT NULL),
               (SELECT pr.art_crop_url
                FROM public.card_prints pr
                WHERE pr.oracle_id = c.oracle_id AND pr.art_crop_url IS NOT NULL
                ORDER BY (pr.lang = 'en') DESC, pr.released_at NULLS LAST,
                         pr.scryfall_id
                LIMIT 1)
           ),
           COALESCE(m.owned, 0)
    FROM unnest(
             p_ids,
             COALESCE(
                 p_prints,
                 array_fill(NULL::uuid, ARRAY[coalesce(cardinality(p_ids), 0)])
             )
         ) WITH ORDINALITY AS requested(id, print_id, position)
    JOIN public.cards c ON c.oracle_id = requested.id
    -- Le prix le moins cher, calculé pour les cartes trouvées et pour elles
    -- seules. La vue `card_cheapest_price` agrège `GROUP BY oracle_id` ;
    -- Postgres ne pousse pas le filtre à travers cet agrégat et la calcule
    -- pour tout le catalogue avant de joindre. Mesuré : 5,457 s sur dix noms
    -- là où la médiane est 0,522 s — une bascule de plan, donc un timeout
    -- qui frappe au hasard. Voir `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur
        FROM public.card_prints pr
        WHERE pr.oracle_id = c.oracle_id
    ) p ON true
    LEFT JOIN public.owned_by_oracle(p_ids) m ON m.oracle_id = c.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = (SELECT public.my_display_lang())
        LIMIT 1
    ) fr ON true
    ORDER BY requested.position;
$function$;

CREATE OR REPLACE FUNCTION public.deck_missing_cards(p_deck_id uuid)
 RETURNS TABLE(oracle_id uuid, name text, printed_name text, needed integer, owned integer, missing integer, unit_price_eur numeric, line_cost_eur numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    ),
    needs AS (
        SELECT dc.oracle_id, SUM(dc.quantity)::integer AS needed
        FROM public.deck_cards dc
        WHERE dc.deck_id = p_deck_id AND dc.board = 'main'
        GROUP BY dc.oracle_id
    )
    SELECT c.oracle_id,
           c.name,
           fr.name,
           n.needed,
           COALESCE(m.owned, 0),
           GREATEST(n.needed - COALESCE(m.owned, 0), 0),
           p.price_eur,
           GREATEST(n.needed - COALESCE(m.owned, 0), 0) * COALESCE(p.price_eur, 0)
    FROM needs n
    JOIN public.cards c ON c.oracle_id = n.oracle_id
    LEFT JOIN mine m ON m.oracle_id = n.oracle_id
    -- Le prix le moins cher, calculé pour les cartes retenues et pour elles
    -- seules — voir la migration 20260903150000 et `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur,
               min(pr.price_usd) AS price_usd
        FROM public.card_prints pr
        WHERE pr.oracle_id = n.oracle_id
    ) p ON true
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = n.oracle_id AND s.lang = (SELECT public.my_display_lang())
        LIMIT 1
    ) fr ON true
    -- Ce qui manque d'abord, du plus cher au moins cher — c'est la liste de
    -- courses. Ce qu'on possède ferme la marche, par ordre alphabétique : on n'y
    -- cherche pas un prix, on vérifie une présence.
    ORDER BY (n.needed > COALESCE(m.owned, 0)) DESC,
             (GREATEST(n.needed - COALESCE(m.owned, 0), 0) * COALESCE(p.price_eur, 0)) DESC,
             COALESCE(fr.name, c.name);
$function$;

CREATE OR REPLACE FUNCTION public.deck_suggestions(p_format text, p_max_missing integer DEFAULT 100, p_max_results integer DEFAULT 30, p_max_cost numeric DEFAULT NULL::numeric, p_tier text DEFAULT NULL::text, p_game text DEFAULT 'magic'::text, p_colors text[] DEFAULT NULL::text[], p_banned_colors text[] DEFAULT NULL::text[], p_commander text DEFAULT NULL::text, p_owned_commander boolean DEFAULT false)
 RETURNS TABLE(deck_id uuid, deck_name text, tier text, source_id text, source_name text, attribution text, total_cards integer, owned_cards integer, missing_cards integer, completion real, missing_cost_eur numeric, colors text[], commander_oracle_id uuid, commander_name text, commander_owned boolean, basic_lands integer, unpriced_cards integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH wanted AS (
        SELECT public.normalize_card_name(COALESCE(p_commander, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    ),
    -- Ce qu'on possède déjà dans chaque deck : en nombre, et en valeur.
    -- Part de la collection, pas du corpus — seuls les decks contenant au moins
    -- une carte possédée sont touchés.
    owned AS (
        SELECT n.deck_id,
               SUM(LEAST(n.needed, m.owned))::integer                     AS owned_cards,
               SUM(LEAST(n.needed, m.owned) * n.unit_price_eur)           AS owned_cost_eur
        FROM mine m
        JOIN public.deck_needs n
          ON n.oracle_id = m.oracle_id AND NOT n.is_basic
        GROUP BY n.deck_id
    ),
    candidates AS (
        SELECT p.deck_id,
               p.total_cards,
               p.basic_lands,
               p.colors,
               p.unpriced_cards,
               COALESCE(o.owned_cards, 0)                                 AS owned_cards,
               p.total_cards - COALESCE(o.owned_cards, 0)                 AS missing_cards,
               p.total_cost_eur - COALESCE(o.owned_cost_eur, 0)           AS missing_cost_eur
        FROM public.deck_profile p
        LEFT JOIN owned o ON o.deck_id = p.deck_id
        WHERE p.game = p_game
          AND p.format = p_format
          AND p.total_cards > 0
    )
    SELECT d.id,
           d.name,
           d.tier,
           d.source_id,
           s.display_name,
           s.attribution_text,
           t.total_cards,
           t.owned_cards,
           t.missing_cards,
           (t.owned_cards::real / NULLIF(t.total_cards, 0))::real,
           t.missing_cost_eur,
           t.colors,
           d.commander_oracle_id,
           COALESCE(fr.name, cmd.name),
           d.commander_oracle_id IS NOT NULL
               AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id),
           t.basic_lands,
           t.unpriced_cards
    FROM candidates t
    JOIN public.decks d ON d.id = t.deck_id
    JOIN public.deck_sources s ON s.id = d.source_id
    LEFT JOIN public.cards cmd ON cmd.oracle_id = d.commander_oracle_id
    LEFT JOIN LATERAL (
        SELECT sn.name
        FROM public.card_search_names sn
        WHERE sn.oracle_id = d.commander_oracle_id AND sn.lang = (SELECT public.my_display_lang())
        LIMIT 1
    ) fr ON true
    WHERE t.missing_cards <= p_max_missing
      AND (p_max_cost IS NULL OR t.missing_cost_eur <= p_max_cost)
      AND (p_tier IS NULL OR d.tier = p_tier)
      AND ((SELECT n FROM wanted) = ''
           OR EXISTS (
                SELECT 1 FROM public.card_search_names s2
                WHERE s2.oracle_id = d.commander_oracle_id
                  AND s2.normalized LIKE '%' || (SELECT n FROM wanted) || '%'
           ))
      AND (NOT p_owned_commander
           OR EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id))
      AND (p_colors IS NULL OR cardinality(p_colors) = 0
           OR p_colors <@ t.colors)
      AND (p_banned_colors IS NULL OR cardinality(p_banned_colors) = 0
           OR NOT (t.colors && p_banned_colors))
    ORDER BY (d.commander_oracle_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id)) DESC,
             -- Constructibles d'abord : rien à acheter bat tout le reste.
             (t.missing_cards = 0) DESC,
             -- **Puis le coût, mais seulement s'il est entier.** Le `CASE` rend
             -- `NULL` pour un deck dont une carte n'est pas cotée, et un `NULL`
             -- se range en dernier sur un tri croissant : les decks au prix
             -- connu passent devant, par coût, les autres suivent. C'est ce qui
             -- évite qu'un deck non coté paraisse gratuit et remonte en tête.
             CASE WHEN t.unpriced_cards = 0 THEN t.missing_cost_eur END,
             -- Pour ceux dont le prix est incomplet — trois jeux entiers —
             -- c'est la complétion qui ordonne, la valeur que l'écran affiche.
             (t.owned_cards::real / NULLIF(t.total_cards, 0)) DESC,
             t.missing_cards,
             d.name,
             -- Dernier départage, sans quoi deux decks jumeaux s'échangent
             -- d'un appel à l'autre.
             d.id
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$function$;

CREATE OR REPLACE FUNCTION public.my_buildable_cards(p_format text DEFAULT 'commander'::text, p_game text DEFAULT 'magic'::text)
 RETURNS TABLE(oracle_id uuid, name text, printed_name text, type_line text, mana_cost text, cmc numeric, color_identity text[], oracle_text text, quantity integer, price_eur numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    )
    SELECT c.oracle_id,
           c.name,
           fr.name,
           c.type_line,
           c.mana_cost,
           c.cmc,
           c.color_identity,
           COALESCE(c.oracle_text, ''),
           m.quantity,
           cheap.price_eur
    FROM mine m
    JOIN public.cards c ON c.oracle_id = m.oracle_id AND c.game = p_game
    -- Le prix le moins cher, calculé pour les cartes retenues et pour elles
    -- seules — voir la migration 20260903150000 et `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur,
               min(pr.price_usd) AS price_usd
        FROM public.card_prints pr
        WHERE pr.oracle_id = c.oracle_id
    ) cheap ON true
    -- Le nom français quand il existe : c'est celui qu'on lit sur la carte qu'on
    -- ira chercher dans sa boîte.
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = (SELECT public.my_display_lang())
        LIMIT 1
    ) fr ON true
    WHERE (p_format = 'commander' AND c.legal_commander)
       OR (p_format = 'pauper'    AND c.legal_pauper)
       OR (p_format = 'modern'    AND c.legal_modern)
    ORDER BY COALESCE(fr.name, c.name);
$function$;

CREATE OR REPLACE FUNCTION public.my_collection(p_query text DEFAULT NULL::text, p_sort text DEFAULT 'name'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_game text DEFAULT 'magic'::text, p_unspecified_only boolean DEFAULT false, p_descending boolean DEFAULT false, p_finish text DEFAULT NULL::text, p_full_art boolean DEFAULT NULL::boolean)
 RETURNS TABLE(oracle_id uuid, print_id uuid, is_foil boolean, name text, printed_name text, type_line text, set_code text, set_name text, collector_number text, rarity text, full_art boolean, quantity integer, unit_price_eur numeric, line_price_eur numeric, legal_pauper boolean, legal_modern boolean, legal_commander boolean, added_at timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH needle AS (
        SELECT public.normalize_card_name(COALESCE(p_query, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
          AND (NOT p_unspecified_only OR i.print_id IS NULL)
          AND (p_finish IS NULL
               OR (p_finish = 'foil' AND i.is_foil)
               OR (p_finish = 'nonfoil' AND NOT i.is_foil))
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    priced AS (
        SELECT m.*,
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur
               ) AS unit_price,
               pr.set_code,
               pr.set_name,
               pr.collector_number,
               pr.rarity,
               pr.full_art,
               public.rarity_rank(pr.rarity) AS rarity_rank,
               NULLIF(regexp_replace(COALESCE(pr.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank,
               COALESCE(pr.printed_name, fr.name) AS shown_name
        FROM mine m
        LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
        -- Le prix le moins cher, calculé pour les cartes retenues et pour elles
    -- seules — voir la migration 20260903150000 et `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur,
               min(pr.price_usd) AS price_usd
        FROM public.card_prints pr
        WHERE pr.oracle_id = m.oracle_id
    ) cheap ON true
        LEFT JOIN LATERAL (
            SELECT s.name
            FROM public.card_search_names s
            WHERE s.oracle_id = m.oracle_id AND s.lang = (SELECT public.my_display_lang())
            LIMIT 1
        ) fr ON true
        WHERE p_full_art IS NULL
           OR COALESCE(pr.full_art, false) = p_full_art
    )
    SELECT p.oracle_id,
           p.print_id,
           p.is_foil,
           c.name,
           p.shown_name,
           c.type_line,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.rarity,
           p.full_art,
           p.quantity,
           p.unit_price,
           p.unit_price * p.quantity,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           p.added_at
    FROM priced p
    JOIN public.cards c ON c.oracle_id = p.oracle_id AND c.game = p_game
    WHERE (SELECT n FROM needle) = ''
       OR EXISTS (
            SELECT 1 FROM public.card_search_names s
            WHERE s.oracle_id = p.oracle_id
              AND s.normalized LIKE '%' || (SELECT n FROM needle) || '%'
       )
    ORDER BY
        CASE WHEN p_sort = 'price'    AND     p_descending THEN COALESCE(p.unit_price * p.quantity, 0) END DESC,
        CASE WHEN p_sort = 'price'    AND NOT p_descending THEN COALESCE(p.unit_price * p.quantity, 0) END ASC,
        CASE WHEN p_sort = 'quantity' AND     p_descending THEN p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' AND NOT p_descending THEN p.quantity END ASC  NULLS LAST,
        CASE WHEN p_sort = 'recent'   AND     p_descending THEN p.added_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   AND NOT p_descending THEN p.added_at END ASC  NULLS LAST,
        CASE WHEN p_sort = 'rarity'   AND     p_descending THEN p.rarity_rank END DESC NULLS LAST,
        CASE WHEN p_sort = 'rarity'   AND NOT p_descending THEN p.rarity_rank END ASC  NULLS LAST,
        CASE WHEN p_sort = 'name'     AND     p_descending THEN COALESCE(p.shown_name, c.name) END DESC,
        CASE WHEN p_sort = 'name'     AND NOT p_descending THEN COALESCE(p.shown_name, c.name) END ASC,
        -- **Le classeur : l'extension d'abord.** Elle désigne le volume ; le
        -- numéro, plus bas, désigne la case à l'intérieur. C'est la seule clé
        -- propre à ce tri — tout le reste lui est déjà commun.
        CASE WHEN p_sort = 'binder'   AND     p_descending THEN p.set_code END DESC NULLS LAST,
        CASE WHEN p_sort = 'binder'   AND NOT p_descending THEN p.set_code END ASC  NULLS LAST,
        -- **Le numéro départage tout le reste.** À rareté égale, à prix égal,
        -- l'ordre paraissait aléatoire à qui range une boîte, où les numéros se
        -- suivent. Il porte aussi les tris « numéro » et « classeur », dont il
        -- est la clé de rangement — d'où sa présence ici plutôt qu'au-dessus.
        CASE WHEN p_sort IN ('number', 'binder') AND p_descending THEN p.number_rank END DESC NULLS LAST,
        p.number_rank ASC NULLS LAST,
        p.collector_number ASC NULLS LAST,
        -- Dernier recours : sans lui, deux cartes du même numéro dans deux
        -- extensions pourraient changer de place d'une page à l'autre.
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST,
        p.is_foil
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$function$;

COMMIT;
