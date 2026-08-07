-- 016 — L'illustration accompagne l'édition dans le sélecteur.
--
-- Deux éditions d'une même carte s'affichaient « Marvel Super Heroes · MSH #151 »
-- et « Marvel Super Heroes · MSH #368 », à des prix différents, sans aucun moyen
-- de savoir laquelle on tient en main. Le numéro de collection ne figure pas
-- toujours en évidence sur la carte, et deux impressions d'une même extension se
-- distinguent le plus souvent par leur illustration — c'est ce qui saute aux yeux
-- quand on compare la carte à l'écran.
--
-- `art_crop_url` existait déjà dans `card_prints` : elle sert à construire l'index
-- d'empreintes. Elle n'était simplement pas exposée à l'application.
--
-- La fonction change de type de retour : elle est donc supprimée avant d'être
-- recréée. Un CREATE OR REPLACE créerait une surcharge et PostgREST répondrait
-- HTTP 300 sur tous les appels (défaut de la migration 012).

BEGIN;

DROP FUNCTION IF EXISTS public.card_printings(uuid, text, integer);

CREATE FUNCTION public.card_printings(
    p_oracle_id uuid,
    p_query     text    DEFAULT NULL,
    p_limit     integer DEFAULT 60
)
RETURNS TABLE (
    print_id         uuid,
    set_code         text,
    set_name         text,
    collector_number text,
    rarity           text,
    lang             text,
    printed_name     text,
    price_eur        numeric,
    released_at      date,
    owned            integer,
    art_crop_url     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH needle AS (
        SELECT lower(trim(COALESCE(p_query, ''))) AS n
    ),
    mine AS (
        SELECT i.print_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid() AND i.print_id IS NOT NULL
        GROUP BY i.print_id
    )
    SELECT p.scryfall_id,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.rarity,
           p.lang,
           p.printed_name,
           p.price_eur,
           p.released_at,
           COALESCE(m.owned, 0),
           p.art_crop_url
    FROM public.card_prints p
    LEFT JOIN mine m ON m.print_id = p.scryfall_id
    WHERE p.oracle_id = p_oracle_id
      -- La recherche porte sur le nom d'édition et son code : c'est ce qui est
      -- imprimé sur la carte, et donc ce que l'utilisateur a sous les yeux.
      AND ((SELECT n FROM needle) = ''
           OR lower(COALESCE(p.set_name, '')) LIKE '%' || (SELECT n FROM needle) || '%'
           OR lower(p.set_code) LIKE (SELECT n FROM needle) || '%')
    -- Les éditions déjà possédées remontent en tête : sur une carte à mille
    -- impressions, retrouver celle qu'on a déjà choisie ne doit pas demander de
    -- fouiller. Les plus récentes ensuite — ce sont les plus probables.
    ORDER BY COALESCE(m.owned, 0) DESC,
             p.released_at DESC NULLS LAST,
             p.set_code,
             p.collector_number
    LIMIT GREATEST(1, LEAST(p_limit, 200));
$$;

COMMENT ON FUNCTION public.card_printings IS
    'Éditions d''une carte, avec leur illustration : c''est elle qui permet de '
    'distinguer deux impressions d''une même extension. Cherchables par nom ou code.';

GRANT EXECUTE ON FUNCTION public.card_printings(uuid, text, integer) TO anon, authenticated;

COMMIT;
