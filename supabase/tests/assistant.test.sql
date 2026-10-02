-- Éprouve la migration `20261002100000_garde_assistant.sql` : un jeton
-- d'assistant (revendication `client_id`) modifie les cartes, jamais le compte.
-- Dans les deux sens, et sous le rôle qui subit la règle : ce qu'un assistant
-- ne fait pas lui est refusé, ce qu'il fait passe, et l'application — un jeton
-- sans `client_id` — garde tous ses droits.
--
-- **Sur une base jetable seulement** (un Supabase local où les migrations ont
-- été rejouées), dans une transaction annulée à la fin.
--
-- Usage (base locale) :
--   docker exec -i supabase_db_DeckHand psql -v ON_ERROR_STOP=1 -U postgres \
--     -d postgres < supabase/tests/assistant.test.sql

BEGIN;

-- Un contrôle : l'expression booléenne doit valoir `p_attendu`.
CREATE FUNCTION pg_temp.vaut(p_sql text, p_attendu boolean, p_libelle text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v boolean;
BEGIN
    EXECUTE p_sql INTO v;
    IF v IS DISTINCT FROM p_attendu THEN
        RAISE EXCEPTION 'ÉCHEC — % : obtenu %, attendu %', p_libelle, v, p_attendu;
    END IF;
    RAISE NOTICE 'ok — % (%)', p_libelle, v;
END;
$$;
GRANT EXECUTE ON FUNCTION pg_temp.vaut(text, boolean, text) TO authenticated;

-- ── Données de l'essai ─────────────────────────────────────────────────────
INSERT INTO auth.users (id, email, aud, role)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'a@essai.test', 'authenticated', 'authenticated'),
       ('00000000-0000-0000-0000-0000000000b2', 'b@essai.test', 'authenticated', 'authenticated');
INSERT INTO public.profiles (user_id, games) VALUES ('00000000-0000-0000-0000-0000000000a1', '{magic}');
INSERT INTO public.cards (oracle_id, name)
VALUES ('00000000-0000-0000-0000-00000000c0de', 'Carte d''essai');
INSERT INTO public.collections (id, owner_id, is_public)
VALUES ('00000000-0000-0000-0000-0000000000ca', '00000000-0000-0000-0000-0000000000a1', false);

-- ── Sous un jeton d'assistant ──────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
    '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated","client_id":"9a8b7c6d-0000-0000-0000-00000000c11e"}';

-- Ce qu'il fait : les cartes.
SELECT pg_temp.vaut($$SELECT public.add_to_collection('00000000-0000-0000-0000-00000000c0de', 3) = 3$$,
    true, 'l''assistant ajoute des cartes');
-- `remove_from_collection` rend le nombre d'exemplaires retirés.
SELECT pg_temp.vaut($$SELECT public.remove_from_collection('00000000-0000-0000-0000-00000000c0de', 1) = 1$$,
    true, 'l''assistant en retire');
SELECT pg_temp.vaut($$SELECT count(*) = 1 FROM public.collections$$,
    true, 'l''assistant lit sa collection');

-- Ce qu'il ne fait pas : le compte.
DO $$
BEGIN
    PERFORM public.delete_my_account();
    RAISE EXCEPTION 'ÉCHEC — un jeton d''assistant a pu supprimer le compte';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok — refusé : un assistant ne supprime pas de compte';
END;
$$;

UPDATE public.collections SET is_public = true, slug = 'publie-par-un-assistant'
WHERE id = '00000000-0000-0000-0000-0000000000ca';
DELETE FROM public.collections WHERE id = '00000000-0000-0000-0000-0000000000ca';
UPDATE public.profiles SET games = '{pokemon}' WHERE user_id = '00000000-0000-0000-0000-0000000000a1';

RESET ROLE;
SELECT pg_temp.vaut($$SELECT NOT is_public AND slug IS NULL FROM public.collections
                        WHERE id = '00000000-0000-0000-0000-0000000000ca'$$,
    true, 'refusé : un assistant ne publie pas la collection');
SELECT pg_temp.vaut($$SELECT EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000a1')
                        AND EXISTS (SELECT 1 FROM public.collection_items
                                    WHERE collection_id = '00000000-0000-0000-0000-0000000000ca')$$,
    true, 'refusé : le compte et la collection sont intacts');
SELECT pg_temp.vaut($$SELECT games = '{magic}' FROM public.profiles
                        WHERE user_id = '00000000-0000-0000-0000-0000000000a1'$$,
    true, 'refusé : un assistant ne touche pas aux préférences');

-- ── Un compte sans collection, sous un jeton d'assistant ───────────────────
-- Le premier ajout crée la collection, privée ; une collection publiée d'emblée
-- est refusée.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims =
    '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated","client_id":"9a8b7c6d-0000-0000-0000-00000000c11e"}';
DO $$
BEGIN
    INSERT INTO public.collections (owner_id, is_public, slug)
    VALUES ('00000000-0000-0000-0000-0000000000b2', true, 'publiee-d-emblee');
    RAISE EXCEPTION 'ÉCHEC — un assistant a créé une collection publiée';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok — refusé : un assistant ne crée pas de collection publiée';
END;
$$;
SELECT pg_temp.vaut($$SELECT public.add_to_collection('00000000-0000-0000-0000-00000000c0de', 1) = 1$$,
    true, 'le premier ajout d''un assistant crée la collection');
RESET ROLE;
SELECT pg_temp.vaut($$SELECT NOT is_public FROM public.collections
                        WHERE owner_id = '00000000-0000-0000-0000-0000000000b2'$$,
    true, 'cette collection est privée');

-- ── Sous un jeton de l'application (sans client_id) ────────────────────────
-- La garde ne vise que l'assistant : le titulaire garde tous ses gestes.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
UPDATE public.collections SET is_public = true
WHERE id = '00000000-0000-0000-0000-0000000000ca';
UPDATE public.profiles SET games = '{pokemon}' WHERE user_id = '00000000-0000-0000-0000-0000000000a1';
RESET ROLE;
SELECT pg_temp.vaut($$SELECT is_public FROM public.collections
                        WHERE id = '00000000-0000-0000-0000-0000000000ca'$$,
    true, 'l''application publie toujours la collection');
SELECT pg_temp.vaut($$SELECT games = '{pokemon}' FROM public.profiles
                        WHERE user_id = '00000000-0000-0000-0000-0000000000a1'$$,
    true, 'l''application règle toujours ses préférences');

SET LOCAL ROLE authenticated;
SELECT public.delete_my_account();
RESET ROLE;
SELECT pg_temp.vaut($$SELECT NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000a1')$$,
    true, 'l''application supprime toujours le compte');

SELECT 'garde de l''assistant : tous les cas passent' AS verdict;
ROLLBACK;
