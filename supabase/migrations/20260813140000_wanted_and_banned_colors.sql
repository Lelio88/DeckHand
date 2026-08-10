-- 043 — Couleurs voulues et couleurs bannies.
--
-- **Un seul ensemble ne suffisait pas.** Le filtre demandait que l'identité du
-- deck soit *incluse* dans les couleurs cochées : cocher le rouge écartait donc
-- tous les decks rouge-blanc, alors que cocher une couleur veut dire « j'en
-- veux », pas « rien d'autre ». La sémantique est renversée — les couleurs
-- cochées doivent être **présentes** — et une seconde liste dit celles qu'on
-- refuse.
--
-- « Du rouge, mais pas de bleu » ne s'exprime pas autrement, et c'est la
-- question qu'on se pose devant une collection : on connaît ses couleurs, et
-- celles qu'on ne veut pas jouer.
--
-- Signature élargie : l'ancienne est supprimée.

BEGIN;

DROP FUNCTION IF EXISTS public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text, boolean);

CREATE FUNCTION public.deck_suggestions(
    p_format           text,
    p_max_missing      integer DEFAULT 100,
    p_max_results      integer DEFAULT 30,
    p_max_cost         numeric DEFAULT NULL,
    p_tier             text    DEFAULT NULL,
    p_game             text    DEFAULT 'magic',
    p_colors           text[]  DEFAULT NULL,
    p_banned_colors    text[]  DEFAULT NULL,
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
    commander_owned     boolean,
    basic_lands         integer
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
$$;

COMMENT ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text[], text, boolean) IS
    'Decks du corpus confrontés à la collection. `p_colors` liste les couleurs '
    'que le deck doit porter, `p_banned_colors` celles qu''il ne doit pas '
    'porter. Terrains de base exclus du compte.';

GRANT EXECUTE ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text[], text, boolean)
    TO anon, authenticated;

COMMIT;
