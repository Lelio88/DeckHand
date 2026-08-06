-- 013 — Supprime l'ancienne signature de `deck_suggestions`.
--
-- **Le piège** : `CREATE OR REPLACE FUNCTION` ne remplace une fonction que si la
-- signature est **identique**. Ajouter un paramètre crée une seconde fonction
-- qui coexiste avec la première.
--
-- PostgREST se retrouve alors incapable de choisir entre les deux et répond
-- HTTP 300 / PGRST203 sur **tous** les appels, y compris ceux qui
-- fonctionnaient avant. L'écran des decks devient inutilisable, sans qu'aucune
-- migration n'ait échoué : `supabase db push` avait rapporté un succès.
--
-- À retenir pour toute évolution d'une fonction exposée à l'API : ajouter un
-- paramètre impose de supprimer explicitement l'ancienne signature dans la même
-- migration.

BEGIN;

DROP FUNCTION IF EXISTS public.deck_suggestions(text, integer, integer);

COMMIT;
