-- One Piece rejoint les jeux connus.
--
-- **Deux lignes de contrainte, comme les cinq jeux précédents.** L'inventaire de
-- #22 le prévoyait et cinq ajouts l'ont vérifié : les notions structurantes du
-- modèle sont génériques, un jeu de plus ne demande que l'autorisation
-- d'exister.
--
-- Ce que `onepiece` range dans les colonnes existantes, et pourquoi :
--
-- - `layout` porte le **type de carte** — `Character`, `Event`, `Leader`,
--   `Stage`. Contrairement aux cinq autres jeux, il ne décide **pas** de la
--   fenêtre d'illustration : `--compare` a montré que les quatre fenêtres sont
--   interchangeables, toutes les paires restant entre 14 et 21 bits pour un
--   seuil de confiance à 12. Une seule fenêtre sert le jeu entier. `layout` y
--   reste utile au constructeur, qui dose ces familles.
-- - `color_identity` porte la **couleur** (Red, Green, Blue, Purple, Black,
--   Yellow), qui contraint réellement la construction : un deck se joue dans
--   les couleurs de son leader. C'est le cas SWU, non le cas Yu-Gi-Oh — où
--   l'Attribut ressemblait à une identité de couleur sans rien imposer.
-- - `cmc` porte le **coût en DON!!**, un vrai coût de mise en jeu. Les 285
--   Leaders n'en ont pas : ils portent une vie, et la colonne étant
--   `NOT NULL DEFAULT 0`, leur zéro se lira « gratuit ». Même limite que les
--   Bases de SWU, et de même ampleur.
--
-- **Le format est mesuré, et il est muet.** Sur 500 tournois relevés chez
-- Limitless, **474 ne déclarent aucun format** — c'est le format standard
-- implicite du jeu, qui n'en a qu'un. `CUSTOM` (15) et `EXTRA` (11) sont des
-- variantes maison, écartées pour la raison que Pokémon a déjà écrite : un deck
-- ainsi étiqueté ne dit pas avec quelles cartes il peut être rejoué, ce qui est
-- précisément ce que le calcul de complétion doit savoir.
--
-- **`op_standard` et non `standard`**, bien que le jeu nomme ainsi son format :
-- `DeckBlueprint.of` ne reçoit que le format, jamais le jeu, et partager
-- l'identifiant avec Pokémon ferait construire un deck One Piece sur les
-- proportions d'un autre jeu sans que rien ne l'annonce. C'est la raison pour
-- laquelle Wankul porte `tournament` et SWU `premier`.
--
-- L'horodatage suit la dernière migration qui redéfinit ces contraintes
-- partagées (`20260817110000_swu.sql`) : une base rejouée depuis zéro verrait
-- sinon un fichier antérieur reprendre ce qu'un fichier postérieur a ajouté,
-- sans lever d'erreur.
--
-- Refs: #22

BEGIN;

ALTER TABLE public.cards
    DROP CONSTRAINT IF EXISTS cards_game_known;
ALTER TABLE public.cards
    ADD CONSTRAINT cards_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon', 'wankul', 'swu',
                    'onepiece'));

ALTER TABLE public.decks
    DROP CONSTRAINT IF EXISTS decks_game_known;
ALTER TABLE public.decks
    ADD CONSTRAINT decks_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon', 'wankul', 'swu',
                    'onepiece'));

ALTER TABLE public.decks DROP CONSTRAINT IF EXISTS decks_format_check;
ALTER TABLE public.decks ADD CONSTRAINT decks_format_check CHECK (
    format = ANY (ARRAY[
        'pauper', 'modern', 'commander',     -- Magic
        'constructed',                       -- Riftbound
        'edison', 'goat', 'redu', 'hat',     -- Yu-Gi-Oh
        'standard', 'glc', 'expanded', 'ex', -- Pokémon
        'premier',                           -- Star Wars Unlimited
        'op_standard'                        -- One Piece
    ])
);

COMMIT;
