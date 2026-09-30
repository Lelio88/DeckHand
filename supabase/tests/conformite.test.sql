-- Éprouve la migration `20260930100000_conformite.sql` sous les rôles qui
-- subissent ses règles, dans les deux sens : ce qui doit passer passe, ce qui
-- doit être refusé l'est.
--
-- **Sur une base jetable seulement** (un Supabase local où les migrations ont
-- été rejouées). Tout se déroule dans une transaction annulée à la fin : aucune
-- ligne ne survit, mais le fichier crée des comptes et des collections le temps
-- de l'essai — il n'a rien à faire sur la base en service.
--
-- Chaque contrôle lève une exception à la première règle qui ne tient pas ; la
-- dernière ligne annonce le succès.
--
-- Usage (base locale) :
--   docker exec -i supabase_db_DeckHand psql -v ON_ERROR_STOP=1 -U postgres \
--     -d postgres < supabase/tests/conformite.test.sql

BEGIN;

-- Un contrôle : l'appel doit échouer faute de droit (42501).
CREATE FUNCTION pg_temp.refuse(p_sql text, p_libelle text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'ÉCHEC — accepté alors qu''il devait être refusé : %', p_libelle;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok — refusé : %', p_libelle;
END;
$$;

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

GRANT EXECUTE ON FUNCTION pg_temp.refuse(text, text), pg_temp.vaut(text, boolean, text)
    TO anon, authenticated;

-- ── Données de l'essai ─────────────────────────────────────────────────────
INSERT INTO auth.users (id, email, aud, role)
VALUES ('00000000-0000-0000-0000-0000000000a1', 'a@essai.test', 'authenticated', 'authenticated'),
       ('00000000-0000-0000-0000-0000000000b2', 'b@essai.test', 'authenticated', 'authenticated');

INSERT INTO public.cards (oracle_id, name)
VALUES ('00000000-0000-0000-0000-00000000c0de', 'Carte d''essai');
INSERT INTO public.card_prints (scryfall_id, oracle_id, lang, set_code, collector_number)
VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000c0de', 'en', 'zzt', '1'),
       ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000c0de', 'en', 'zzt', '2');

INSERT INTO public.collections (id, owner_id, is_public, slug)
VALUES ('00000000-0000-0000-0000-0000000000ca', '00000000-0000-0000-0000-0000000000a1', true, 'essai-conformite'),
       ('00000000-0000-0000-0000-0000000000cb', '00000000-0000-0000-0000-0000000000b2', false, NULL);
INSERT INTO public.collection_items (collection_id, oracle_id, print_id)
VALUES ('00000000-0000-0000-0000-0000000000ca', '00000000-0000-0000-0000-00000000c0de', '00000000-0000-0000-0000-0000000000f1'),
       ('00000000-0000-0000-0000-0000000000cb', '00000000-0000-0000-0000-00000000c0de', '00000000-0000-0000-0000-0000000000f1');
INSERT INTO public.profiles (user_id) VALUES ('00000000-0000-0000-0000-0000000000a1');
INSERT INTO public.collection_overlay_keys (collection_id, key_hash)
VALUES ('00000000-0000-0000-0000-0000000000ca', sha256(convert_to('bonne-cle', 'UTF8')));

-- ── Le calque, sous la clé anonyme ─────────────────────────────────────────
SET LOCAL ROLE anon;

SELECT pg_temp.refuse($$SELECT public.public_request_spotlight('00000000-0000-0000-0000-0000000000ca', 'zzt', '1', 'x', 'magic')$$,
    'l''écriture d''origine n''est plus ouverte à anon');
SELECT pg_temp.refuse($$SELECT public.public_request_spotlight_page('00000000-0000-0000-0000-0000000000ca', 'zzt', 1, 'x', 'magic')$$,
    'ni sa variante page');
SELECT pg_temp.refuse($$SELECT public.public_request_spotlight_strip('00000000-0000-0000-0000-0000000000ca', 'zzt', '1', 'x', 'magic')$$,
    'ni sa variante tapis');
SELECT pg_temp.refuse($$SELECT count(*) FROM public.collection_overlay_keys$$,
    'les empreintes de clé ne se lisent pas');
SELECT pg_temp.refuse($$SELECT public.overlay_key_matches('00000000-0000-0000-0000-0000000000ca', 'bonne-cle')$$,
    'la comparaison de clé n''est pas un oracle ouvert');
SELECT pg_temp.refuse($$SELECT public.delete_my_account()$$,
    'anon ne supprime aucun compte');

SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight(NULL, '00000000-0000-0000-0000-0000000000ca', 'zzt', '1', 'x')$$,
    false, 'sans clé, rien ne monte');
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight('mauvaise', '00000000-0000-0000-0000-0000000000ca', 'zzt', '1', 'x')$$,
    false, 'une clé fausse, rien ne monte');
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight('bonne-cle', '00000000-0000-0000-0000-0000000000ca', 'zzt', '1', 'x')$$,
    true, 'la bonne clé fait monter une case possédée');
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight('bonne-cle', '00000000-0000-0000-0000-0000000000ca', 'zzt', '1', 'y')$$,
    false, 'le délai de 30 s tient toujours');
RESET ROLE;
UPDATE public.collection_spotlight SET requested_at = NOW() - INTERVAL '1 minute';
SET LOCAL ROLE anon;
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight('bonne-cle', '00000000-0000-0000-0000-0000000000ca', 'zzt', '2', 'x')$$,
    false, 'une case non possédée reste refusée');
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight_page('mauvaise', '00000000-0000-0000-0000-0000000000ca', 'zzt', 1, 'x')$$,
    false, 'page : une clé fausse, rien ne monte');
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight_page('bonne-cle', '00000000-0000-0000-0000-0000000000ca', 'zzt', 1, 'x')$$,
    true, 'page : la bonne clé fait monter la page');
RESET ROLE;
UPDATE public.collection_spotlight SET requested_at = NOW() - INTERVAL '1 minute';
SET LOCAL ROLE anon;
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight_strip('mauvaise', '00000000-0000-0000-0000-0000000000ca', 'zzt', '1', 'x')$$,
    false, 'tapis : une clé fausse, rien ne monte');
-- La clé d'une collection n'ouvre pas une autre : B n'est pas publiée, et
-- n'a pas de clé.
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight('bonne-cle', 'essai-conformite', 'zzt', '1', 'x')$$,
    true, 'le nom public ouvre aussi le calque');
RESET ROLE;
UPDATE public.collection_spotlight SET requested_at = NOW() - INTERVAL '1 minute';
SET LOCAL ROLE anon;
SELECT pg_temp.vaut($$SELECT public.bot_request_spotlight('bonne-cle', '00000000-0000-0000-0000-0000000000cb', 'zzt', '1', 'x')$$,
    false, 'la clé de A n''ouvre pas le calque de B');
RESET ROLE;

-- ── La purge des pseudos ───────────────────────────────────────────────────
DO $$
DECLARE v_commande text;
BEGIN
    SELECT command INTO v_commande FROM cron.job WHERE jobname = 'deckhand-purge-calque';
    IF v_commande IS NULL THEN
        RAISE EXCEPTION 'ÉCHEC — la tâche de purge n''est pas planifiée';
    END IF;
    UPDATE public.collection_spotlight SET requested_at = NOW() - INTERVAL '25 hours';
    EXECUTE v_commande;
    IF EXISTS (SELECT 1 FROM public.collection_spotlight) THEN
        RAISE EXCEPTION 'ÉCHEC — une demande de plus de 24 h a survécu à la purge';
    END IF;
    RAISE NOTICE 'ok — la purge efface les demandes de plus de 24 h';
END;
$$;
INSERT INTO public.collection_spotlight (collection_id, request_id, set_code, collector_number, requested_by, requested_at)
VALUES ('00000000-0000-0000-0000-0000000000ca', nextval('public.collection_spotlight_request_seq'), 'zzt', '1', 'recent', NOW());
DO $$
BEGIN
    EXECUTE (SELECT command FROM cron.job WHERE jobname = 'deckhand-purge-calque');
    IF NOT EXISTS (SELECT 1 FROM public.collection_spotlight) THEN
        RAISE EXCEPTION 'ÉCHEC — la purge a effacé une demande récente';
    END IF;
    RAISE NOTICE 'ok — une demande récente survit à la purge';
END;
$$;

-- ── Les inscriptions jamais confirmées ─────────────────────────────────────
INSERT INTO auth.users (id, email, aud, role, created_at, email_confirmed_at, last_sign_in_at)
VALUES ('00000000-0000-0000-0000-0000000000e1', 'vieille@essai.test', 'authenticated', 'authenticated',
        NOW() - INTERVAL '8 days', NULL, NULL),
       ('00000000-0000-0000-0000-0000000000e2', 'recente@essai.test', 'authenticated', 'authenticated',
        NOW() - INTERVAL '2 days', NULL, NULL),
       ('00000000-0000-0000-0000-0000000000e3', 'ancienne@essai.test', 'authenticated', 'authenticated',
        NOW() - INTERVAL '90 days', NULL, NOW() - INTERVAL '60 days');
DO $$
BEGIN
    EXECUTE (SELECT command FROM cron.job WHERE jobname = 'deckhand-purge-inscriptions');
    IF EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000e1') THEN
        RAISE EXCEPTION 'ÉCHEC — une inscription jamais confirmée de 8 jours a survécu';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000e2') THEN
        RAISE EXCEPTION 'ÉCHEC — une inscription de 2 jours a été effacée trop tôt';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000e3') THEN
        RAISE EXCEPTION 'ÉCHEC — un compte qui s''est déjà connecté a été effacé';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000a1') THEN
        RAISE EXCEPTION 'ÉCHEC — un compte ordinaire a été effacé par la purge';
    END IF;
    RAISE NOTICE 'ok — seules les inscriptions jamais confirmées ni utilisées de plus de 7 jours partent';
END;
$$;

-- ── Le journal tient toujours les retraits ordinaires ──────────────────────
-- Le déclencheur ignore désormais les cases d'une collection qui disparaît ;
-- un retrait dans une collection qui reste doit, lui, s'inscrire.
DELETE FROM public.collection_items
WHERE collection_id = '00000000-0000-0000-0000-0000000000cb';
SELECT pg_temp.vaut($$SELECT EXISTS (SELECT 1 FROM public.collection_movements
                        WHERE collection_id = '00000000-0000-0000-0000-0000000000cb' AND delta = -1)$$,
    true, 'un retrait ordinaire s''inscrit au journal');
INSERT INTO public.collection_items (collection_id, oracle_id, print_id)
VALUES ('00000000-0000-0000-0000-0000000000cb', '00000000-0000-0000-0000-00000000c0de', '00000000-0000-0000-0000-0000000000f1');

-- ── Supprimer son compte ───────────────────────────────────────────────────
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"role":"authenticated"}';
DO $$
BEGIN
    PERFORM public.delete_my_account();
    RAISE EXCEPTION 'ÉCHEC — une session sans utilisateur a pu appeler la suppression';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'ok — refusé : un jeton sans utilisateur ne supprime rien';
END;
$$;

SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated"}';
SELECT public.delete_my_account();
RESET ROLE;
SELECT pg_temp.vaut($$SELECT NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000b2')$$,
    true, 'B a supprimé son compte');
SELECT pg_temp.vaut($$SELECT NOT EXISTS (SELECT 1 FROM public.collections WHERE owner_id = '00000000-0000-0000-0000-0000000000b2')$$,
    true, 'sa collection est partie avec lui');
SELECT pg_temp.vaut($$SELECT EXISTS (SELECT 1 FROM auth.users WHERE id = '00000000-0000-0000-0000-0000000000a1')
                        AND EXISTS (SELECT 1 FROM public.collection_items WHERE collection_id = '00000000-0000-0000-0000-0000000000ca')$$,
    true, 'A et sa collection sont intacts');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
SELECT public.delete_my_account();
RESET ROLE;
SELECT pg_temp.vaut($$SELECT NOT EXISTS (SELECT 1 FROM public.collections WHERE id = '00000000-0000-0000-0000-0000000000ca')
                        AND NOT EXISTS (SELECT 1 FROM public.collection_items WHERE collection_id = '00000000-0000-0000-0000-0000000000ca')
                        AND NOT EXISTS (SELECT 1 FROM public.collection_overlay_keys)
                        AND NOT EXISTS (SELECT 1 FROM public.collection_spotlight)
                        AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE user_id = '00000000-0000-0000-0000-0000000000a1')$$,
    true, 'la suppression de A emporte collection, cases, clé, calque et profil');

SELECT 'conformité : tous les cas passent' AS verdict;
ROLLBACK;
