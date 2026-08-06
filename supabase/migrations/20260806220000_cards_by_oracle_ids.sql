-- 010 — Détails de cartes à partir de leurs identifiants.
--
-- La reconnaissance rend des `oracle_id` ; l'écran de confirmation doit montrer
-- des noms, des prix et des formats. Cette fonction fait le pont.
--
-- Elle existe pour la même raison que `my_collection` : le prix vient d'une vue
-- et le nom français d'une table d'index, deux jointures que l'API REST ne sait
-- pas déduire d'elle-même faute de clé étrangère.
--
-- L'ordre des résultats suit celui des identifiants demandés : la reconnaissance
-- les fournit classés par pertinence, et cet ordre ne doit pas être perdu en
-- route.

BEGIN;

CREATE OR REPLACE FUNCTION public.cards_by_oracle_ids(p_ids uuid[])
RETURNS TABLE (
    oracle_id       uuid,
    name            text,
    printed_name    text,
    type_line       text,
    price_eur       numeric,
    legal_pauper    boolean,
    legal_modern    boolean,
    legal_commander boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT c.oracle_id,
           c.name,
           fr.name,
           c.type_line,
           p.price_eur,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander
    FROM unnest(p_ids) WITH ORDINALITY AS requested(id, position)
    JOIN public.cards c ON c.oracle_id = requested.id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = c.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    ORDER BY requested.position;
$$;

GRANT EXECUTE ON FUNCTION public.cards_by_oracle_ids(uuid[]) TO anon, authenticated;

COMMIT;
