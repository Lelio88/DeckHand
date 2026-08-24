-- Le prix qu'un compte paie reellement un booster, jeu par jeu.
--
-- Motivation : la page de profil sait dire « ce que ma collection aurait coute
-- en boosters achetes ». Ce chiffre est le seul du projet qu'aucune source ne
-- publie — il exige un prix de booster, et il n'en existe pas UN.
--
-- Releve le 2026-08-24, meme produit, meme jour :
--   Pokemon Mega-Evolution FR   4,99 EUR (Micromania)  vs  9,90 EUR (Play-in)
--   Magic Play Booster          5,29 EUR (par display) vs  7,40 EUR (a l'unite)
-- Soit pres du double d'ecart selon l'enseigne et la chaleur de l'extension.
-- Un nombre inscrit dans le code serait donc faux pour a peu pres tout le
-- monde, et faux SANS LE DIRE.
--
-- La TAILLE d'un booster, elle, reste dans le code : c'est un fait publie par
-- l'editeur, stable sur des annees, et identique pour tous. Seul le prix est
-- personnel — d'ou cette colonne et non une seconde table de reference.
--
-- INVARIANT — l'absence d'une clef vaut « je n'ai rien dit », pas « gratuit ».
-- L'application retombe alors sur son prix de reference. Un 0 explicite, lui,
-- est une reponse : il se lit « je ne les achete pas en booster ».
--
-- Forme : {"magic": 6.90, "pokemon": 4.99}. Un objet plutot que des colonnes
-- parce que le nombre de jeux bouge a chaque nouvelle source, et qu'une
-- migration jouee ne se modifie pas (CLAUDE.md §IV.12) : une colonne par jeu
-- en exigerait une nouvelle a chaque fois.
--
-- La politique `profiles_owner` est `FOR ALL` et porte sur la ligne, pas sur
-- les colonnes : elle couvre celle-ci sans etre rejouee.
--
-- Refs: page de profil, indicateurs defilants

BEGIN;

ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS booster_prices jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.profiles.booster_prices IS
    'Prix paye pour un booster, en euros, par identifiant de jeu : {"magic": 6.90}. '
    'Clef absente = pas de reponse, l''application retombe sur son prix de reference. '
    'Zero explicite = « je n''en achete pas », et se respecte.';

COMMIT;
