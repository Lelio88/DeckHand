-- Mise en conformité : supprimer son compte, fermer le calque aux inconnus,
-- ne pas garder les pseudos des spectateurs.
--
-- **1. Supprimer son compte, depuis l'application.** Google Play l'exige de
-- toute application à comptes, et la politique de confidentialité le promet.
-- `delete_my_account()` efface la ligne de `auth.users` de l'appelant ; tout le
-- reste suit par les clés étrangères, qui sont toutes en `ON DELETE CASCADE` :
-- `collections` (et avec elle `collection_items`, `collection_movements`,
-- `collection_spotlight`, `collection_overlay_keys`), `profiles`, et côté
-- GoTrue les identités et les sessions. Aucune table ne référence un
-- utilisateur sans cascade : la suppression ne peut pas échouer à mi-chemin.
-- `SECURITY DEFINER` parce que `authenticated` n'a aucun droit sur `auth.users` ;
-- l'identifiant vient du jeton (`auth.uid()`), jamais d'un paramètre, si bien
-- que chacun ne peut effacer que lui-même.
--
-- **2. Le calque n'écrit plus que sous la clé du bot.** Les trois fonctions
-- d'écriture (`public_request_spotlight`, `_page`, `_strip`) étaient accordées
-- à `anon` : qui connaissait l'adresse du classeur — elle est à l'antenne —
-- pouvait faire monter une carte possédée toutes les trente secondes, sous le
-- pseudo de son choix, sans passer par le chat ni par sa modération. Elles
-- deviennent internes, et trois portes `bot_request_*` les précèdent d'un
-- contrôle : la clé du calque de cette collection. Seule son **empreinte**
-- (SHA-256) est en base, dans une table que ni `anon` ni `authenticated` ne
-- lisent ; la clé elle-même vit dans le coffre du poste qui diffuse
-- (`../.deckhand-secrets/twitch.env`), posée par `python -m app.twitch.cle`.
-- Les verrous d'origine — collection publiée, case possédée, trente secondes —
-- restent ceux des fonctions internes : les portes n'en réécrivent aucun.
-- **La clé de service reste écartée** : elle contournerait la portée choisie
-- dans l'écran de partage, alors que la clé du calque n'ouvre que ces trois
-- écritures bornées. Une clé fausse et une collection fermée rendent le même
-- `false` que les refus d'origine.
--
-- **3. Les pseudos des spectateurs ne durent pas.** `collection_spotlight`
-- garde le pseudo Twitch du dernier demandeur ; le calque ne montre une
-- demande que dix minutes. Une tâche `pg_cron` efface chaque nuit les
-- demandes de plus de 24 heures, la durée qu'annonce la politique.
--
-- **4. Une inscription jamais confirmée non plus** : effacée après 7 jours.
--
-- Vérifié sous les rôles qui subissent les règles (`anon`, `authenticated`),
-- dans les deux sens, par `api/app/measure/conformite_rls.py`.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Supprimer son compte
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
    DELETE FROM auth.users WHERE id = v_uid;
END;
$$;

-- **Le journal ne suit pas une collection qui disparaît.** Le déclencheur de
-- `collection_items` inscrit chaque retrait dans `collection_movements`. Quand
-- la collection elle-même part en cascade — ce que fait toute suppression de
-- compte —, il inscrivait le retrait de chaque case dans le journal d'une
-- collection déjà effacée, et la clé étrangère faisait échouer la suppression
-- entière : aucun compte possédant une carte ne pouvait partir. Un retrait
-- dont la collection n'existe plus n'est pas un mouvement : il est ignoré.
CREATE OR REPLACE FUNCTION public.log_collection_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_delta integer;
BEGIN
    IF TG_OP = 'DELETE' AND NOT EXISTS (
        SELECT 1 FROM public.collections c WHERE c.id = OLD.collection_id
    ) THEN
        RETURN NULL;
    END IF;

    v_delta := CASE TG_OP
        WHEN 'INSERT' THEN NEW.quantity
        WHEN 'DELETE' THEN -OLD.quantity
        ELSE NEW.quantity - OLD.quantity
    END;

    -- Une mise à jour qui ne change pas la quantité — une date retouchée, une
    -- édition corrigée en place — n'est pas un mouvement.
    IF v_delta = 0 THEN
        RETURN NULL;
    END IF;

    INSERT INTO public.collection_movements
        (collection_id, oracle_id, print_id, is_foil, delta)
    VALUES (
        COALESCE(NEW.collection_id, OLD.collection_id),
        COALESCE(NEW.oracle_id, OLD.oracle_id),
        COALESCE(NEW.print_id, OLD.print_id),
        COALESCE(NEW.is_foil, OLD.is_foil),
        v_delta
    );

    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.delete_my_account() IS
    'Supprime le compte de l''appelant et, par cascade, tout ce qui s''y '
    'rattache. L''identifiant vient du jeton : chacun ne supprime que lui-même.';

-- Une fonction neuve est exécutable par PUBLIC tant qu'on ne le retire pas.
REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. La clé du calque
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.collection_overlay_keys (
    collection_id uuid PRIMARY KEY
        REFERENCES public.collections(id) ON DELETE CASCADE,
    -- SHA-256 de la clé. La clé est un jeton aléatoire de 256 bits : une
    -- empreinte sans sel suffit, il n'y a pas de dictionnaire à craindre.
    key_hash      bytea NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.collection_overlay_keys IS
    'Empreinte de la clé qui autorise le bot à écrire sur le calque de cette '
    'collection. Lue par les seules fonctions bot_request_* (DEFINER).';

-- **`collection_by_handle` ne convertit plus un nom en UUID.** Elle écrivait
-- `p_handle ~ '<uuid>' AND c.id = p_handle::uuid` dans un `OR` : rien ne
-- garantit l'ordre d'évaluation, et un plan qui passe par l'index de la clé
-- primaire calcule `p_handle::uuid` d'abord — une adresse par nom levait alors
-- « invalid input syntax for type uuid ». Observé sur une base neuve ; la
-- production choisit aujourd'hui un autre plan, ce qui ne protège de rien. Le
-- `CASE` impose l'ordre. La clé du calque passe par cette fonction.
CREATE OR REPLACE FUNCTION public.collection_by_handle(p_handle text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
    SELECT c.id
    FROM public.collections c
    WHERE c.is_public
      AND (
          c.slug = lower(trim(p_handle))
          -- L'UUID reste accepté : les liens déjà donnés continuent de vivre.
          OR c.id = CASE WHEN p_handle ~ '^[0-9a-fA-F-]{36}$' THEN p_handle::uuid END
      )
    LIMIT 1;
$function$;

ALTER TABLE public.collection_overlay_keys ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.collection_overlay_keys FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.overlay_key_matches(p_handle text, p_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.collection_overlay_keys k
        WHERE k.collection_id = public.collection_by_handle(p_handle)
          AND k.key_hash = sha256(convert_to(COALESCE(p_key, ''), 'UTF8'))
    );
$$;

REVOKE ALL ON FUNCTION public.overlay_key_matches(text, text)
    FROM PUBLIC, anon, authenticated;

-- Les trois écritures d'origine deviennent internes : seul leur propriétaire,
-- donc les portes ci-dessous, peut encore les appeler.
REVOKE EXECUTE ON FUNCTION
    public.public_request_spotlight(text, text, text, text, text)
    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION
    public.public_request_spotlight_page(text, text, integer, text, text)
    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION
    public.public_request_spotlight_strip(text, text, text, text, text)
    FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.bot_request_spotlight(
    p_key              text,
    p_handle           text,
    p_set_code         text,
    p_collector_number text,
    p_requested_by     text DEFAULT NULL,
    p_game             text DEFAULT 'magic'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT public.overlay_key_matches(p_handle, p_key) THEN
        RETURN false;
    END IF;
    RETURN public.public_request_spotlight(
        p_handle, p_set_code, p_collector_number, p_requested_by, p_game);
END;
$$;

CREATE OR REPLACE FUNCTION public.bot_request_spotlight_page(
    p_key          text,
    p_handle       text,
    p_set_code     text,
    p_page         integer,
    p_requested_by text DEFAULT NULL,
    p_game         text DEFAULT 'magic'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT public.overlay_key_matches(p_handle, p_key) THEN
        RETURN false;
    END IF;
    RETURN public.public_request_spotlight_page(
        p_handle, p_set_code, p_page, p_requested_by, p_game);
END;
$$;

CREATE OR REPLACE FUNCTION public.bot_request_spotlight_strip(
    p_key              text,
    p_handle           text,
    p_set_code         text,
    p_collector_number text,
    p_requested_by     text DEFAULT NULL,
    p_game             text DEFAULT 'magic'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT public.overlay_key_matches(p_handle, p_key) THEN
        RETURN false;
    END IF;
    RETURN public.public_request_spotlight_strip(
        p_handle, p_set_code, p_collector_number, p_requested_by, p_game);
END;
$$;

COMMENT ON FUNCTION public.bot_request_spotlight IS
    'Fait monter une case sur le calque, pour le bot seul : exige la clé du '
    'calque de la collection, puis applique les verrous de '
    'public_request_spotlight (publiée, possédée, 30 s).';
COMMENT ON FUNCTION public.bot_request_spotlight_page IS
    'Fait monter une page sur le calque, pour le bot seul (clé du calque, puis '
    'verrous de public_request_spotlight_page).';
COMMENT ON FUNCTION public.bot_request_spotlight_strip IS
    'Fait monter le tapis des versions, pour le bot seul (clé du calque, puis '
    'verrous de public_request_spotlight_strip).';

REVOKE ALL ON FUNCTION public.bot_request_spotlight(text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bot_request_spotlight_page(text, text, text, integer, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bot_request_spotlight_strip(text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_request_spotlight(text, text, text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_request_spotlight_page(text, text, text, integer, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_request_spotlight_strip(text, text, text, text, text, text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Les pseudos des spectateurs ne durent pas
-- ---------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- `cron.schedule` remplace une tâche du même nom : rejouer ce fichier ne la
-- double pas.
SELECT cron.schedule(
    'deckhand-purge-calque',
    '23 4 * * *',
    $$DELETE FROM public.collection_spotlight
      WHERE requested_at < NOW() - INTERVAL '24 hours'$$
);

-- ---------------------------------------------------------------------------
-- 4. Une inscription jamais confirmée ne dure pas
-- ---------------------------------------------------------------------------
--
-- La confirmation par courriel est désormais exigée (`push_auth_config.py`).
-- Une adresse mal tapée, ou celle d'un tiers, laisse alors un compte que
-- personne n'ouvrira : il est effacé au bout de 7 jours, la durée
-- qu'annonce la politique. **Jamais confirmé et jamais connecté** : les
-- comptes nés avant la confirmation l'ont été d'office et se sont connectés,
-- et un compte Google arrive confirmé — aucun ne peut être visé.
SELECT cron.schedule(
    'deckhand-purge-inscriptions',
    '41 4 * * *',
    $$DELETE FROM auth.users
      WHERE email_confirmed_at IS NULL
        AND last_sign_in_at IS NULL
        AND created_at < NOW() - INTERVAL '7 days'$$
);

COMMIT;
