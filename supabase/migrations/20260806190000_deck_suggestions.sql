-- 007 — Moteur de suggestion : que puis-je construire avec ma collection ?
--
-- Pour chaque deck du format demandé, confronte les cartes requises à celles
-- possédées, et chiffre ce qui manque.
--
-- Choix de conception :
--
-- * **Le sideboard est exclu du calcul.** On mesure la faisabilité du deck
--   principal ; exiger les 15 cartes de réserve rendrait presque tout deck
--   incomplet et masquerait ceux qui sont réellement à portée.
--
-- * **Les quantités comptent.** Un deck réclamant 4 Foudre alors qu'on en
--   possède 2 est incomplet de 2 cartes, pas de zéro. C'est toute la différence
--   entre une promesse tenable et un décompte flatteur.
--
-- * **Les cartes sans cote comptent pour 0 €.** Mieux vaut sous-estimer le coût
--   de complétion que d'inventer un prix.
--
-- * **Le classement privilégie le nombre de cartes manquantes, puis le coût.**
--   « Il me manque 2 cartes à 3 € » est une information plus actionnable que
--   « il me manque 30 cartes à 2 € ».

BEGIN;

CREATE OR REPLACE FUNCTION public.deck_suggestions(
    p_format       text,
    p_max_missing  integer DEFAULT 100,
    p_max_results  integer DEFAULT 30
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
    ORDER BY t.missing_cards, t.missing_cost_eur, d.name
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$$;

COMMENT ON FUNCTION public.deck_suggestions IS
    'Decks du format demandé, classés du plus proche au plus lointain de la collection '
    'de l''appelant. Le sideboard est exclu ; les quantités sont respectées.';

-- Détail des cartes qui manquent pour un deck donné — la liste de courses.
CREATE OR REPLACE FUNCTION public.deck_missing_cards(p_deck_id uuid)
RETURNS TABLE (
    oracle_id     uuid,
    name          text,
    printed_name  text,
    needed        integer,
    owned         integer,
    missing       integer,
    unit_price_eur numeric,
    line_cost_eur  numeric
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
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = n.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = n.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE n.needed > COALESCE(m.owned, 0)
    ORDER BY (GREATEST(n.needed - COALESCE(m.owned, 0), 0) * COALESCE(p.price_eur, 0)) DESC,
             c.name;
$$;

GRANT EXECUTE ON FUNCTION public.deck_suggestions(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deck_missing_cards(uuid) TO authenticated;

COMMIT;
