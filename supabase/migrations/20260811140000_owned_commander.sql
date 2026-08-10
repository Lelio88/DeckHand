-- 033 — Savoir si l'on possède déjà le commandant.
--
-- **C'est la première carte qu'on regarde, et la plus décisive.** Un deck
-- Commander se construit autour de son général : sans lui, les quatre-vingt-dix
-- neuf autres cartes ne forment pas un deck. Or la liste des suggestions ne
-- distinguait pas « il me manque le commandant et cinquante cartes » de « il me
-- manque cinquante cartes », alors que la première situation est d'une autre
-- nature — et que le commandant est souvent la carte la plus chère de la liste.
--
-- La sortie porte donc `commander_owned`, et `p_owned_commander` permet de
-- s'en tenir aux decks dont on tient déjà le général.
--
-- **Le filtre s'applique aussi aux formats sans commandant**, où il ne peut
-- rien rendre : c'est voulu. Il n'a pas à connaître le format, et l'interface
-- ne le propose que là où il a un sens — un filtre qui devine ce qu'on a voulu
-- dire est un filtre dont on ne sait plus ce qu'il fait.
--
-- Signature modifiée : suppression puis recréation, sous peine de surcharge
-- PostgREST (migration 012).

BEGIN;

DROP FUNCTION IF EXISTS public.deck_suggestions(
    text, integer, integer, numeric, text, text, text[], text);

CREATE FUNCTION public.deck_suggestions(
    p_format           text,
    p_max_missing      integer DEFAULT 100,
    p_max_results      integer DEFAULT 30,
    p_max_cost         numeric DEFAULT NULL,
    p_tier             text    DEFAULT NULL,
    p_game             text    DEFAULT 'magic',
    p_colors           text[]  DEFAULT NULL,
    p_commander        text    DEFAULT NULL,
    p_owned_commander  boolean DEFAULT false
)
RETURNS TABLE (
    deck_id             uuid,
    deck_name           text,
    tier                text,
    source_id           text,
    source_name         text,
    attribution         text,
    total_cards         integer,
    owned_cards         integer,
    missing_cards       integer,
    completion          real,
    missing_cost_eur    numeric,
    colors              text[],
    commander_oracle_id uuid,
    commander_name      text,
    commander_owned     boolean
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
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
    needs AS (
        SELECT dc.deck_id,
               dc.oracle_id,
               SUM(dc.quantity)::integer AS needed
        FROM public.deck_cards dc
        JOIN chosen ON chosen.id = dc.deck_id
        WHERE dc.board = 'main'
        GROUP BY dc.deck_id, dc.oracle_id
    ),
    deck_colors AS (
        SELECT n.deck_id,
               COALESCE(
                   array_agg(DISTINCT ci ORDER BY ci) FILTER (WHERE ci IS NOT NULL),
                   ARRAY[]::text[]
               ) AS colors
        FROM needs n
        JOIN public.cards c ON c.oracle_id = n.oracle_id
        LEFT JOIN LATERAL unnest(c.color_identity) AS ci ON true
        GROUP BY n.deck_id
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
           t.missing_cost_eur,
           dc.colors,
           d.commander_oracle_id,
           COALESCE(fr.name, cmd.name),
           d.commander_oracle_id IS NOT NULL
               AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id)
    FROM totals t
    JOIN public.decks d ON d.id = t.deck_id
    JOIN public.deck_sources s ON s.id = d.source_id
    JOIN deck_colors dc ON dc.deck_id = t.deck_id
    LEFT JOIN public.cards cmd ON cmd.oracle_id = d.commander_oracle_id
    LEFT JOIN LATERAL (
        SELECT sn.name
        FROM public.card_search_names sn
        WHERE sn.oracle_id = d.commander_oracle_id AND sn.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE t.missing_cards <= p_max_missing
      AND (p_max_cost IS NULL OR t.missing_cost_eur <= p_max_cost)
      AND (p_colors IS NULL OR cardinality(p_colors) = 0 OR dc.colors <@ p_colors)
    -- Le commandant possédé passe devant, à manque égal : c'est la carte qui
    -- décide si le deck est un projet ou une liste de courses.
    ORDER BY (d.commander_oracle_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id)) DESC,
             t.missing_cards,
             t.missing_cost_eur,
             d.name
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$$;

COMMENT ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text, boolean) IS
    'Decks du corpus confrontés à la collection. Porte le commandant, dit si on '
    'le possède, et sait s''y restreindre.';

GRANT EXECUTE ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text, boolean)
    TO anon, authenticated;

COMMIT;
