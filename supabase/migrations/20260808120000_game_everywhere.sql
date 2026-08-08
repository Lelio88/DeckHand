-- 023 — Le jeu choisi traverse toute l'application.
--
-- La migration précédente n'a rendu que la recherche consciente du jeu, parce
-- que c'était le seul changement qui ne pouvait pas attendre : sans lui, ingérer
-- Riftbound polluait la saisie Magic dès la première frappe. Les autres
-- fonctions suivent maintenant, sans quoi choisir Riftbound afficherait une
-- collection Magic.
--
-- * **`magic` par défaut partout.** Une application qui n'envoie pas encore le
--   paramètre garde exactement son comportement.
--
-- * **`DROP` puis `CREATE`.** Chaque signature change ; un remplacement créerait
--   une surcharge, et PostgREST répondrait HTTP 300 sur *tous* les appels, y
--   compris ceux d'une version déjà installée.
--
-- * **`decks.game`** manquait : le corpus était implicitement Magic. La colonne
--   permet à `deck_suggestions` de ne proposer que les decks du jeu courant.
--
-- * **`search_cards` rend désormais une illustration.** Quatre-vingts noms
--   Riftbound sont portés par plusieurs cartes distinctes, et le type ne les
--   départage jamais — mesuré, 0 sur 80. Leurs illustrations, elles, diffèrent
--   toutes : une vignette suffit donc à les distinguer, là où le nom seul
--   affichait deux lignes identiques.

BEGIN;

ALTER TABLE public.decks
    ADD COLUMN IF NOT EXISTS game text NOT NULL DEFAULT 'magic';

ALTER TABLE public.decks DROP CONSTRAINT IF EXISTS decks_game_known;
ALTER TABLE public.decks
    ADD CONSTRAINT decks_game_known CHECK (game IN ('magic', 'riftbound'));

COMMENT ON COLUMN public.decks.game IS
    'Jeu du deck. Un deck ne se construit qu''avec les cartes de son jeu.';

DROP FUNCTION IF EXISTS public.search_cards(text, integer, text);
DROP FUNCTION IF EXISTS public.my_collection(text, text, integer, integer);
DROP FUNCTION IF EXISTS public.my_collection_summary();
DROP FUNCTION IF EXISTS public.deck_suggestions(text, integer, integer, numeric, text);

CREATE FUNCTION public.search_cards(q text, max_results integer DEFAULT 20, p_game text DEFAULT 'magic'::text)
 RETURNS TABLE(oracle_id uuid, name text, matched_name text, matched_lang text, type_line text, mana_cost text, price_eur numeric, legal_pauper boolean, legal_modern boolean, legal_commander boolean, score real, owned integer, art_url text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
    WITH needle AS (
        SELECT public.normalize_card_name(q) AS n
    ),
    matches AS (
        SELECT s.oracle_id,
               s.name AS matched_name,
               s.lang AS matched_lang,
               GREATEST(
                   similarity(s.normalized, (SELECT n FROM needle)),
                   CASE
                       WHEN s.normalized = (SELECT n FROM needle) THEN 1.0
                       WHEN s.normalized LIKE (SELECT n FROM needle) || ' %'
                           THEN 0.85 + 0.13 * (
                               length((SELECT n FROM needle))::real
                               / GREATEST(length(s.normalized), 1)
                           )
                       WHEN s.normalized LIKE (SELECT n FROM needle) || '%'
                           THEN 0.70 + 0.14 * (
                               length((SELECT n FROM needle))::real
                               / GREATEST(length(s.normalized), 1)
                           )
                       ELSE 0
                   END
               )::real AS score
        FROM public.card_search_names s
        WHERE (SELECT n FROM needle) <> ''
          AND (s.normalized % (SELECT n FROM needle)
               OR s.normalized LIKE (SELECT n FROM needle) || '%')
    ),
    best AS (
        SELECT DISTINCT ON (m.oracle_id) m.*
        FROM matches m
        ORDER BY m.oracle_id, m.score DESC
    ),
    mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    )
    SELECT c.oracle_id,
           c.name,
           b.matched_name,
           b.matched_lang,
           c.type_line,
           c.mana_cost,
           p.price_eur,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           b.score,
           -- Zéro plutôt que NULL pour un visiteur non connecté : la recherche
           -- reste publique, et « possédé : 0 » est la vérité pour lui.
           COALESCE(m.owned, 0),
           (SELECT pr.art_crop_url
            FROM public.card_prints pr
            WHERE pr.oracle_id = c.oracle_id AND pr.art_crop_url IS NOT NULL
            ORDER BY (pr.lang = 'en') DESC, pr.released_at NULLS LAST, pr.scryfall_id
            LIMIT 1)
    FROM best b
    -- Le cloisonnement se fait ici plutôt que dans `matches` : la table des noms
    -- indexés ne porte pas le jeu, et l'y ajouter obligerait à la reconstruire
    -- entièrement pour un gain nul à cette échelle.
    JOIN public.cards c ON c.oracle_id = b.oracle_id AND c.game = p_game
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = b.oracle_id
    LEFT JOIN mine m ON m.oracle_id = b.oracle_id
    ORDER BY b.score DESC, length(c.name), c.name
    LIMIT GREATEST(1, LEAST(max_results, 50));
$function$;

CREATE FUNCTION public.my_collection(p_query text DEFAULT NULL::text, p_sort text DEFAULT 'name'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_game text DEFAULT 'magic'::text)
 RETURNS TABLE(oracle_id uuid, print_id uuid, is_foil boolean, name text, printed_name text, type_line text, set_code text, set_name text, collector_number text, quantity integer, unit_price_eur numeric, line_price_eur numeric, legal_pauper boolean, legal_modern boolean, legal_commander boolean, added_at timestamp with time zone)
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
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    priced AS (
        SELECT m.*,
               -- Édition précisée : son prix dans la finition possédée. Sinon le
               -- moins cher connu — l'exemplaire n'étant pas identifié, mieux
               -- vaut sous-estimer que d'inventer.
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur
               ) AS unit_price,
               pr.set_code,
               pr.set_name,
               pr.collector_number,
               COALESCE(pr.printed_name, fr.name) AS shown_name
        FROM mine m
        LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
        LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id
        LEFT JOIN LATERAL (
            SELECT s.name
            FROM public.card_search_names s
            WHERE s.oracle_id = m.oracle_id AND s.lang = 'fr'
            LIMIT 1
        ) fr ON true
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
        CASE WHEN p_sort = 'price'    THEN p.unit_price * p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' THEN p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   THEN p.added_at END DESC NULLS LAST,
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST,
        p.is_foil
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$function$;

CREATE FUNCTION public.my_collection_summary(p_game text DEFAULT 'magic'::text)
 RETURNS TABLE(total_cards integer, distinct_cards integer, total_value_eur numeric, unspecified_prints integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH mine AS (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    )
    SELECT COALESCE(SUM(m.quantity), 0)::integer,
           COUNT(DISTINCT m.oracle_id)::integer,
           COALESCE(SUM(m.quantity * COALESCE(
               public.print_price(m.print_id, m.is_foil),
               cheap.price_eur,
               0
           )), 0),
           COALESCE(SUM(m.quantity) FILTER (WHERE m.print_id IS NULL), 0)::integer
    FROM mine m
    LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id;
$function$;

CREATE FUNCTION public.deck_suggestions(p_format text, p_max_missing integer DEFAULT 100, p_max_results integer DEFAULT 30, p_max_cost numeric DEFAULT NULL::numeric, p_tier text DEFAULT NULL::text, p_game text DEFAULT 'magic'::text)
 RETURNS TABLE(deck_id uuid, deck_name text, tier text, source_id text, source_name text, attribution text, total_cards integer, owned_cards integer, missing_cards integer, completion real, missing_cost_eur numeric)
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
        SELECT dc.deck_id,
               dc.oracle_id,
               SUM(dc.quantity)::integer AS needed
        FROM public.deck_cards dc
        JOIN public.decks d ON d.id = dc.deck_id
        WHERE d.format = p_format
          AND d.game = p_game
          AND dc.board = 'main'
          AND (p_tier IS NULL OR d.tier = p_tier)
        GROUP BY dc.deck_id, dc.oracle_id
    ),
    gaps AS (
        SELECT n.deck_id,
               n.oracle_id,
               n.needed,
               GREATEST(n.needed - COALESCE(m.owned, 0), 0) AS missing
        FROM needs n
        LEFT JOIN mine m ON m.oracle_id = n.oracle_id
    ),
    totals AS (
        SELECT g.deck_id,
               SUM(g.needed)::integer                      AS total_cards,
               SUM(g.needed - g.missing)::integer          AS owned_cards,
               SUM(g.missing)::integer                     AS missing_cards,
               SUM(g.missing * COALESCE(p.price_eur, 0))   AS missing_cost_eur
        FROM gaps g
        LEFT JOIN public.card_cheapest_price p ON p.oracle_id = g.oracle_id
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
           t.missing_cost_eur
    FROM totals t
    JOIN public.decks d ON d.id = t.deck_id
    JOIN public.deck_sources s ON s.id = d.source_id
    WHERE t.missing_cards <= p_max_missing
      AND (p_max_cost IS NULL OR t.missing_cost_eur <= p_max_cost)
    ORDER BY t.missing_cards, t.missing_cost_eur, d.name
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$function$;
GRANT EXECUTE ON FUNCTION public.search_cards(text, integer, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection(text, text, integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection_summary(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text) TO anon, authenticated;

COMMIT;
