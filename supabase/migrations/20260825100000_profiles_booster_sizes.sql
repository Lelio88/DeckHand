-- Le nombre de cartes qu'un compte ouvre reellement par booster, jeu par jeu.
--
-- Motivation : la migration 20260824100000 a rendu le PRIX personnel et a
-- explicitement garde la TAILLE dans le code, au motif que « c'est un fait
-- publie par l'editeur, stable sur des annees, et identique pour tous ».
-- Cette phrase est fausse des qu'on regarde un rayon : un meme jeu vend
-- plusieurs produits a des contenus differents — Magic vend un Play Booster a
-- 14 cartes, un Collector a 15, un Set a 12 — et le code lui-meme l'admettait
-- deja sans en tirer la consequence, le commentaire de `onepiece` disant « les
-- boosters japonais font 6 a 9 cartes ; c'est le format francais qui est
-- retenu ». Retenir un format, c'est choisir pour quelqu'un d'autre.
--
-- Les deux nombres sont donc de meme nature : un repere date et source dans le
-- code, remplacable par celui qui sait ce qu'il achete.
--
-- INVARIANT — l'absence d'une clef vaut « je n'ai rien dit », pas « zero ».
-- L'application retombe alors sur la taille de reference du jeu.
--
-- INVARIANT — zero n'est PAS une reponse ici, au contraire du prix. Un booster
-- a zero carte ne decrit aucun produit, et les deux indicateurs qui s'en
-- servent divisent par ce nombre. La contrainte le refuse en base, la saisie le
-- refuse a l'ecran, et la lecture Dart l'ecarte une troisieme fois : une valeur
-- peut arriver d'un client tiers ou d'une base editee a la main.
--
-- Forme : {"magic": 15, "pokemon": 10}. Un objet plutot que des colonnes pour
-- la meme raison que `booster_prices` : le nombre de jeux bouge a chaque
-- nouvelle source, et une migration jouee ne se modifie pas (CLAUDE.md §IV.12).
--
-- La politique `profiles_owner` est `FOR ALL` et porte sur la ligne, pas sur
-- les colonnes : elle couvre celle-ci sans etre rejouee.
--
-- Refs: page de profil, indicateurs defilants

BEGIN;

ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS booster_sizes jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Le garde-fou vit ici et pas seulement dans l'application : c'est le seul
-- endroit qu'un client tiers ne peut pas contourner.
--
-- POURQUOI UNE FONCTION plutot qu'un CHECK ecrit en clair : parcourir les
-- entrees d'un jsonb demande `jsonb_each`, qui rend un ensemble, donc une
-- sous-requete — et Postgres refuse « cannot use subquery in check
-- constraint ». Une fonction IMMUTABLE l'encapsule. Elle l'est reellement :
-- elle ne lit aucune table et ne depend que de son argument.
--
-- `search_path` vide et fonctions qualifiees : une fonction appelee depuis une
-- contrainte s'execute avec le search_path de l'appelant, quel qu'il soit.
CREATE OR REPLACE FUNCTION public.booster_sizes_are_positive(v jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO ''
AS $$
    SELECT pg_catalog.jsonb_typeof(v) = 'object'
       AND NOT EXISTS (
           SELECT 1
           FROM pg_catalog.jsonb_each(v) AS e(key, value)
           WHERE pg_catalog.jsonb_typeof(e.value) <> 'number'
              OR (e.value)::numeric < 1
       );
$$;

COMMENT ON FUNCTION public.booster_sizes_are_positive(jsonb) IS
    'Vraie quand chaque valeur de l''objet est un nombre >= 1. Sert la contrainte '
    'de profiles.booster_sizes ; un objet vide passe, c''est le defaut.';

-- `jsonb_each` sur un objet vide ne rend aucune ligne, donc le defaut passe.
ALTER TABLE public.profiles
    DROP CONSTRAINT IF EXISTS profiles_booster_sizes_positive;

ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_booster_sizes_positive
        CHECK (public.booster_sizes_are_positive(booster_sizes));

COMMENT ON COLUMN public.profiles.booster_sizes IS
    'Cartes par booster reellement ouvert, par identifiant de jeu : {"magic": 15}. '
    'Clef absente = pas de reponse, l''application retombe sur la taille de reference. '
    'Zero et negatifs sont refuses : ils ne decrivent aucun produit et diviseraient '
    'par zero les indicateurs en boosters.';

COMMIT;
