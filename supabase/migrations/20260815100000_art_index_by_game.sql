-- L'index d'empreintes se sert par jeu.
--
-- **Ce qui n'allait pas.** `art_hash_page` rendait les 50 209 empreintes de la
-- table, tous jeux confondus. En mode Riftbound, l'application téléchargeait
-- donc 49 016 empreintes Magic pour n'en utiliser aucune : le cloisonnement par
-- `cards.game` interdit de proposer une carte Magic dans ce mode, si bien que
-- ces empreintes n'auraient pu que produire des faux positifs — et le code de
-- reconnaissance les écarte. Cinquante allers-retours réseau pour 1 193
-- empreintes utiles.
--
-- **Le découpage se fait ici, pas à la génération.** L'issue #6 proposait de
-- découper l'index dans `api/app/vision/index_builder.py`. Ce serait recopier
-- dans un artefact une information que la base porte déjà : `art_hashes` est
-- rattachée à `cards`, qui connaît le jeu. Une jointure suffit, et elle ne peut
-- pas se désynchroniser du catalogue.
--
-- **Pourquoi remplacer la signature au lieu d'ajouter une variante.** Ajouter
-- `p_game` sans supprimer l'ancienne forme créerait une surcharge : un appel
-- portant `p_offset` et `p_limit` conviendrait aux deux, et PostgREST n'aurait
-- aucun moyen de trancher. Les anciennes signatures sont donc retirées ; le
-- défaut `'magic'` garde les clients déjà installés fonctionnels, et il dit la
-- même chose que `Game.fromId` côté application — un jeu inconnu ou absent, ce
-- n'est pas une erreur, c'est Magic.

BEGIN;

DROP FUNCTION IF EXISTS public.art_hash_page(integer, integer);
DROP FUNCTION IF EXISTS public.art_hash_count();

CREATE FUNCTION public.art_hash_page(
    p_offset integer DEFAULT 0,
    p_limit  integer DEFAULT 2000,
    p_game   text    DEFAULT 'magic'
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
    JOIN public.cards c ON c.oracle_id = h.oracle_id
    WHERE c.game = p_game
    ORDER BY h.scryfall_id
    OFFSET GREATEST(p_offset, 0)
    LIMIT GREATEST(1, LEAST(p_limit, 5000));
$$;

COMMENT ON FUNCTION public.art_hash_page IS
    'Page de l''index d''empreintes du jeu demandé, l''empreinte en hexadécimal '
    'sur 16 caractères. Le format textuel protège du dépassement de précision '
    'des entiers JavaScript ; le filtre par jeu évite de télécharger un index '
    'dont aucune entrée ne peut être proposée.';

CREATE FUNCTION public.art_hash_count(p_game text DEFAULT 'magic')
RETURNS integer
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT count(*)::integer
    FROM public.art_hashes h
    JOIN public.cards c ON c.oracle_id = h.oracle_id
    WHERE c.game = p_game;
$$;

COMMENT ON FUNCTION public.art_hash_count IS
    'Nombre d''empreintes disponibles pour un jeu. Sert à décider si le cache '
    'local est périmé : le comparer au total tous jeux confondus déclencherait '
    'un retéléchargement à chaque bascule de jeu.';

GRANT EXECUTE ON FUNCTION public.art_hash_page(integer, integer, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.art_hash_count(text) TO anon, authenticated;

COMMIT;
