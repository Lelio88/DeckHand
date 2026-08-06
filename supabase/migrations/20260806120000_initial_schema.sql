-- 001 — Schéma initial : catalogue de cartes, collections, corpus de decks.
--
-- Motivation des choix non évidents :
--   * `cards` est indexé sur l'`oracle_id` Scryfall et non sur l'identifiant d'impression :
--     le deckbuilding raisonne en cartes, pas en éditions. Les impressions vivent à part.
--   * Les légalités arrivent en JSON depuis Scryfall mais sont projetées en colonnes
--     générées : filtrer un format est l'opération la plus fréquente de l'application.
--   * `card_search_names` existe parce que la collection mélange français et anglais.
--     Une carte y a plusieurs entrées (nom oracle + noms imprimés localisés) pointant
--     toutes vers le même `oracle_id`.
--   * `deck_sources.attribution_text` porte l'obligation légale de crédit (TopDeck.gg).
--     L'attribution voyage avec la donnée pour que l'interface ne puisse pas l'oublier.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.cards (
    oracle_id      uuid PRIMARY KEY,
    name           text NOT NULL,
    mana_cost      text,
    cmc            numeric NOT NULL DEFAULT 0,
    type_line      text,
    oracle_text    text,
    color_identity text[] NOT NULL DEFAULT '{}',
    legalities     jsonb NOT NULL DEFAULT '{}'::jsonb,
    layout         text,
    updated_at     timestamptz NOT NULL DEFAULT NOW(),

    legal_pauper    boolean GENERATED ALWAYS AS ((legalities ->> 'pauper')    = 'legal') STORED,
    legal_modern    boolean GENERATED ALWAYS AS ((legalities ->> 'modern')    = 'legal') STORED,
    legal_commander boolean GENERATED ALWAYS AS ((legalities ->> 'commander') = 'legal') STORED
);

COMMENT ON TABLE  public.cards IS 'Cartes au sens oracle : une ligne par carte distincte, toutes éditions confondues.';
COMMENT ON COLUMN public.cards.name IS 'Nom oracle anglais. Fait foi partout — les decklists et les règles sont en anglais.';
COMMENT ON COLUMN public.cards.color_identity IS 'Identité couleur Scryfall. Contrainte de construction en Commander.';
COMMENT ON COLUMN public.cards.legal_pauper IS 'Projection de legalities->>pauper. Colonne générée : le filtrage par format est le chemin chaud.';

CREATE INDEX IF NOT EXISTS idx_cards_legal_pauper    ON public.cards (oracle_id) WHERE legal_pauper;
CREATE INDEX IF NOT EXISTS idx_cards_legal_modern    ON public.cards (oracle_id) WHERE legal_modern;
CREATE INDEX IF NOT EXISTS idx_cards_legal_commander ON public.cards (oracle_id) WHERE legal_commander;

CREATE TABLE IF NOT EXISTS public.card_prints (
    scryfall_id      uuid PRIMARY KEY,
    oracle_id        uuid NOT NULL REFERENCES public.cards(oracle_id) ON DELETE CASCADE,
    lang             text NOT NULL,
    printed_name     text,
    set_code         text NOT NULL,
    set_name         text,
    collector_number text,
    rarity           text,
    art_crop_url     text,
    price_eur        numeric,
    price_usd        numeric,
    released_at      date
);

COMMENT ON TABLE  public.card_prints IS 'Impressions : une ligne par (carte, édition, langue). Porte les prix et l''illustration.';
COMMENT ON COLUMN public.card_prints.printed_name IS 'Nom tel qu''imprimé sur la carte physique — en français pour les impressions FR.';
COMMENT ON COLUMN public.card_prints.art_crop_url IS 'Source du calcul d''empreinte perceptuelle. L''image n''est jamais stockée.';

CREATE INDEX IF NOT EXISTS idx_card_prints_oracle ON public.card_prints (oracle_id);
CREATE INDEX IF NOT EXISTS idx_card_prints_price  ON public.card_prints (oracle_id, price_eur) WHERE price_eur IS NOT NULL;

-- Prix de référence d'une carte : l'impression la moins chère.
-- La granularité de collection retenue ignore l'édition quand elle n'est pas détectée ;
-- valoriser au minimum est le choix honnête plutôt qu'une moyenne trompeuse.
CREATE OR REPLACE VIEW public.card_cheapest_price AS
SELECT oracle_id,
       MIN(price_eur) AS price_eur,
       MIN(price_usd) AS price_usd
FROM public.card_prints
GROUP BY oracle_id;

COMMENT ON VIEW public.card_cheapest_price IS 'Prix plancher par carte, base de la valorisation de collection et du coût de complétion.';

-- ---------------------------------------------------------------------------
-- Recherche multilingue
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.card_search_names (
    id         bigserial PRIMARY KEY,
    oracle_id  uuid NOT NULL REFERENCES public.cards(oracle_id) ON DELETE CASCADE,
    name       text NOT NULL,
    normalized text NOT NULL,
    lang       text NOT NULL,
    UNIQUE (oracle_id, normalized, lang)
);

COMMENT ON TABLE  public.card_search_names IS 'Index de saisie : plusieurs noms (oracle + localisés) pointent vers une même carte.';
COMMENT ON COLUMN public.card_search_names.normalized IS 'Minuscules, accents retirés. Permet de saisir "ile" pour trouver "Île".';

CREATE INDEX IF NOT EXISTS idx_card_search_trgm ON public.card_search_names USING gin (normalized gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- Collections
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.collections (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name       text NOT NULL DEFAULT 'Ma collection',
    created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.collection_items (
    id            bigserial PRIMARY KEY,
    collection_id uuid NOT NULL REFERENCES public.collections(id) ON DELETE CASCADE,
    oracle_id     uuid NOT NULL REFERENCES public.cards(oracle_id),
    print_id      uuid REFERENCES public.card_prints(scryfall_id),
    quantity      integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
    added_at      timestamptz NOT NULL DEFAULT NOW(),
    UNIQUE NULLS NOT DISTINCT (collection_id, oracle_id, print_id)
);

COMMENT ON COLUMN public.collection_items.print_id IS 'Édition possédée, NULL si indéterminée. La valorisation retombe alors sur le prix plancher.';

CREATE INDEX IF NOT EXISTS idx_collection_items_collection ON public.collection_items (collection_id);

ALTER TABLE public.collections      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collection_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY collections_owner ON public.collections
    FOR ALL USING (owner_id = auth.uid()) WITH CHECK (owner_id = auth.uid());

CREATE POLICY collection_items_owner ON public.collection_items
    FOR ALL USING (
        EXISTS (SELECT 1 FROM public.collections c
                WHERE c.id = collection_id AND c.owner_id = auth.uid())
    ) WITH CHECK (
        EXISTS (SELECT 1 FROM public.collections c
                WHERE c.id = collection_id AND c.owner_id = auth.uid())
    );

-- ---------------------------------------------------------------------------
-- Corpus de decks
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.deck_sources (
    id                   text PRIMARY KEY,
    display_name         text NOT NULL,
    url                  text NOT NULL,
    attribution_required boolean NOT NULL DEFAULT false,
    attribution_text     text
);

COMMENT ON COLUMN public.deck_sources.attribution_required IS 'TopDeck.gg impose un crédit visible. L''obligation est portée par la donnée, pas par l''interface.';

INSERT INTO public.deck_sources (id, display_name, url, attribution_required, attribution_text) VALUES
    ('topdeck',  'TopDeck.gg', 'https://topdeck.gg',  true,  'Données de tournoi fournies par TopDeck.gg'),
    ('edhtop16', 'EDHTop16',   'https://edhtop16.com', true, 'Données de Commander compétitif fournies par EDHTop16'),
    ('mtgjson',  'MTGJSON',    'https://mtgjson.com',  false, 'Decks préconstruits issus de MTGJSON (licence MIT)')
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.decks (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id           text NOT NULL REFERENCES public.deck_sources(id),
    external_id         text,
    name                text NOT NULL,
    format              text NOT NULL CHECK (format IN ('pauper', 'modern', 'commander')),
    tier                text NOT NULL CHECK (tier IN ('accessible', 'competitive')),
    commander_oracle_id uuid REFERENCES public.cards(oracle_id),
    source_url          text,
    recorded_at         timestamptz,
    UNIQUE (source_id, external_id)
);

COMMENT ON COLUMN public.decks.tier IS
    'accessible = précon ou deck budget, à portée d''une collection ordinaire. '
    'competitive = deck de tournoi, souvent hors de portée (le cEDH relevé dépasse 10 000 $). '
    'Distinction affichée à l''utilisateur : sans elle, la promesse "à quelques cartes près" devient mensongère.';

CREATE TABLE IF NOT EXISTS public.deck_cards (
    id        bigserial PRIMARY KEY,
    deck_id   uuid NOT NULL REFERENCES public.decks(id) ON DELETE CASCADE,
    oracle_id uuid NOT NULL REFERENCES public.cards(oracle_id),
    quantity  integer NOT NULL CHECK (quantity > 0),
    board     text NOT NULL DEFAULT 'main' CHECK (board IN ('main', 'side')),
    UNIQUE (deck_id, oracle_id, board)
);

CREATE INDEX IF NOT EXISTS idx_deck_cards_deck   ON public.deck_cards (deck_id);
CREATE INDEX IF NOT EXISTS idx_deck_cards_oracle ON public.deck_cards (oracle_id);

-- ---------------------------------------------------------------------------
-- Exposition via l'API de données
-- ---------------------------------------------------------------------------
-- Le projet Supabase est configuré SANS exposition automatique des nouvelles
-- tables et AVEC activation automatique de la RLS. Double conséquence : chaque
-- table doit recevoir explicitement ses privilèges *et* porter une policy,
-- sinon elle reste totalement inaccessible depuis l'API.
--
-- Le rôle `service_role` contourne la RLS : l'ingestion serveur n'est pas
-- concernée par ce qui suit.

-- Catalogue : lecture publique assumée. Ces données viennent de Scryfall et ne
-- contiennent rien de personnel.
GRANT SELECT ON public.cards, public.card_prints, public.card_search_names,
                public.deck_sources, public.decks, public.deck_cards,
                public.card_cheapest_price
    TO anon, authenticated;

ALTER TABLE public.cards             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.card_prints       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.card_search_names ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deck_sources      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.decks             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deck_cards        ENABLE ROW LEVEL SECURITY;

CREATE POLICY cards_public_read
    ON public.cards FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY card_prints_public_read
    ON public.card_prints FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY card_search_names_public_read
    ON public.card_search_names FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY deck_sources_public_read
    ON public.deck_sources FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY decks_public_read
    ON public.decks FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY deck_cards_public_read
    ON public.deck_cards FOR SELECT TO anon, authenticated USING (true);

-- Sans `security_invoker`, une vue s'exécute avec les droits de son
-- propriétaire et court-circuiterait donc la RLS des tables qu'elle lit.
ALTER VIEW public.card_cheapest_price SET (security_invoker = true);

-- Collections : accès complet pour un utilisateur authentifié, le périmètre
-- étant restreint à ses propres lignes par les policies définies plus haut.
GRANT SELECT, INSERT, UPDATE, DELETE
    ON public.collections, public.collection_items
    TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.collection_items_id_seq TO authenticated;

COMMIT;
