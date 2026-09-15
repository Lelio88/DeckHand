-- Filtrer les éditions par époque, pour sortir une vieille carte du lot.
--
-- **Le sélecteur d'édition trie par sortie la plus récente, et c'est le
-- problème.** Sur une carte réimprimée une dizaine de fois, l'ordre ne se voit
-- jamais. Sur un terrain de base — plus d'un millier d'impressions —, les 60
-- premières (le plafond de `p_limit`) sont mécaniquement toutes des sorties
-- récentes : une vieille Forêt de 1994 n'apparaît qu'en tapant le nom exact de
-- son extension, que l'utilisateur ne connaît justement pas toujours.
--
-- **La recherche textuelle ne résout pas ce cas.** Elle suppose de connaître
-- le nom de l'extension ; ce qu'on connaît souvent d'une vieille carte, c'est
-- son époque approximative, pas son nom précis. D'où deux nouveaux paramètres,
-- optionnels et à bornes ouvertes : `p_from_year` et `p_to_year` filtrent sur
-- l'année de sortie, sans exiger de connaître l'extension elle-même.
--
-- Une impression sans date connue disparaît dès qu'un filtre d'année est actif
-- — elle ne peut pas être confirmée dans la tranche demandée — mais reste
-- visible quand aucun filtre ne s'applique, comme aujourd'hui.
--
-- **Signature changée : DROP avant CREATE**, sous peine de surcharge
-- PostgREST (HTTP 300, migration 012). Un DROP emporte les GRANT — repris
-- explicitement en fin de fichier.

BEGIN;

DROP FUNCTION IF EXISTS public.card_printings(uuid, text, integer, text);

CREATE FUNCTION public.card_printings(
    p_oracle_id  uuid,
    p_query      text    DEFAULT NULL,
    p_limit      integer DEFAULT 60,
    p_lang       text    DEFAULT NULL,
    p_from_year  integer DEFAULT NULL,
    p_to_year    integer DEFAULT NULL
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
    price_eur_foil   numeric,
    has_nonfoil      boolean,
    has_foil         boolean,
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
    )
    SELECT e.print_id,
           e.set_code,
           e.set_name,
           e.collector_number,
           e.rarity,
           e.lang,
           e.printed_name,
           e.price_eur,
           e.price_eur_foil,
           e.has_nonfoil,
           e.has_foil,
           e.released_at,
           e.owned,
           e.art_crop_url
    FROM public.card_editions(ARRAY[p_oracle_id], p_lang) e
    WHERE ((SELECT n FROM needle) = ''
           OR lower(COALESCE(e.set_name, '')) LIKE '%' || (SELECT n FROM needle) || '%'
           OR lower(e.set_code) LIKE (SELECT n FROM needle) || '%')
      AND (p_from_year IS NULL OR EXTRACT(YEAR FROM e.released_at) >= p_from_year)
      AND (p_to_year   IS NULL OR EXTRACT(YEAR FROM e.released_at) <= p_to_year)
    ORDER BY e.owned DESC,
             e.released_at DESC NULLS LAST,
             e.set_code,
             e.collector_number
    LIMIT GREATEST(1, LEAST(p_limit, 200));
$$;

COMMENT ON FUNCTION public.card_printings(uuid, text, integer, text, integer, integer) IS
    'Éditions d''une carte, cherchables par extension et filtrables par tranche '
    'd''années de sortie (p_from_year/p_to_year, bornes incluses et ouvertes). '
    'Une ligne par édition, dans la langue demandée quand elle existe. Porte '
    'les deux cotes et les finitions.';

GRANT EXECUTE ON FUNCTION
    public.card_printings(uuid, text, integer, text, integer, integer)
    TO anon, authenticated;

COMMIT;
