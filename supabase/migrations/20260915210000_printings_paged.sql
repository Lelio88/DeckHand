-- Paginer les éditions d'une carte, et filtrer la finition côté serveur.
--
-- **Une limite fixe cachait des éditions.** `card_printings` rendait une page
-- unique de 60 lignes. 19 cartes Magic en comptent davantage — les cinq
-- terrains de base près de 900 chacun, Sol Ring 135, Command Tower 118 —, et le
-- tri par sortie la plus récente enterrait les plus anciennes, même dans une
-- tranche d'années : 109 Forêts avant 2000, 230 entre 2000 et 2009.
-- `p_offset` laisse l'application charger la suite. Relever le plafond n'aurait
-- fait que déplacer le problème : les terrains de base dépassent les 200 lignes
-- que le serveur accepte.
--
-- **Mesuré avant de choisir**, sous le rôle `authenticated` et depuis le poste
-- de développement : 60 ou 200 lignes coûtent le même temps serveur — 57 ms
-- pour Lightning Bolt, 86 ms pour Sol Ring, 0,7 s pour la Forêt, dont toutes
-- les éditions sont calculées et triées avant la coupe. Seul le volume change,
-- de 24 à 80 Kio sur la Forêt. Chaque page rejoue ce calcul : charger la suite
-- d'une Forêt coûte à nouveau ses 0,7 s, ce qu'un geste explicite supporte.
--
-- **La finition se filtre ici, et non plus dans l'application** (`p_finish` :
-- 'foil', 'nonfoil', ou NULL pour tout). Filtrée après la coupe, une page de 60
-- éditions pouvait n'en montrer que dix en brillant, et une page suivante
-- aucune : une pagination ne tient que si chaque page compte ce qu'elle promet.
--
-- **Signature changée : DROP avant CREATE**, sous peine de surcharge PostgREST
-- (HTTP 300, migration 012). Un DROP emporte les GRANT — repris en fin de
-- fichier.

BEGIN;

DROP FUNCTION IF EXISTS public.card_printings(uuid, text, integer, text, integer, integer);

CREATE FUNCTION public.card_printings(
    p_oracle_id  uuid,
    p_query      text    DEFAULT NULL,
    p_limit      integer DEFAULT 60,
    p_lang       text    DEFAULT NULL,
    p_from_year  integer DEFAULT NULL,
    p_to_year    integer DEFAULT NULL,
    p_offset     integer DEFAULT 0,
    p_finish     text    DEFAULT NULL
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
      AND (p_finish IS NULL
           OR (p_finish = 'foil'    AND e.has_foil)
           OR (p_finish = 'nonfoil' AND e.has_nonfoil))
    -- Un ordre total : sans lui, deux pages pourraient se recouvrir ou
    -- s'ignorer. Une édition est un couple (extension, numéro), unique ici.
    ORDER BY e.owned DESC,
             e.released_at DESC NULLS LAST,
             e.set_code,
             e.collector_number
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$;

COMMENT ON FUNCTION public.card_printings(uuid, text, integer, text, integer, integer, integer, text) IS
    'Éditions d''une carte, par pages (p_limit, p_offset), cherchables par '
    'extension, filtrables par tranche d''années de sortie (bornes incluses et '
    'ouvertes) et par finition (p_finish : foil, nonfoil ou NULL). Une ligne par '
    'édition, dans la langue demandée quand elle existe.';

GRANT EXECUTE ON FUNCTION
    public.card_printings(uuid, text, integer, text, integer, integer, integer, text)
    TO anon, authenticated;

COMMIT;
