-- 012 — Filtres sur les suggestions de decks.
--
-- L'écran remontait les 30 decks les plus proches, sans moyen d'affiner. Sur
-- 725 decks Pauper, cela masque deux usages distincts :
--
--   « qu'est-ce que je peux jouer ce soir ? »        -> constructibles seulement
--   « qu'est-ce que je peux m'offrir pour 20 € ? »   -> plafond de budget
--
-- Deux paramètres s'ajoutent, tous deux facultatifs pour ne pas modifier le
-- comportement des appels existants :
--   * `p_max_cost` plafonne le coût de complétion ;
--   * `p_tier` restreint aux précons accessibles ou aux listes de tournoi.
--
-- Le filtrage porte sur les agrégats et intervient donc **après** le calcul de
-- complétion, jamais avant : plafonner un budget ne doit pas changer le décompte
-- des cartes manquantes, seulement masquer les decks hors de portée.

BEGIN;

CREATE OR REPLACE FUNCTION public.deck_suggestions(
    p_format       text,
    p_max_missing  integer DEFAULT 100,
    p_max_results  integer DEFAULT 30,
    p_max_cost     numeric DEFAULT NULL,
    p_tier         text    DEFAULT NULL
)
RETURNS TABLE (
    deck_id           uuid,
    deck_name         text,
    tier              text,
    source_id         text,
    source_name       text,
    attribution       text,
    total_cards       integer,
    owned_cards       integer,
    missing_cards     integer,
    completion        real,
    missing_cost_eur  numeric
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
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
$$;

GRANT EXECUTE ON FUNCTION
    public.deck_suggestions(text, integer, integer, numeric, text)
    TO authenticated;

COMMIT;
