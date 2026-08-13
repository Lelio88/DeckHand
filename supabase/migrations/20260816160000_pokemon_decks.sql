-- Les formats de deck Pokémon, et la source qui les fournit.
--
-- Motivation : les quatre formats retenus le sont **par volume mesuré** sur
-- 6 000 tournois et 321 992 participations relevés sur dix-neuf mois, non par
-- notoriété. La distribution est l'exacte inverse de celle de Yu-Gi-Oh, où les
-- formats rétro portaient 97 % du corpus :
--
--     STANDARD   307 090 participations   (95,4 %)
--     GLC          3 948
--     EX           1 720
--     EXPANDED       362
--
-- `CUSTOM` arrive deuxième en volume (4 650) et n'est pourtant pas importé :
-- c'est un fourre-tout de règles maison, sans légalité reproductible. Un deck
-- ainsi étiqueté ne dit pas avec quelles cartes il peut être rejoué, ce qui est
-- précisément ce que le calcul de complétion doit savoir. Les trente-huit autres
-- libellés relevés pèsent moins de sept cents participations chacun.
--
-- Refs: #22

BEGIN;

ALTER TABLE public.decks DROP CONSTRAINT IF EXISTS decks_format_check;

ALTER TABLE public.decks ADD CONSTRAINT decks_format_check CHECK (
    format = ANY (ARRAY[
        'pauper', 'modern', 'commander',   -- Magic
        'constructed',                     -- Riftbound
        'edison', 'goat', 'redu', 'hat',   -- Yu-Gi-Oh
        'standard', 'glc', 'expanded', 'ex' -- Pokémon
    ])
);

-- Limitless ne publie aucune condition d'utilisation (404 sur `/terms`) : le
-- garde-fou §IV.9 lui applique donc celles de Scryfall, dont l'attribution
-- visible.
INSERT INTO public.deck_sources (id, display_name, url, attribution_required,
                                 attribution_text)
VALUES ('limitless', 'Limitless TCG', 'https://play.limitlesstcg.com', true,
        'Données de tournoi fournies par Limitless TCG')
ON CONFLICT (id) DO UPDATE SET
    display_name         = EXCLUDED.display_name,
    url                  = EXCLUDED.url,
    attribution_required = EXCLUDED.attribution_required,
    attribution_text     = EXCLUDED.attribution_text;

COMMIT;
