-- Un assistant IA agit sur la collection, jamais sur le compte.
--
-- **Pourquoi une garde en base.** Un assistant (claude.ai, Claude Code…) reçoit
-- du serveur OAuth de Supabase un jeton d'accès qui est un jeton d'utilisateur
-- ordinaire, `role` `authenticated`, plus une revendication `client_id`. Il le
-- présente au serveur MCP (`supabase/functions/mcp/`), dont les outils ne font
-- que lire la collection et y ajouter ou retirer des cartes. Mais rien n'oblige
-- son détenteur à passer par ces outils : PostgREST l'accepte tel quel, avec
-- les droits complets du titulaire. Les *scopes* OAuth n'y changent rien — ils
-- ne règlent que les informations d'identité. C'est donc à la base de dire ce
-- qu'un jeton d'assistant ne fait pas, quel que soit le chemin qu'il prend.
--
-- L'inscription des clients est ouverte (c'est ainsi qu'un assistant se
-- présente) : une application malveillante qui se fait passer pour un
-- assistant obtient ce jeton au premier « Autoriser » donné par erreur. La
-- garde borne ce qu'elle en tire.
--
-- **Ce qu'un jeton d'assistant ne fait pas** — rien de ce qui touche au compte
-- plutôt qu'aux cartes :
--
-- 1. supprimer le compte (`delete_my_account`) ;
-- 2. modifier ou effacer la ligne `collections` : c'est elle qui publie un
--    classeur (`is_public`, `slug`, portée), et l'effacer emporterait toute la
--    collection par cascade. L'**insertion** reste permise : le premier ajout
--    d'un nouveau compte crée sa collection (`ensure_my_collection`).
--
-- **Ce qu'il fait** : lire et modifier `collection_items` (choix de
-- l'utilisateur : l'agent écrit directement, §IV.8 de `CLAUDE.md`), sous les
-- mêmes politiques que l'application. Déjà fermé à tout jeton
-- `authenticated`, et donc à l'assistant : la clé du calque
-- (`collection_overlay_keys`), le journal en écriture (`collection_movements`,
-- lecture seule), les écritures du calque (`public_request_*`). Mot de passe et
-- adresse relèvent de GoTrue, qui exige une réidentification pour le premier
-- et une double confirmation pour la seconde.
--
-- **Le test d'un jeton d'assistant** est `auth.jwt() ->> 'client_id'` non nul :
-- l'application, elle, reçoit ses jetons sans `client_id`.
--
-- Vérifié dans les deux sens par `supabase/tests/assistant.test.sql`.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. La suppression du compte refuse un jeton d'assistant
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.delete_my_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'aucun compte connecté' USING ERRCODE = '42501';
    END IF;
    IF (auth.jwt() ->> 'client_id') IS NOT NULL THEN
        RAISE EXCEPTION 'un assistant ne supprime pas de compte' USING ERRCODE = '42501';
    END IF;
    DELETE FROM auth.users WHERE id = v_uid;
END;
$$;

COMMENT ON FUNCTION public.delete_my_account() IS
    'Supprime le compte de l''appelant et, par cascade, tout ce qui s''y '
    'rattache. L''identifiant vient du jeton : chacun ne supprime que lui-même. '
    'Refusé à un jeton d''assistant (client_id).';

-- `CREATE OR REPLACE` conserve les droits ; rappelés pour qu'ils se lisent ici.
REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. La ligne de collection ne se modifie ni ne s'efface sous un jeton
--    d'assistant
-- ---------------------------------------------------------------------------

-- RESTRICTIVE : s'ajoute en ET à `collections_owner`, sans la réécrire. Une
-- mise à jour ou une suppression refusée touche zéro ligne, sans erreur — c'est
-- le comportement ordinaire de la RLS.
DROP POLICY IF EXISTS collections_assistant_no_update ON public.collections;
CREATE POLICY collections_assistant_no_update
    ON public.collections
    AS RESTRICTIVE
    FOR UPDATE
    TO authenticated
    USING ((auth.jwt() ->> 'client_id') IS NULL);

DROP POLICY IF EXISTS collections_assistant_no_delete ON public.collections;
CREATE POLICY collections_assistant_no_delete
    ON public.collections
    AS RESTRICTIVE
    FOR DELETE
    TO authenticated
    USING ((auth.jwt() ->> 'client_id') IS NULL);

COMMIT;
