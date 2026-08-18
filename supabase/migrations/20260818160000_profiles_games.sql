-- Les jeux auxquels un compte declare jouer, et dans quel ordre.
--
-- Motivation : le selecteur de jeu alignait les huit jeux dans l'ordre du code,
-- le meme pour tout le monde. Quelqu'un qui ne joue qu'a Pokemon devait passer
-- devant sept jeux qui ne le concernent pas, a chaque fois. La preference est
-- donc portee par le COMPTE et non par l'appareil : elle suit l'utilisateur du
-- telephone au web, et survit a une reinstallation — comme sa collection, qui
-- vit deja ici.
--
-- INVARIANT — la presence de la ligne vaut reponse.
--   pas de ligne   → on n'a jamais pose la question, l'etape de choix s'affiche
--   games = '{}'   → la question a ete posee et l'utilisateur l'a passee
-- Sans cette distinction, « je ne declare aucun jeu » serait indiscernable de
-- « je n'ai pas encore repondu », et l'etape reviendrait a chaque lancement.
--
-- INVARIANT — l'ORDRE du tableau est l'information, pas seulement son contenu.
-- games[1] est le jeu que l'application ouvre. Ne jamais trier cette colonne
-- ni la dedupliquer cote base : c'est un choix de l'utilisateur, pas un
-- ensemble.
--
-- Aucune contrainte ne verifie que les identifiants sont des jeux connus, et
-- c'est delibere : une liste figee ici devrait etre reecrite a chaque jeu
-- ajoute, or une migration jouee ne se modifie pas (CLAUDE.md §IV.12). C'est
-- l'application qui ecarte a la lecture ce qu'elle ne connait pas — un jeu
-- retire du code laisse alors une ligne inerte, jamais une erreur.
--
-- La table s'appelle `profiles` plutot que `played_games` : elle porte les
-- preferences du compte, dont `games` est la premiere. Une table par
-- preference en multiplierait autant que de reglages.

BEGIN;

CREATE TABLE IF NOT EXISTS public.profiles (
    user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    games      text[] NOT NULL DEFAULT '{}',
    updated_at timestamptz NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.profiles IS
    'Preferences d''un compte. La presence de la ligne vaut reponse a l''etape de choix des jeux.';
COMMENT ON COLUMN public.profiles.games IS
    'Identifiants des jeux joues, dans l''ordre choisi. games[1] est le jeu ouvert au demarrage. Ordre significatif : ne pas trier.';

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Calque exact de `collections_owner` : restreinte a `authenticated`, parce
-- qu'un visiteur sans compte n'a pas de profil a faire valoir et que faire
-- evaluer la condition a `anon` lui ferait lire une colonne qui ne le regarde
-- pas (voir 20260815210000_owner_policies_for_authenticated.sql).
DROP POLICY IF EXISTS profiles_owner ON public.profiles;
CREATE POLICY profiles_owner
    ON public.profiles FOR ALL
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Le DELETE n'est pas accorde : une preference se vide, elle ne se supprime
-- pas — et effacer la ligne ferait reapparaitre l'etape de choix, ce que
-- l'invariant ci-dessus interdit. La suppression du compte emporte la ligne
-- par la cascade.
GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;

COMMIT;
