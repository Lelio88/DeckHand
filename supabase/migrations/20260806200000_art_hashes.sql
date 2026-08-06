-- 008 — Index d'empreintes d'illustrations.
--
-- Une empreinte perceptuelle de 64 bits par illustration, calculée côté serveur
-- à partir des images Scryfall. **Les images ne sont jamais stockées** : elles
-- sont téléchargées, hachées, puis jetées. L'index complet tient ainsi en
-- quelques centaines de kilo-octets là où les images pèseraient plusieurs
-- gigaoctets — c'est ce qui rend l'embarquement dans l'application possible.
--
-- `bigint` et non `numeric` : une empreinte est un motif de bits, pas une
-- quantité. Postgres n'ayant pas d'entier 64 bits non signé, les valeurs au-delà
-- de 2^63 sont repliées en négatif ; la conversion est réversible et gérée par
-- `app/vision/dhash.py`.
--
-- L'empreinte porte sur l'illustration seule, jamais sur la carte entière : une
-- carte française et sa version anglaise partagent la même illustration mais pas
-- le même cadre de texte. Hacher l'art rend la langue transparente.

BEGIN;

CREATE TABLE IF NOT EXISTS public.art_hashes (
    scryfall_id uuid PRIMARY KEY REFERENCES public.card_prints(scryfall_id) ON DELETE CASCADE,
    oracle_id   uuid NOT NULL REFERENCES public.cards(oracle_id) ON DELETE CASCADE,
    dhash       bigint NOT NULL,
    computed_at timestamptz NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.art_hashes IS
    'Empreintes perceptuelles des illustrations, servies à l''application pour la '
    'reconnaissance embarquée. Les images elles-mêmes ne sont jamais conservées.';
COMMENT ON COLUMN public.art_hashes.dhash IS
    'Difference hash 64 bits, replié en bigint signé. Voir app/vision/dhash.py.';

CREATE INDEX IF NOT EXISTS idx_art_hashes_oracle ON public.art_hashes (oracle_id);
CREATE INDEX IF NOT EXISTS idx_art_hashes_value  ON public.art_hashes (dhash);

-- Lecture publique : l'index est destiné à être téléchargé par l'application,
-- et ne contient aucune donnée personnelle.
GRANT SELECT ON public.art_hashes TO anon, authenticated;
ALTER TABLE public.art_hashes ENABLE ROW LEVEL SECURITY;
CREATE POLICY art_hashes_public_read
    ON public.art_hashes FOR SELECT TO anon, authenticated USING (true);

COMMIT;
