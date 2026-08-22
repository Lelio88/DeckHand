-- L'illustration reconnue remonte jusqu'à l'écran.
--
-- Motivation : la reconnaissance identifie une *illustration* — c'est sur elle
-- que l'empreinte est calculée — mais seule l'identité de la carte remontait.
-- L'écran affichait donc l'illustration de la plus ancienne impression
-- anglaise, quelle que soit celle qu'on venait de scanner.
--
-- Ce n'est pas un cas marginal : **23,9 % des cartes Magic ont plusieurs
-- illustrations** (7 853 sur 32 808), et le premier essai sur l'appareil est
-- tombé dessus — « Levée de bouclier » en a deux, la version Marvel scannée et
-- celle d'origine affichée.
--
-- Ce que cela coûtait : le §IV.8 exige une confirmation de l'utilisateur avant
-- toute écriture en collection. Lui montrer une autre illustration que celle
-- qu'il tient rend cette confirmation impossible à donner en conscience.
--
-- `art_hashes` porte déjà `scryfall_id`, l'impression précise : l'information
-- existait, elle était perdue en route.
--
-- Refs: #8

BEGIN;

-- Le nombre de colonnes rendues change : il faut déposer avant de recréer.
DROP FUNCTION IF EXISTS public.art_hash_page(integer, integer, text);

CREATE FUNCTION public.art_hash_page(
    p_offset integer DEFAULT 0,
    p_limit integer DEFAULT 2000,
    p_game text DEFAULT 'magic'
)
RETURNS TABLE(oracle_id uuid, print_id uuid, hash_hex text)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
    SELECT h.oracle_id,
           h.scryfall_id,
           lpad(to_hex(h.dhash), 16, '0')
    FROM public.art_hashes h
    JOIN public.cards c ON c.oracle_id = h.oracle_id
    WHERE c.game = p_game
    ORDER BY h.scryfall_id
    OFFSET GREATEST(p_offset, 0)
    LIMIT GREATEST(1, LEAST(p_limit, 5000));
$$;

COMMENT ON FUNCTION public.art_hash_page(integer, integer, text) IS
    'Page de l''index d''empreintes. Rend l''impression (scryfall_id) et non '
    'seulement la carte : une carte sur quatre porte plusieurs illustrations, '
    'et c''est celle qui a été reconnue qu''il faut montrer.';

DROP FUNCTION IF EXISTS public.cards_by_oracle_ids(uuid[]);

CREATE FUNCTION public.cards_by_oracle_ids(
    p_ids uuid[],
    p_prints uuid[] DEFAULT NULL
)
RETURNS TABLE(
    oracle_id uuid,
    name text,
    printed_name text,
    type_line text,
    price_eur numeric,
    legal_pauper boolean,
    legal_modern boolean,
    legal_commander boolean,
    art_url text
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
    SELECT c.oracle_id,
           c.name,
           fr.name,
           c.type_line,
           p.price_eur,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           -- L'illustration reconnue d'abord ; à défaut, celle d'origine.
           -- Le repli compte : `p_prints` est absent des appels qui ne viennent
           -- pas d'un scan (une liste de decks, un classeur), et une impression
           -- peut n'avoir aucune illustration servie.
           COALESCE(
               (SELECT pr.art_crop_url
                FROM public.card_prints pr
                WHERE pr.scryfall_id = requested.print_id
                  AND pr.art_crop_url IS NOT NULL),
               (SELECT pr.art_crop_url
                FROM public.card_prints pr
                WHERE pr.oracle_id = c.oracle_id AND pr.art_crop_url IS NOT NULL
                ORDER BY (pr.lang = 'en') DESC, pr.released_at NULLS LAST,
                         pr.scryfall_id
                LIMIT 1)
           )
    FROM unnest(
             p_ids,
             COALESCE(
                 p_prints,
                 array_fill(NULL::uuid, ARRAY[coalesce(cardinality(p_ids), 0)])
             )
         ) WITH ORDINALITY AS requested(id, print_id, position)
    JOIN public.cards c ON c.oracle_id = requested.id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = c.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    ORDER BY requested.position;
$$;

COMMENT ON FUNCTION public.cards_by_oracle_ids(uuid[], uuid[]) IS
    'Cartes dans l''ordre demandé. `p_prints` désigne, position par position, '
    'l''impression reconnue : son illustration est alors celle rendue, faute de '
    'quoi l''écran montrerait une autre version de la même carte.';

GRANT EXECUTE ON FUNCTION public.art_hash_page(integer, integer, text)
    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cards_by_oracle_ids(uuid[], uuid[])
    TO anon, authenticated;

COMMIT;
