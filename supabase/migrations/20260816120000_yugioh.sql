-- Accueil d'un troisième jeu : Yu-Gi-Oh.
--
-- Motivation : les contraintes `cards_game_known` et `decks_game_known`
-- énumèrent les jeux couverts. C'est délibéré — une colonne `game` libre
-- laisserait une faute de frappe créer un catalogue fantôme que rien
-- n'afficherait —, et le prix en est une migration par jeu ajouté.
--
-- Rien d'autre ne change. L'inventaire de `docs/multi-game.md` tient : les
-- notions structurantes du modèle — légalités en jsonb, identité de couleur en
-- tableau, impressions, collection — sont génériques ou extensibles. Un
-- troisième jeu ne demande aucune refonte, et c'est ce que cette migration
-- d'une ligne par table démontre.
--
-- `decks.format` n'est pas touchée : les formats Yu-Gi-Oh dont le corpus sera
-- réellement importé se mesurent sur la source (#27), et une contrainte
-- inventée d'avance vaut moins qu'une contrainte ajoutée quand la donnée
-- existe. C'est la règle déjà suivie pour Riftbound.
--
-- Refs: #25

BEGIN;

ALTER TABLE public.cards
    DROP CONSTRAINT IF EXISTS cards_game_known;

ALTER TABLE public.cards
    ADD CONSTRAINT cards_game_known CHECK (game IN ('magic', 'riftbound', 'yugioh'));

ALTER TABLE public.decks
    DROP CONSTRAINT IF EXISTS decks_game_known;

ALTER TABLE public.decks
    ADD CONSTRAINT decks_game_known CHECK (game IN ('magic', 'riftbound', 'yugioh'));

COMMIT;
