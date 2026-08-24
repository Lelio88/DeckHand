-- La synthèse de collection ne calcule plus les prix trois fois.
--
-- Motivation : la version précédente dépassait le `statement_timeout` de huit
-- secondes du rôle `authenticated` — « canceling statement due to statement
-- timeout », c'est-à-dire une page de profil qui ne s'affiche plus.
--
-- **Une CTE n'est pas une variable.** Depuis PostgreSQL 12, une `WITH` sans
-- effet de bord est *inlinée* par défaut : chaque référence la réévalue. La
-- version précédente lisait `cotee` trois fois — une pour les agrégats, une
-- pour « une de chaque », une pour la carte la plus chère — et recalculait donc
-- `print_price` sur chaque exemplaire à chaque fois.
--
-- `MATERIALIZED` rétablit ce que l'on croyait écrire : le calcul a lieu une
-- fois, les trois lectures se servent du résultat.
--
-- **Et la carte la plus chère se cherche avant de se nommer.** Joindre
-- `cards` pour lire un nom n'a de sens que sur la ligne retenue ; le faire
-- avant le tri joignait toute la collection pour n'en garder qu'une ligne.
--
-- Mesuré sous le rôle réel — la connexion d'ingestion est propriétaire et ne
-- porte pas ce délai, elle aurait montré une fonction parfaitement saine.
--
-- Refs: page de profil, indicateurs défilants

BEGIN;

DROP FUNCTION IF EXISTS public.my_collection_summary(text);

CREATE FUNCTION public.my_collection_summary(p_game text DEFAULT 'magic')
RETURNS TABLE(
    total_cards integer,
    distinct_cards integer,
    total_value_eur numeric,
    unspecified_prints integer,
    unique_value_eur numeric,
    top_card_name text,
    top_card_eur numeric
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
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
        LEFT JOIN public.card_cheapest_price cheap
               ON cheap.oracle_id = m.oracle_id
    ),
    totaux AS (
        SELECT COALESCE(SUM(quantity), 0)::integer AS total_cards,
               COUNT(DISTINCT reference)::integer AS distinct_cards,
               COALESCE(SUM(quantity * unite), 0) AS total_value,
               COALESCE(SUM(quantity) FILTER (WHERE print_id IS NULL), 0)::integer
                   AS unspecified
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
    )
    SELECT t.total_cards,
           t.distinct_cards,
           t.total_value,
           t.unspecified,
           u.valeur,
           (SELECT ca.name FROM public.cards ca
             WHERE ca.oracle_id = (SELECT oracle_id FROM plus_chere)),
           COALESCE((SELECT unite FROM plus_chere), 0)
    FROM totaux t, une_de_chaque u;
$$;

COMMENT ON FUNCTION public.my_collection_summary(text) IS
    'Agrégats de la collection entière, en une passe. Les CTE sont MATERIALIZED '
    'à dessein : inlinées, elles recalculaient les prix une fois par lecture et '
    'la fonction dépassait le statement_timeout du rôle authenticated.';

GRANT EXECUTE ON FUNCTION public.my_collection_summary(text) TO authenticated;

COMMIT;
