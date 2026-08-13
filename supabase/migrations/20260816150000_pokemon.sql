-- Pokémon rejoint les jeux connus.
--
-- **Deux lignes, et c'est tout ce que le schéma demande.** L'inventaire de #22
-- l'annonçait et Yu-Gi-Oh l'avait confirmé : les notions structurantes du modèle
-- — impressions, collection, légalités en `jsonb`, identité de couleur en
-- tableau — sont génériques. Un quatrième jeu ne demande aucune refonte, juste
-- l'autorisation d'exister.
--
-- Ce que `pokemon` range dans les colonnes existantes, et pourquoi :
--
-- - `cmc` et `mana_cost` portent les **PV**. Ce jeu n'a pas de coût
--   d'invocation ; les PV sont la seule grandeur numérique qui gradue une carte,
--   et ce que l'utilisateur lit en haut du cadre.
-- - `color_identity` porte le **type d'énergie** (Grass, Fire, Water…). Même
--   nature, même usage qu'en Magic : c'est lui qui décide de l'énergie qu'un
--   deck doit embarquer.
-- - `layout` porte le **gabarit d'illustration** mesuré par #28 — `pokemon`,
--   `trainer`, `full`, `energy`, `special-energy` —, exactement comme il porte
--   le `frameType` de Yu-Gi-Oh et l'orientation de Riftbound.
--
-- Aucun format de deck n'est ajouté ici : le corpus Limitless n'est pas ingéré,
-- et déclarer un format sans listes referait l'erreur que Yu-Gi-Oh a payée en
-- annonçant `Advanced` sur la foi de son nom.

BEGIN;

ALTER TABLE public.cards
    DROP CONSTRAINT IF EXISTS cards_game_known;
ALTER TABLE public.cards
    ADD CONSTRAINT cards_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon'));

ALTER TABLE public.decks
    DROP CONSTRAINT IF EXISTS decks_game_known;
ALTER TABLE public.decks
    ADD CONSTRAINT decks_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon'));

COMMIT;
