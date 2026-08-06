-- 009 — Distribution de l'index d'empreintes à l'application.
--
-- **Pourquoi l'empreinte sort en hexadécimal et non en bigint.** Sur Flutter
-- web, `int` est un double IEEE-754 : au-delà de 2^53 les valeurs perdent des
-- bits silencieusement. Une empreinte de 64 bits transitant en nombre JSON
-- serait donc corrompue sur le web tout en restant correcte sur mobile — une
-- reconnaissance qui échoue sur une plateforme et pas sur l'autre, sans le
-- moindre message. Le format textuel évite le problème à la racine.
--
-- `to_hex` traite les valeurs négatives en complément à deux sur 64 bits, ce qui
-- restitue exactement les bits d'origine : le repliement en bigint signé côté
-- serveur est donc transparent pour le client.
--
-- La pagination est explicite plutôt que laissée à l'API REST : l'application
-- télécharge l'index une fois et le conserve, elle a besoin d'un parcours
-- déterministe et complet, pas d'un jeu de résultats plafonné.

BEGIN;

CREATE OR REPLACE FUNCTION public.art_hash_page(
    p_offset integer DEFAULT 0,
    p_limit  integer DEFAULT 2000
)
RETURNS TABLE (
    oracle_id uuid,
    hash_hex  text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT h.oracle_id,
           lpad(to_hex(h.dhash), 16, '0')
    FROM public.art_hashes h
    ORDER BY h.scryfall_id
    OFFSET GREATEST(p_offset, 0)
    LIMIT GREATEST(1, LEAST(p_limit, 5000));
$$;

COMMENT ON FUNCTION public.art_hash_page IS
    'Page de l''index d''empreintes, l''empreinte en hexadécimal sur 16 caractères. '
    'Le format textuel protège du dépassement de précision des entiers JavaScript.';

CREATE OR REPLACE FUNCTION public.art_hash_count()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT count(*)::integer FROM public.art_hashes;
$$;

GRANT EXECUTE ON FUNCTION public.art_hash_page(integer, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.art_hash_count() TO anon, authenticated;

COMMIT;
