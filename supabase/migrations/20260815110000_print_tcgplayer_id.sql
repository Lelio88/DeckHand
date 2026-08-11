-- L'identifiant marchand d'une impression, reçu et jusqu'ici jeté.
--
-- **Ce que ça débloque.** Riftbound n'a aucun prix : `price_eur` et ses trois
-- jumelles sont vides pour les 1 451 impressions, si bien que la collection ne
-- se valorise pas et qu'un deck ne se chiffre pas. Riftcodex ne sert pas de
-- prix, mais il sert le **`tcgplayer_id`** de chaque impression — le chaînon
-- vers une source qui, elle, en sert. L'ingestion le recevait déjà et le
-- jetait faute de colonne où l'écrire.
--
-- **Mesuré à la source, pas déduit** : 1 224 impressions sur 1 451 en portent
-- un (84,4 %), 1 223 valeurs distinctes. Les 227 manquantes sont **toutes** de
-- l'extension `VEN`, publiée le 31 juillet 2026 : ce n'est pas un trou de
-- couverture réparti, c'est une extension trop récente pour être cotée. Elle
-- recevra ses identifiants quand elle atteindra le marché.
--
-- **Pourquoi une colonne générique et pas `riftbound_tcgplayer_id`.**
-- TCGplayer numérote les cartes de tous ses jeux dans le même espace, Magic
-- compris : Scryfall publie le même identifiant. La colonne accueillera donc le
-- catalogue Magic le jour où quelque chose en aura besoin, sans migration de
-- plus. Elle reste vide pour lui aujourd'hui — remplir 167 000 impressions
-- demanderait une réingestion complète pour un jeu qui a déjà ses prix.
--
-- Nullable et sans contrainte d'unicité : une impression peut légitimement ne
-- pas être cotée, et deux impressions partagent déjà un identifiant à la source
-- (1 223 valeurs pour 1 224 lignes). Refuser le doublon rejetterait une donnée
-- exacte au motif qu'elle nous surprend.

BEGIN;

ALTER TABLE public.card_prints
    ADD COLUMN IF NOT EXISTS tcgplayer_id integer;

COMMENT ON COLUMN public.card_prints.tcgplayer_id IS
    'Identifiant TCGplayer de l''impression, tel que servi par la source du '
    'catalogue. Sert de chaînage vers une source de prix ; ne porte aucun prix '
    'par lui-même.';

-- Un index, parce que l'usage prévu est la jointure inverse : partant d'un
-- relevé de prix indexé par identifiant marchand, retrouver l'impression.
CREATE INDEX IF NOT EXISTS idx_card_prints_tcgplayer
    ON public.card_prints (tcgplayer_id)
    WHERE tcgplayer_id IS NOT NULL;

COMMIT;
