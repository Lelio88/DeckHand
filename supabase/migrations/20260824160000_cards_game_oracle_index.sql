-- Compter les empreintes d'un jeu ne doit pas relire 32 918 cartes entieres.
--
-- Motivation : `art_hash_count` depassait le `statement_timeout` de TROIS
-- secondes du role `anon` — mesure en tentant de rapatrier l'index depuis un
-- banc, qui n'ouvre pas de session. Sous `authenticated` (huit secondes) elle
-- passait, ce qui la rendait invisible : l'application l'appelle a CHAQUE
-- ouverture de l'ecran de scan, pour verifier la fraicheur de son cache.
--
-- Le plan disait tout, et rien n'etait sur disque (`shared hit=5742`, aucune
-- lecture) :
--
--   Aggregate                                    1929 ms
--     Hash Join
--       Seq Scan on art_hashes                     15 ms
--       Hash
--         Bitmap Heap Scan on cards              1600 ms   <-- ici
--           Bitmap Index Scan on idx_cards_game
--
-- `idx_cards_game` porte le jeu mais PAS `oracle_id` : Postgres trouve les
-- lignes par l'index puis va chercher chacune dans la table — 4 835 blocs — pour
-- n'en lire qu'une colonne. Les lignes de `cards` sont larges (nom, texte,
-- types), d'ou le prix.
--
-- L'index composite (game, oracle_id) rend le parcours *index-only* : la
-- colonne voulue est dans l'index, la table n'est plus touchee.
--
-- Il sert aussi `art_hash_page`, qui fait exactement la meme jointure page par
-- page — cinquante fois par telechargement d'index.
--
-- `idx_cards_game` n'est PAS supprime : un index composite sert les requetes
-- qui ne filtrent que sur `game`, mais il est plus large, et rien ne presse de
-- retirer un index qui ne coute que de l'espace. A reexaminer si l'ecriture du
-- catalogue ralentit.
--
-- Pas de CONCURRENTLY : `cards` n'est ecrite que par l'ingestion, lancee a la
-- main. Le garder dans la transaction vaut mieux qu'un index a moitie construit.
--
-- Refs: #32, analyse d'une VOD ; chantier d'optimisation du 2026-08-24

BEGIN;

CREATE INDEX IF NOT EXISTS idx_cards_game_oracle
    ON public.cards (game, oracle_id);

COMMENT ON INDEX public.idx_cards_game_oracle IS
    'Parcours index-only pour art_hash_count et art_hash_page : sans lui, '
    'compter les empreintes d''un jeu relit 32 918 lignes de cards en entier.';

COMMIT;
