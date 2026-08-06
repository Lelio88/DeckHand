-- 011 — Mémoire des ingestions.
--
-- Sans elle, un rafraîchissement quotidien retélécharge 390 Mo d'exports
-- Scryfall même quand rien n'a bougé. Cette table retient ce qui a été ingéré et
-- à partir de quelle version de la source, ce qui permet de sauter le travail
-- inutile — et de rendre visible la dernière fois qu'une donnée a été rafraîchie.
--
-- `source_version` est volontairement du texte : chaque source exprime sa
-- fraîcheur à sa façon. Scryfall date ses exports, MTGJSON les versionne,
-- TopDeck.gg n'a rien d'équivalent et se contente d'une fenêtre glissante.

BEGIN;

CREATE TABLE IF NOT EXISTS public.ingestion_state (
    source          text PRIMARY KEY,
    source_version  text,
    last_run_at     timestamptz NOT NULL DEFAULT NOW(),
    items_processed integer NOT NULL DEFAULT 0,
    last_error      text
);

COMMENT ON TABLE public.ingestion_state IS
    'Dernière ingestion réussie par source. Permet de sauter un rafraîchissement '
    'lorsque la source n''a pas changé.';
COMMENT ON COLUMN public.ingestion_state.source_version IS
    'Marqueur de fraîcheur propre à la source : date d''export Scryfall, version '
    'MTGJSON, fenêtre glissante pour TopDeck.gg.';

-- Lecture publique : savoir quand les prix ont été rafraîchis intéresse
-- l'utilisateur, et rien ici n'est personnel.
GRANT SELECT ON public.ingestion_state TO anon, authenticated;
ALTER TABLE public.ingestion_state ENABLE ROW LEVEL SECURITY;
CREATE POLICY ingestion_state_public_read
    ON public.ingestion_state FOR SELECT TO anon, authenticated USING (true);

COMMIT;
