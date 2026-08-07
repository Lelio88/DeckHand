-- 021 — L'identifiant d'illustration, clé d'un index complet.
--
-- L'index d'empreintes ne porte qu'une image par carte, si bien qu'une réédition
-- à l'illustration changée est invisible au scan — un quart des cas mesurés.
-- Le corriger suppose de hacher chaque illustration distincte.
--
-- Hacher les 162 000 impressions serait absurde : la plupart partagent leur art.
-- Scryfall publie `illustration_id`, commun à toutes les impressions d'une même
-- œuvre. Une empreinte par identifiant suffit donc, et l'index reste borné au
-- nombre d'illustrations réelles plutôt qu'au nombre d'impressions.

BEGIN;

ALTER TABLE public.card_prints
    ADD COLUMN IF NOT EXISTS illustration_id uuid;

COMMENT ON COLUMN public.card_prints.illustration_id IS
    'Identifiant Scryfall de l''œuvre. Partagé par toutes les impressions qui '
    'réutilisent la même illustration — évite de hacher deux fois la même image.';

CREATE INDEX IF NOT EXISTS idx_card_prints_illustration
    ON public.card_prints (illustration_id)
    WHERE illustration_id IS NOT NULL;

COMMIT;
