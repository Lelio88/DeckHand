-- 014 — Collection consultable à l'échelle, et possession visible à la saisie.
--
-- `my_collection()` renvoyait la collection entière, sans filtre ni ordre. Sur
-- quelques cartes c'est indolore ; sur les deux mille que vise le produit, cela
-- transporte tout à chaque ouverture et rend une carte introuvable.
--
-- **La pagination casse les agrégats**, et c'est le piège de cette migration :
-- une page ne peut pas porter le total de la collection. Le décompte et la
-- valorisation vivent donc dans une fonction séparée, qui interroge toujours la
-- collection complète — sans quoi l'utilisateur verrait « 50 cartes » en page 1
-- et « 30 cartes » en page 2.
--
-- `search_cards` gagne la quantité possédée. Sans elle, on ne sait pas, en
-- saisissant, si une carte a déjà été ajoutée — sur une collection saisie en
-- plusieurs séances, on ne sait plus où l'on en est dans sa boîte.
--
-- Les deux fonctions changent de signature ET de type de retour : elles sont
-- donc supprimées avant d'être recréées. Un simple CREATE OR REPLACE créerait
-- une surcharge, et PostgREST répondrait HTTP 300 sur tous les appels — le
-- défaut rencontré à la migration 012.

BEGIN;

DROP FUNCTION IF EXISTS public.my_collection();
DROP FUNCTION IF EXISTS public.search_cards(text, integer);

-- ---------------------------------------------------------------------------
-- Collection : page filtrée et ordonnée
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.my_collection(
    p_query  text    DEFAULT NULL,
    p_sort   text    DEFAULT 'name',
    p_limit  integer DEFAULT 50,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    oracle_id       uuid,
    name            text,
    printed_name    text,
    type_line       text,
    quantity        integer,
    unit_price_eur  numeric,
    line_price_eur  numeric,
    legal_pauper    boolean,
    legal_modern    boolean,
    legal_commander boolean,
    added_at        timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH needle AS (
        SELECT public.normalize_card_name(COALESCE(p_query, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id,
               SUM(i.quantity)::integer AS quantity,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    )
    SELECT c.oracle_id,
           c.name,
           fr.name,
           c.type_line,
           m.quantity,
           p.price_eur,
           p.price_eur * m.quantity,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           m.added_at
    FROM mine m
    JOIN public.cards c ON c.oracle_id = m.oracle_id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = m.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = m.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    -- Le filtre porte sur tous les noms connus de la carte, français compris :
    -- chercher « foudre » dans sa collection doit trouver Lightning Bolt.
    WHERE (SELECT n FROM needle) = ''
       OR EXISTS (
            SELECT 1 FROM public.card_search_names s
            WHERE s.oracle_id = m.oracle_id
              AND s.normalized LIKE '%' || (SELECT n FROM needle) || '%'
       )
    ORDER BY
        CASE WHEN p_sort = 'price'    THEN p.price_eur * m.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' THEN m.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   THEN m.added_at END DESC NULLS LAST,
        COALESCE(fr.name, c.name)
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection IS
    'Page de collection, filtrable par nom (français compris) et ordonnable. '
    'Les totaux sont dans my_collection_summary : une page ne peut pas les porter.';

-- ---------------------------------------------------------------------------
-- Collection : agrégats, toujours calculés sur l'ensemble
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.my_collection_summary()
RETURNS TABLE (
    total_cards     integer,
    distinct_cards  integer,
    total_value_eur numeric
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT COALESCE(SUM(m.quantity), 0)::integer,
           COUNT(*)::integer,
           COALESCE(SUM(m.quantity * COALESCE(p.price_eur, 0)), 0)
    FROM (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    ) m
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = m.oracle_id;
$$;

-- ---------------------------------------------------------------------------
-- Recherche : la possession devient visible
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.search_cards(q text, max_results integer DEFAULT 20)
RETURNS TABLE (
    oracle_id       uuid,
    name            text,
    matched_name    text,
    matched_lang    text,
    type_line       text,
    mana_cost       text,
    price_eur       numeric,
    legal_pauper    boolean,
    legal_modern    boolean,
    legal_commander boolean,
    score           real,
    owned           integer
)
LANGUAGE sql
STABLE
SET search_path = public, extensions
AS $$
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
           COALESCE(m.owned, 0)
    FROM best b
    JOIN public.cards c ON c.oracle_id = b.oracle_id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = b.oracle_id
    LEFT JOIN mine m ON m.oracle_id = b.oracle_id
    ORDER BY b.score DESC, length(c.name), c.name
    LIMIT GREATEST(1, LEAST(max_results, 50));
$$;

GRANT EXECUTE ON FUNCTION public.my_collection(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_cards(text, integer) TO anon, authenticated;

COMMIT;
