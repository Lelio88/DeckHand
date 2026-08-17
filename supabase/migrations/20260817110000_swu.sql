-- Star Wars Unlimited rejoint les jeux connus.
--
-- **Deux lignes de contrainte, comme les quatre jeux précédents.** L'inventaire
-- de #22 le prévoyait et quatre ajouts l'ont vérifié : les notions
-- structurantes du modèle sont génériques, un jeu de plus ne demande que
-- l'autorisation d'exister.
--
-- Ce que `swu` range dans les colonnes existantes, et pourquoi :
--
-- - `layout` porte le **type de carte** — `Unit`, `Event`, `Upgrade`, `Leader`,
--   `Base`. C'est lui, et lui seul, qui décide de la fenêtre d'illustration :
--   mesuré, un Event porte la sienne **en bas** quand une Unit la porte en
--   haut, et un Leader est imprimé en travers. Même usage que le `frameType` de
--   Yu-Gi-Oh, le gabarit de Pokémon et l'effigie de Wankul.
-- - `color_identity` porte les **aspects**, et c'est légitime **parce que
--   mesuré** : 79,1 % des decks du corpus tiennent entièrement dans les aspects
--   de leur leader et de leur base, la part hors aspect ayant une médiane de
--   0,0 %. Yu-Gi-Oh a montré l'inverse — son Attribut ressemble à une identité
--   de couleur et n'impose aucune contrainte, si bien qu'y filtrer écartait
--   32 % du catalogue sur une règle inexistante. Ici la contrainte existe : le
--   jeu pénalise le hors-aspect de deux ressources.
-- - `cmc` porte le **coût en ressources**, qui est un vrai coût de mise en jeu.
--
-- **Le format est mesuré, pas déduit d'un nom.** `premier` couvre 19 tournois
-- sur 20 dans le corpus relevé, tous officiels ; le vingtième n'en déclare
-- aucun. Yu-Gi-Oh a payé la déduction inverse : `Advanced` y avait été déclaré
-- parce qu'il porte le nom du format courant du jeu, et ne comptait que trois
-- decklists sur 168 tournois — un onglet vide, sur un écran qui a l'air en
-- panne alors qu'il dit vrai.
--
-- L'horodatage suit la dernière migration qui redéfinit ces contraintes
-- partagées (`20260817090000_wankul.sql`) : une base rejouée depuis zéro verrait
-- sinon un fichier antérieur reprendre ce qu'un fichier postérieur a ajouté,
-- sans lever d'erreur.
--
-- Refs: #22

BEGIN;

ALTER TABLE public.cards
    DROP CONSTRAINT IF EXISTS cards_game_known;
ALTER TABLE public.cards
    ADD CONSTRAINT cards_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon', 'wankul', 'swu'));

ALTER TABLE public.decks
    DROP CONSTRAINT IF EXISTS decks_game_known;
ALTER TABLE public.decks
    ADD CONSTRAINT decks_game_known
    CHECK (game IN ('magic', 'riftbound', 'yugioh', 'pokemon', 'wankul', 'swu'));

ALTER TABLE public.decks DROP CONSTRAINT IF EXISTS decks_format_check;
ALTER TABLE public.decks ADD CONSTRAINT decks_format_check CHECK (
    format = ANY (ARRAY[
        'pauper', 'modern', 'commander',    -- Magic
        'constructed',                      -- Riftbound
        'edison', 'goat', 'redu', 'hat',    -- Yu-Gi-Oh
        'standard', 'glc', 'expanded', 'ex', -- Pokémon
        'premier'                           -- Star Wars Unlimited
    ])
);

-- SWU Meta Stats ne publie aucune condition d'utilisation (404 sur `/terms`) et
-- documente une API publique sans clé : le garde-fou §IV.9 lui applique donc
-- celles de Scryfall, dont l'attribution visible.
INSERT INTO public.deck_sources (id, display_name, url, attribution_required,
                                 attribution_text)
VALUES ('swumetastats', 'SWU Meta Stats', 'https://swumetastats.com', true,
        'Données de tournoi fournies par SWU Meta Stats')
ON CONFLICT (id) DO UPDATE SET
    display_name         = EXCLUDED.display_name,
    url                  = EXCLUDED.url,
    attribution_required = EXCLUDED.attribution_required,
    attribution_text     = EXCLUDED.attribution_text;

COMMIT;
