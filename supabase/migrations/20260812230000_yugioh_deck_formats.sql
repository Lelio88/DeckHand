-- Les formats de tournoi Yu-Gi-Oh entrent dans le corpus.
--
-- **Quatre formats rétro, et aucun format courant.** Mesuré sur un an chez
-- TopDeck.gg : Edison 3 069 decklists, Goat 485, REDU 320, HAT 81 — quand
-- `Advanced`, le format de tournoi courant, n'en a que **3 sur 168 tournois**.
-- 97 % du corpus est dans les formats rétro.
--
-- Ce n'est pas un manque, c'est ce qu'on voulait. Un format rétro puise dans un
-- pool figé et ancien : les cartes en sont largement disponibles et bon marché,
-- là où un format courant demande les raretés récentes que personne ne possède
-- par accident. C'est exactement le raisonnement qui fait du Pauper le format
-- prioritaire de Magic — et il vaut ici sans transposition.
--
-- `Genesys` (4 tournois) et `Domain` (0) n'ont aucune decklist : ils
-- n'entrent pas, faute de matière, et non par jugement.
--
-- Une contrainte `CHECK` se remplace, elle ne s'altère pas : `DROP` puis `ADD`,
-- dans la même transaction pour qu'aucune écriture ne passe entre les deux.

BEGIN;

ALTER TABLE public.decks
    DROP CONSTRAINT IF EXISTS decks_format_check;

ALTER TABLE public.decks
    ADD CONSTRAINT decks_format_check
    CHECK (format IN ('pauper', 'modern', 'commander', 'constructed',
                      'edison', 'goat', 'redu', 'hat'));

COMMENT ON COLUMN public.decks.format IS
    'Format de jeu. « pauper », « modern » et « commander » sont des formats '
    'Magic ; « constructed » est le format construit de Riftbound ; « edison », '
    '« goat », « redu » et « hat » sont les formats rétro de Yu-Gi-Oh, retenus '
    'sur le volume de decklists publiées et non sur leur notoriété. La colonne '
    '`game` reste ce qui cloisonne les catalogues — un format n''appartient '
    'qu''à un jeu, mais c''est une propriété de la donnée, pas une contrainte '
    'de schéma.';

COMMIT;
