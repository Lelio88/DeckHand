-- Le format construit de Riftbound entre dans le corpus.
--
-- **Pourquoi la contrainte n'avait pas été élargie plus tôt.** L'annexe
-- multi-jeu le disait : « les formats Riftbound ne sont pas connus, et une
-- contrainte inventée d'avance vaut moins qu'une contrainte ajoutée quand la
-- donnée existera ». La donnée existe : TopDeck.gg — la source déjà employée
-- pour Magic, sous la même clé et la même obligation d'attribution — sert
-- 159 tournois Riftbound, dont 59 portent des decklists, pour 2 501
-- participations documentées. Son libellé de format est `Constructed`.
--
-- `Sealed` répond aussi (13 tournois), mais un format scellé ne se confronte
-- pas à une collection : on y joue ce que la boîte donne. Il n'entre donc pas
-- dans le corpus, et la contrainte ne l'accueille pas.
--
-- Une contrainte `CHECK` se remplace, elle ne s'altère pas : `DROP` puis `ADD`,
-- dans la même transaction pour qu'aucune écriture ne passe entre les deux.

BEGIN;

ALTER TABLE public.decks
    DROP CONSTRAINT IF EXISTS decks_format_check;

ALTER TABLE public.decks
    ADD CONSTRAINT decks_format_check
    CHECK (format IN ('pauper', 'modern', 'commander', 'constructed'));

COMMENT ON COLUMN public.decks.format IS
    'Format de jeu. Les trois premiers sont des formats Magic ; « constructed » '
    'est le format construit de Riftbound. La colonne `game` reste ce qui '
    'cloisonne les catalogues — un format n''appartient qu''à un jeu, mais '
    'c''est une propriété de la donnée, pas une contrainte de schéma.';

COMMIT;
