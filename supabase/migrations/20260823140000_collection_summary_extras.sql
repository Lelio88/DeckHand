-- La synthèse de collection rend de quoi alimenter plusieurs indicateurs.
--
-- Motivation : la page de profil n'affichait que deux chiffres — le nombre
-- d'exemplaires et la valeur totale. On veut pouvoir en faire défiler d'autres
-- d'une pression, et deux d'entre eux n'existent nulle part :
--
--   * la valeur **une de chaque** — ce que vaudrait la collection sans les
--     doublons. Elle répond à « qu'est-ce que j'ai, vraiment ? », quand le total
--     répond à « qu'est-ce que je possède ? » ;
--   * la **carte la plus chère**, qui est la première chose qu'on cherche et
--     que rien ne disait.
--
-- Les deux se calculent là où sont les données. Les faire côté application
-- obligerait à télécharger la collection entière pour n'en tirer qu'un nombre —
-- et la page n'en porte qu'une partie, ce qui donnerait un total faux qui change
-- en tournant les pages.
--
-- **Une de chaque, c'est une par référence**, au même sens que `distinct_cards` :
-- le couple (extension, numéro) fait foi, une carte sans édition précisée en
-- valant une. Compter par oracle ferait de 871 éditions de Plaine une seule
-- ligne, alors que deux illustrations occupent deux cases d'un classeur.
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
    ),
    cotee AS (
        SELECT m.*,
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
    -- Une référence peut exister en plusieurs lignes — ordinaire et brillante.
    -- « Une de chaque » retient alors la plus chère : c'est celle qu'on garderait.
    par_reference AS (
        SELECT reference, MAX(unite) AS unite
        FROM cotee
        GROUP BY reference
    )
    SELECT COALESCE(SUM(c.quantity), 0)::integer,
           COUNT(DISTINCT c.reference)::integer,
           COALESCE(SUM(c.quantity * c.unite), 0),
           COALESCE(SUM(c.quantity) FILTER (WHERE c.print_id IS NULL), 0)::integer,
           COALESCE((SELECT SUM(unite) FROM par_reference), 0),
           (SELECT ca.name
              FROM cotee c2
              JOIN public.cards ca ON ca.oracle_id = c2.oracle_id
             ORDER BY c2.unite DESC, ca.name
             LIMIT 1),
           COALESCE((SELECT MAX(unite) FROM cotee), 0)
    FROM cotee c;
$$;

COMMENT ON FUNCTION public.my_collection_summary(text) IS
    'Agrégats de la collection entière : exemplaires, références, valeur totale, '
    'valeur « une de chaque », et la carte la plus chère. Calculé ici et non '
    'dans l''application, qui ne tient qu''une page de la collection à la fois.';

GRANT EXECUTE ON FUNCTION public.my_collection_summary(text) TO authenticated;

COMMIT;
