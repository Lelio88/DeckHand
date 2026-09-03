-- Les six dernières lectrices du prix passent à la latérale
--
-- Suite de `20260903150000_cheapest_price_lateral.sql`, qui n'avait touché que
-- les trois fonctions de recherche. Les six autres avaient été laissées de côté
-- par prudence : elles portent sur des collections et des corpus de decks, et
-- l'agrégat complet de `card_cheapest_price` pouvait y être le bon plan.
--
-- **Mesuré, c'est faux : la latérale gagne partout, et largement.** Ces
-- fonctions paginent ou plafonnent, et ne rendent en réalité que quelques
-- dizaines de lignes — cinquante pour une page de collection, trente pour des
-- suggestions de decks. L'agrégat, lui, coûte le catalogue entier quel que
-- soit ce qu'on en garde.
--
-- Joué sous le rôle `authenticated`, avec l'identité du propriétaire, médiane
-- et pire des trois essais :
--
--   fonction                 actuel              latérale
--   my_collection            0,414 s / 6,187 s   0,062 s / 0,291 s
--   my_collection_summary    0,547 s / 0,829 s   0,117 s / 0,120 s
--   my_buildable_cards       0,351 s / 0,361 s   0,033 s / 0,035 s
--   my_unsorted_pile         0,128 s / 0,146 s   0,019 s / 0,019 s
--   deck_suggestions         3,952 s / 5,260 s   0,667 s / 1,541 s
--   deck_missing_cards       0,485 s / 0,667 s   0,031 s / 0,056 s
--
-- **Deux chiffres expliquent des pannes réelles.** `my_collection` a touché
-- 6,187 s : c'est l'écran de collection, ouvert plusieurs fois par séance, à un
-- cheveu des huit secondes du rôle. Et `deck_suggestions` tient une médiane de
-- 3,95 s — les deux tiers du plafond en marche normale, sans rien de
-- particulier.
--
-- La vue reste en place. Plus aucune fonction ne la lit, mais c'est une
-- surface publique : la retirer serait un changement d'API, pas une
-- optimisation, et elle ne coûte rien tant que personne ne l'interroge.

BEGIN;

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
            WHERE s.oracle_id = m.oracle_id AND s.lang = 'fr'
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

CREATE OR REPLACE FUNCTION public.my_collection_summary(p_game text DEFAULT 'magic'::text)
 RETURNS TABLE(total_cards integer, distinct_cards integer, total_value_eur numeric, unspecified_prints integer, unique_value_eur numeric, top_card_name text, top_card_eur numeric, distinct_sets integer, best_set_name text, best_set_owned integer, best_set_total integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH mine AS MATERIALIZED (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    cotee AS MATERIALIZED (
        SELECT m.oracle_id,
               m.print_id,
               m.quantity,
               pr.set_code,
               pr.collector_number,
               -- Le type d'extension descend jusqu'ici pour que le COMPTE et le
               -- MEILLEUR classeur partagent exactement le meme critere.
               COALESCE(cs.set_type, '') = 'token' AS est_jeton,
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur,
                   0
               ) AS unite,
               -- La même clé de référence que `distinct_cards`, pour que « une
               -- de chaque » compte exactement les lignes que ce nombre annonce.
               m.oracle_id::text || ':' ||
               COALESCE(
                   pr.set_code || '#' || COALESCE(pr.collector_number, ''),
                   ''
               ) AS reference
        FROM mine m
        LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
        LEFT JOIN public.card_sets cs ON cs.code = pr.set_code
        -- Le prix le moins cher, calculé pour les cartes retenues et pour elles
    -- seules — voir la migration 20260903150000 et `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur,
               min(pr.price_usd) AS price_usd
        FROM public.card_prints pr
        WHERE pr.oracle_id = m.oracle_id
    ) cheap ON true
    ),
    totaux AS (
        SELECT COALESCE(SUM(quantity), 0)::integer AS total_cards,
               COUNT(DISTINCT reference)::integer AS distinct_cards,
               COALESCE(SUM(quantity * unite), 0) AS total_value,
               COALESCE(SUM(quantity) FILTER (WHERE print_id IS NULL), 0)::integer
                   AS unspecified,
               -- Les cartes sans édition précisée n'appartiennent a aucune
               -- extension : `set_code` y est NULL, et COUNT l'ignore — ce qui
               -- est exactement le comportement voulu.
               (COUNT(DISTINCT set_code)
                    FILTER (WHERE NOT est_jeton))::integer AS distinct_sets
        FROM cotee
    ),
    -- Une référence peut exister en plusieurs lignes — ordinaire et brillante.
    -- « Une de chaque » retient la plus chère : c'est celle qu'on garderait.
    une_de_chaque AS (
        SELECT COALESCE(SUM(unite), 0) AS valeur
        FROM (SELECT reference, MAX(unite) AS unite FROM cotee GROUP BY reference) r
    ),
    -- Trier d'abord, nommer ensuite : joindre `cards` avant le tri joindrait
    -- toute la collection pour n'en garder qu'une ligne.
    plus_chere AS (
        SELECT oracle_id, unite FROM cotee ORDER BY unite DESC LIMIT 1
    ),
    -- Cases occupees par extension. Une case est le couple (extension, numero),
    -- comme au classeur : deux langues d'une meme carte n'en font qu'une.
    par_set AS (
        SELECT set_code, COUNT(DISTINCT collector_number)::integer AS occupees
        FROM cotee
        WHERE set_code IS NOT NULL
          AND NOT est_jeton
        GROUP BY set_code
    ),
    tailles AS (
        SELECT p.set_code,
               MIN(p.set_name) AS set_name,
               COUNT(DISTINCT p.collector_number)::integer AS total
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT set_code FROM par_set)
        GROUP BY p.set_code
    ),
    meilleur AS (
        SELECT t.set_name, s.occupees, t.total
        FROM par_set s
        JOIN tailles t ON t.set_code = s.set_code
        WHERE t.total > 0
        -- Le taux d'abord ; a taux egal, la plus grosse extension, qui est le
        -- plus bel accomplissement des deux.
        ORDER BY s.occupees::numeric / t.total DESC, t.total DESC
        LIMIT 1
    )
    SELECT t.total_cards,
           t.distinct_cards,
           t.total_value,
           t.unspecified,
           u.valeur,
           (SELECT ca.name FROM public.cards ca
             WHERE ca.oracle_id = (SELECT oracle_id FROM plus_chere)),
           COALESCE((SELECT unite FROM plus_chere), 0),
           t.distinct_sets,
           (SELECT set_name FROM meilleur),
           COALESCE((SELECT occupees FROM meilleur), 0),
           COALESCE((SELECT total FROM meilleur), 0)
    FROM totaux t, une_de_chaque u;
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
        WHERE s.oracle_id = c.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE (p_format = 'commander' AND c.legal_commander)
       OR (p_format = 'pauper'    AND c.legal_pauper)
       OR (p_format = 'modern'    AND c.legal_modern)
    ORDER BY COALESCE(fr.name, c.name);
$function$;

CREATE OR REPLACE FUNCTION public.my_unsorted_pile(p_game text DEFAULT 'magic'::text, p_page integer DEFAULT 1, p_per_page integer DEFAULT 9)
 RETURNS TABLE(oracle_id uuid, name text, printed_name text, art_crop_url text, price_eur numeric, owned integer, has_foil boolean, added_at timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH mine AS (
        SELECT i.oracle_id,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
          AND i.print_id IS NULL
        GROUP BY i.oracle_id
    ),
    -- Une impression représentative, seulement pour l'image et le nom imprimé.
    shown AS (
        SELECT DISTINCT ON (p.oracle_id)
               p.oracle_id, p.printed_name, p.art_crop_url
        FROM public.card_prints p
        JOIN mine m ON m.oracle_id = p.oracle_id
        ORDER BY p.oracle_id, (p.lang = 'fr') DESC, p.released_at DESC NULLS LAST
    )
    SELECT m.oracle_id,
           c.name,
           s.printed_name,
           s.art_crop_url,
           cheap.price_eur,
           m.copies,
           m.foil,
           m.added_at
    FROM mine m
    JOIN public.cards c ON c.oracle_id = m.oracle_id
    LEFT JOIN shown s ON s.oracle_id = m.oracle_id
    -- Le prix le moins cher, calculé pour les cartes retenues et pour elles
    -- seules — voir la migration 20260903150000 et `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur,
               min(pr.price_usd) AS price_usd
        FROM public.card_prints pr
        WHERE pr.oracle_id = m.oracle_id
    ) cheap ON true
    ORDER BY m.added_at DESC NULLS LAST, c.name
    LIMIT GREATEST(1, LEAST(p_per_page, 60))
    OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60));
$function$;

CREATE OR REPLACE FUNCTION public.deck_suggestions(p_format text, p_max_missing integer DEFAULT 100, p_max_results integer DEFAULT 30, p_max_cost numeric DEFAULT NULL::numeric, p_tier text DEFAULT NULL::text, p_game text DEFAULT 'magic'::text, p_colors text[] DEFAULT NULL::text[], p_banned_colors text[] DEFAULT NULL::text[], p_commander text DEFAULT NULL::text, p_owned_commander boolean DEFAULT false)
 RETURNS TABLE(deck_id uuid, deck_name text, tier text, source_id text, source_name text, attribution text, total_cards integer, owned_cards integer, missing_cards integer, completion real, missing_cost_eur numeric, colors text[], commander_oracle_id uuid, commander_name text, commander_owned boolean, basic_lands integer)
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
    chosen AS (
        SELECT d.id
        FROM public.decks d
        WHERE d.format = p_format
          AND d.game = p_game
          AND (p_tier IS NULL OR d.tier = p_tier)
          AND ((SELECT n FROM wanted) = ''
               OR EXISTS (
                    SELECT 1 FROM public.card_search_names s
                    WHERE s.oracle_id = d.commander_oracle_id
                      AND s.normalized LIKE '%' || (SELECT n FROM wanted) || '%'
               ))
          AND (NOT p_owned_commander
               OR EXISTS (
                    SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id
               ))
    ),
    entries AS (
        SELECT dc.deck_id,
               dc.oracle_id,
               SUM(dc.quantity)::integer AS needed,
               -- « Basic Land — Plains », « Basic Snow Land — Island ». Ni les
               -- terrains légendaires, ni les bicolores, qui eux s'achètent.
               bool_or(c.type_line LIKE 'Basic Land%') AS is_basic
        FROM public.deck_cards dc
        JOIN chosen ON chosen.id = dc.deck_id
        JOIN public.cards c ON c.oracle_id = dc.oracle_id
        WHERE dc.board = 'main'
        GROUP BY dc.deck_id, dc.oracle_id
    ),
    basics AS (
        SELECT e.deck_id, COALESCE(SUM(e.needed) FILTER (WHERE e.is_basic), 0)::integer AS basic_lands
        FROM entries e
        GROUP BY e.deck_id
    ),
    -- L'identité couleur se lit sur le deck entier, terrains compris : un deck
    -- qui ne contient de rouge que dans ses Montagnes reste un deck rouge.
    deck_colors AS (
        SELECT e.deck_id,
               COALESCE(
                   array_agg(DISTINCT ci ORDER BY ci) FILTER (WHERE ci IS NOT NULL),
                   ARRAY[]::text[]
               ) AS colors
        FROM entries e
        JOIN public.cards c ON c.oracle_id = e.oracle_id
        LEFT JOIN LATERAL unnest(c.color_identity) AS ci ON true
        GROUP BY e.deck_id
    ),
    gaps AS (
        SELECT e.deck_id,
               e.oracle_id,
               e.needed,
               GREATEST(e.needed - COALESCE(m.owned, 0), 0) AS missing
        FROM entries e
        LEFT JOIN mine m ON m.oracle_id = e.oracle_id
        WHERE NOT e.is_basic
    ),
    totals AS (
        SELECT g.deck_id,
               SUM(g.needed)::integer                      AS total_cards,
               SUM(g.needed - g.missing)::integer          AS owned_cards,
               SUM(g.missing)::integer                     AS missing_cards,
               SUM(g.missing * COALESCE(p.price_eur, 0))   AS missing_cost_eur
        FROM gaps g
        -- Le prix le moins cher, calculé pour les cartes retenues et pour elles
    -- seules — voir la migration 20260903150000 et `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur,
               min(pr.price_usd) AS price_usd
        FROM public.card_prints pr
        WHERE pr.oracle_id = g.oracle_id
    ) p ON true
        GROUP BY g.deck_id
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
           dc.colors,
           d.commander_oracle_id,
           COALESCE(fr.name, cmd.name),
           d.commander_oracle_id IS NOT NULL
               AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id),
           b.basic_lands
    FROM totals t
    JOIN public.decks d ON d.id = t.deck_id
    JOIN public.deck_sources s ON s.id = d.source_id
    JOIN deck_colors dc ON dc.deck_id = t.deck_id
    JOIN basics b ON b.deck_id = t.deck_id
    LEFT JOIN public.cards cmd ON cmd.oracle_id = d.commander_oracle_id
    LEFT JOIN LATERAL (
        SELECT sn.name
        FROM public.card_search_names sn
        WHERE sn.oracle_id = d.commander_oracle_id AND sn.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE t.missing_cards <= p_max_missing
      AND (p_max_cost IS NULL OR t.missing_cost_eur <= p_max_cost)
      -- **Voulues** : le deck doit porter toutes ces couleurs. C'est
      -- l'inverse de l'ancien filtre, qui demandait que le deck n'en porte
      -- aucune autre — « je veux du rouge » excluait alors tous les bicolores
      -- rouges, ce que personne ne demande en cochant le rouge.
      AND (p_colors IS NULL OR cardinality(p_colors) = 0
           OR p_colors <@ dc.colors)
      -- **Bannies** : le deck ne doit porter aucune de ces couleurs. Deux
      -- listes valent mieux qu'une : « du rouge, mais pas de bleu » ne
      -- s'exprime pas avec un seul ensemble.
      AND (p_banned_colors IS NULL OR cardinality(p_banned_colors) = 0
           OR NOT (dc.colors && p_banned_colors))
    ORDER BY (d.commander_oracle_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id)) DESC,
             t.missing_cards,
             t.missing_cost_eur,
             d.name
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
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
        WHERE s.oracle_id = n.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    -- Ce qui manque d'abord, du plus cher au moins cher — c'est la liste de
    -- courses. Ce qu'on possède ferme la marche, par ordre alphabétique : on n'y
    -- cherche pas un prix, on vérifie une présence.
    ORDER BY (n.needed > COALESCE(m.owned, 0)) DESC,
             (GREATEST(n.needed - COALESCE(m.owned, 0), 0) * COALESCE(p.price_eur, 0)) DESC,
             COALESCE(fr.name, c.name);
$function$;

COMMIT;
