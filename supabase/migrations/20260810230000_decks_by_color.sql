-- 031 — Filtrer les suggestions par couleur.
--
-- Le corpus mélange les cinq couleurs et toutes leurs combinaisons. Or on ne
-- choisit pas un deck comme on choisit une carte : la couleur vient d'abord,
-- avant le prix et même avant le format — c'est elle qui décide de la façon de
-- jouer, et c'est la première chose qu'un joueur sait de ce qu'il veut.
--
-- **L'identité couleur d'un deck est l'union de celles de ses cartes.** C'est la
-- règle du Commander, et elle vaut comme description ailleurs : un deck
-- contenant une seule carte rouge est un deck qui a besoin de rouge.
--
-- **La sélection est un tamis, pas une recherche.** Demander « rouge » rend les
-- decks qui *tiennent* dans le rouge, pas ceux qui en contiennent : sans quoi
-- choisir une couleur ferait remonter des decks à cinq couleurs, injouables
-- pour qui voulait justement du mono-rouge. `<@` — « contenu dans » — dit
-- exactement cela. Une sélection vide ne filtre rien.
--
-- Les decks incolores (artefacts, terrains) ont une identité vide, laquelle est
-- contenue dans n'importe quelle sélection : ils restent donc proposés quoi
-- qu'on demande, ce qui est juste — ils se jouent partout.
--
-- Signature modifiée : suppression puis recréation, sous peine de surcharge
-- PostgREST (migration 012).

BEGIN;

DROP FUNCTION IF EXISTS public.deck_suggestions(text, integer, integer, numeric, text, text);

CREATE FUNCTION public.deck_suggestions(
    p_format      text,
    p_max_missing integer DEFAULT 100,
    p_max_results integer DEFAULT 30,
    p_max_cost    numeric DEFAULT NULL,
    p_tier        text    DEFAULT NULL,
    p_game        text    DEFAULT 'magic',
    p_colors      text[]  DEFAULT NULL
)
RETURNS TABLE (
    deck_id          uuid,
    deck_name        text,
    tier             text,
    source_id        text,
    source_name      text,
    attribution      text,
    total_cards      integer,
    owned_cards      integer,
    missing_cards    integer,
    completion       real,
    missing_cost_eur numeric,
    colors           text[]
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
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
           dc.colors
    FROM totals t
    JOIN public.decks d ON d.id = t.deck_id
    JOIN public.deck_sources s ON s.id = d.source_id
    JOIN deck_colors dc ON dc.deck_id = t.deck_id
    WHERE t.missing_cards <= p_max_missing
      AND (p_max_cost IS NULL OR t.missing_cost_eur <= p_max_cost)
      AND (p_colors IS NULL OR cardinality(p_colors) = 0 OR dc.colors <@ p_colors)
    ORDER BY t.missing_cards, t.missing_cost_eur, d.name
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$$;

COMMENT ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[]) IS
    'Decks du corpus confrontés à la collection, filtrables par cartes '
    'manquantes, budget, provenance et identité couleur.';

GRANT EXECUTE ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[])
    TO anon, authenticated;

COMMIT;
