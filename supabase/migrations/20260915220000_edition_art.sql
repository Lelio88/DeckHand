-- L'illustration d'une édition, demandée directement.
--
-- **L'aperçu la cherchait dans une liste, et concluait trop vite.** `showCardArt`
-- chargeait la première page des éditions de la carte et y cherchait
-- l'impression voulue ; absente de cette page, elle passait pour « sans image »,
-- et l'aperçu montrait l'illustration d'une autre édition en affirmant que
-- celle-ci n'en avait pas. 19 cartes Magic dépassent une page — la Forêt compte
-- près de 900 éditions —, et une vieille édition pas encore possédée, donc pas
-- remontée en tête, pouvait tomber dans ce cas.
--
-- Cette fonction répond à la seule question posée : l'illustration de cette
-- édition. Elle regarde toute la case — même carte, même extension, même
-- numéro — et préfère l'impression demandée, puis l'anglaise : une fiche
-- localisée publiée sans image n'enlève pas son illustration à l'édition.
-- NULL signifie que l'édition n'a réellement aucune image au catalogue.

BEGIN;

CREATE FUNCTION public.edition_art(p_print_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT p.art_crop_url
    FROM public.card_prints me
    JOIN public.card_prints p
      ON p.oracle_id = me.oracle_id
     AND p.set_code = me.set_code
     AND p.collector_number IS NOT DISTINCT FROM me.collector_number
    WHERE me.scryfall_id = p_print_id
      AND p.art_crop_url IS NOT NULL
    ORDER BY (p.scryfall_id = p_print_id) DESC,
             (p.lang = 'en') DESC,
             p.scryfall_id
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.edition_art(uuid) IS
    'Illustration de l''édition d''une impression : la sienne, sinon celle d''une '
    'autre langue de la même case (anglaise d''abord). NULL quand l''édition n''a '
    'aucune image au catalogue.';

GRANT EXECUTE ON FUNCTION public.edition_art(uuid) TO anon, authenticated;

COMMIT;
