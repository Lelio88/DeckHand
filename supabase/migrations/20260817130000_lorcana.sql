-- Disney Lorcana rejoint les jeux connus.
--
-- **Septième jeu, et le catalogue le plus propre rencontré.** Là où Yu-Gi-Oh et
-- Pokémon ont coûté une réingestion complète pour une identité mal choisie, et
-- où Wankul a demandé trois pièges désamorcés avant la première écriture, Lorcast
-- publie 3 192 cartes dont **aucune n'est sans illustration**, **aucune ne
-- fusionne** sous l'identifiant de la source, et **toutes portent leur prix**.
--
-- Ce que `lorcana` range dans les colonnes existantes, et pourquoi :
--
-- - `layout` porte le **type de carte** — `Character` (2 453), `Action` (406),
--   `Item` (227), `Song` (174), `Location` (106). C'est la sixième fois que
--   cette colonne sert à cela, et la première où elle décide de l'orientation
--   sans ambiguïté : la source publie aussi un champ `layout` valant `normal`
--   ou `landscape`, et **les 106 `landscape` sont exactement les 106 `Location`**
--   — mesuré, les deux ensembles étant identiques carte par carte. Un seul axe
--   suffit donc, et c'est le type qui est retenu : le constructeur en a besoin
--   pour doser, l'orientation s'en déduit.
--
-- - `color_identity` porte l'**encre** (Amber, Amethyst, Emerald, Ruby,
--   Sapphire, Steel), qui contraint réellement la construction : un deck ne se
--   joue qu'en deux encres. C'est le cas SWU et One Piece, non le cas Yu-Gi-Oh
--   — où l'Attribut ressemblait à une identité de couleur sans rien imposer.
--   160 cartes n'en portent aucune ; elles restent constructibles, la contrainte
--   ne s'appliquant qu'à celles qui en ont une.
--
-- - `cmc` porte le **coût en encre**, un vrai coût de mise en jeu.
--
-- **`lorcana_core` et non `core`**, bien que la source nomme ainsi son unique
-- format. `DeckBlueprint.of` ne reçoit que le format, jamais le jeu : partager
-- un identifiant ferait construire un deck Lorcana sur les proportions d'un
-- autre jeu sans que rien ne l'annonce. Même raison que `op_standard`,
-- `premier` et `tournament`.
--
-- **Le format est le seul, et il est déclaré.** `legalities.core` vaut `legal`
-- pour 2 940 cartes, `not_legal` pour 250 et `banned` pour 2. Contrairement à
-- One Piece — dont la source ne publie aucun format et où le rangement est un
-- défaut assumé —, ici la source dit précisément ce qui est jouable, et le
-- constructeur pourra s'y fier.
--
-- L'horodatage suit la migration One Piece (`20260817120000`) : une base rejouée
-- depuis zéro verrait sinon un fichier antérieur reprendre ce qu'un fichier
-- postérieur a ajouté, et le dernier jeu déclaré effacerait les précédents.

BEGIN;

ALTER TABLE public.cards DROP CONSTRAINT IF EXISTS cards_game_known;
ALTER TABLE public.cards
    ADD CONSTRAINT cards_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon', 'wankul', 'swu',
                    'onepiece', 'lorcana'));

ALTER TABLE public.decks
    DROP CONSTRAINT IF EXISTS decks_game_known;
ALTER TABLE public.decks
    ADD CONSTRAINT decks_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon', 'wankul', 'swu',
                    'onepiece', 'lorcana'));

ALTER TABLE public.decks DROP CONSTRAINT IF EXISTS decks_format_check;
ALTER TABLE public.decks ADD CONSTRAINT decks_format_check CHECK (
    format = ANY (ARRAY[
        'pauper', 'modern', 'commander',     -- Magic
        'constructed',                       -- Riftbound
        'edison', 'goat', 'redu', 'hat',     -- Yu-Gi-Oh
        'standard', 'glc', 'expanded', 'ex', -- Pokémon
        'premier',                           -- Star Wars Unlimited
        'op_standard',                       -- One Piece
        'lorcana_core'                       -- Disney Lorcana
    ])
);

COMMIT;
