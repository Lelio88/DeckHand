-- Wankul rejoint les jeux connus.
--
-- **Deux lignes, comme les trois jeux précédents.** L'inventaire de #22 le
-- prévoyait et trois ajouts l'ont vérifié : les notions structurantes du modèle
-- sont génériques, un jeu de plus ne demande que l'autorisation d'exister.
--
-- Ce que `wankul` range dans les colonnes existantes, et pourquoi :
--
-- - `type_line` porte **Personnage** ou **Terrain**, les deux seuls types du
--   jeu. C'est la coupe la plus courte des cinq jeux, et elle suffit : un deck
--   se compose de 10 terrains et de 40 personnages.
-- - `layout` portera l'**effigie** (Laink, Terracid, Guest) si le catalogue la
--   sert — même usage que le `frameType` de Yu-Gi-Oh et le gabarit de #28 : une
--   propriété qui décide de la mise en page, donc de la fenêtre d'illustration.
-- - `cmc`, `mana_cost` et `color_identity` restent **vides**. Ce jeu n'a ni coût
--   d'invocation, ni couleur : les remplir d'un analogue de forme referait
--   l'erreur mesurée sur Yu-Gi-Oh, où l'Attribut rangé dans `color_identity`
--   aurait écarté 32 % du catalogue sur une règle inexistante.
--
-- **Aucun prix ne viendra, et ce n'est pas un retard.** Les quatre autres jeux
-- sont cotés parce qu'ils ont un marché secondaire indexé, relevé par TCGCSV.
-- Wankul se vend en direct par son éditeur ; il n'existe aucune cote carte par
-- carte. `price_eur` restera donc nul, et l'écran des comptes le dit.
--
-- Aucun format de deck n'est déclaré ici : il n'existe aucun corpus de listes
-- publiées pour ce jeu. Déclarer `tournament` sans decks referait l'erreur que
-- Yu-Gi-Oh a payée en annonçant `Advanced` sur la foi de son nom.

BEGIN;

ALTER TABLE public.cards
    DROP CONSTRAINT IF EXISTS cards_game_known;
ALTER TABLE public.cards
    ADD CONSTRAINT cards_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon', 'wankul'));

ALTER TABLE public.decks
    DROP CONSTRAINT IF EXISTS decks_game_known;
ALTER TABLE public.decks
    ADD CONSTRAINT decks_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon', 'wankul'));

COMMIT;
