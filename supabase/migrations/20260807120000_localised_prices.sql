-- 017 — Un prix pour les impressions localisées.
--
-- Scryfall ne cote presque jamais les impressions françaises : le marché de
-- référence est anglophone. Une carte possédée en français s'affichait donc sans
-- prix, et comptait pour zéro dans la valorisation — alors que la même carte, à
-- la même édition et au même numéro de collection, est cotée en anglais.
--
-- Le repli est légitime : c'est le même objet, sortie de la même boîte, seule la
-- langue du texte diffère. Les écarts de cote entre langues existent mais
-- restent marginaux comparés à l'erreur commise en comptant zéro.
--
-- Le repli est **strictement borné** à la même carte, la même extension et le
-- même numéro de collection. Sans le numéro, une réimpression bon marché
-- viendrait coter une version rare de la même extension.
--
-- Les deux fonctions changent de corps mais pas de signature ; `CREATE OR
-- REPLACE` suffit donc ici, sans risque de surcharge PostgREST.

BEGIN;

-- ---------------------------------------------------------------------------
-- Prix effectif d'une impression : le sien, ou celui de son équivalent anglais
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.card_print_price AS
SELECT p.scryfall_id,
       p.oracle_id,
       COALESCE(p.price_eur, twin.price_eur) AS price_eur,
       -- Vrai quand la cote vient de l'équivalent dans une autre langue :
       -- l'interface peut ainsi nuancer plutôt que d'affirmer.
       (p.price_eur IS NULL AND twin.price_eur IS NOT NULL) AS price_is_borrowed
FROM public.card_prints p
LEFT JOIN LATERAL (
    SELECT o.price_eur
    FROM public.card_prints o
    WHERE o.oracle_id = p.oracle_id
      AND o.set_code = p.set_code
      AND o.collector_number IS NOT DISTINCT FROM p.collector_number
      AND o.price_eur IS NOT NULL
    ORDER BY (o.lang = 'en') DESC, o.price_eur
    LIMIT 1
) twin ON true;

COMMENT ON VIEW public.card_print_price IS
    'Prix d''une impression, complété par celui de son équivalent dans une autre '
    'langue quand Scryfall ne cote pas la version localisée (cas courant du français).';

GRANT SELECT ON public.card_print_price TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Le sélecteur d'éditions affiche un prix pour chaque ligne
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.card_printings(
    p_oracle_id uuid,
    p_query     text    DEFAULT NULL,
    p_limit     integer DEFAULT 60
)
RETURNS TABLE (
    print_id         uuid,
    set_code         text,
    set_name         text,
    collector_number text,
    rarity           text,
    lang             text,
    printed_name     text,
    price_eur        numeric,
    released_at      date,
    owned            integer,
    art_crop_url     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH needle AS (
        SELECT lower(trim(COALESCE(p_query, ''))) AS n
    ),
    mine AS (
        SELECT i.print_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid() AND i.print_id IS NOT NULL
        GROUP BY i.print_id
    )
    SELECT p.scryfall_id,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.rarity,
           p.lang,
           p.printed_name,
           pp.price_eur,
           p.released_at,
           COALESCE(m.owned, 0),
           p.art_crop_url
    FROM public.card_prints p
    JOIN public.card_print_price pp ON pp.scryfall_id = p.scryfall_id
    LEFT JOIN mine m ON m.print_id = p.scryfall_id
    WHERE p.oracle_id = p_oracle_id
      AND ((SELECT n FROM needle) = ''
           OR lower(COALESCE(p.set_name, '')) LIKE '%' || (SELECT n FROM needle) || '%'
           OR lower(p.set_code) LIKE (SELECT n FROM needle) || '%')
    ORDER BY COALESCE(m.owned, 0) DESC,
             p.released_at DESC NULLS LAST,
             p.set_code,
             p.collector_number
    LIMIT GREATEST(1, LEAST(p_limit, 200));
$$;

-- ---------------------------------------------------------------------------
-- La collection valorise aussi les impressions localisées
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.my_collection_summary()
RETURNS TABLE (
    total_cards        integer,
    distinct_cards     integer,
    total_value_eur    numeric,
    unspecified_prints integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH mine AS (
        SELECT i.oracle_id,
               i.print_id,
               SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id
    )
    SELECT COALESCE(SUM(m.quantity), 0)::integer,
           COUNT(DISTINCT m.oracle_id)::integer,
           COALESCE(SUM(m.quantity * COALESCE(pp.price_eur, cheap.price_eur, 0)), 0),
           COALESCE(SUM(m.quantity) FILTER (WHERE m.print_id IS NULL), 0)::integer
    FROM mine m
    LEFT JOIN public.card_print_price pp ON pp.scryfall_id = m.print_id
    LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id;
$$;

-- ---------------------------------------------------------------------------
-- La page de collection affiche le prix effectif
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.my_collection(
    p_query  text    DEFAULT NULL,
    p_sort   text    DEFAULT 'name',
    p_limit  integer DEFAULT 50,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    oracle_id        uuid,
    print_id         uuid,
    name             text,
    printed_name     text,
    type_line        text,
    set_code         text,
    set_name         text,
    collector_number text,
    quantity         integer,
    unit_price_eur   numeric,
    line_price_eur   numeric,
    legal_pauper     boolean,
    legal_modern     boolean,
    legal_commander  boolean,
    added_at         timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH needle AS (
        SELECT public.normalize_card_name(COALESCE(p_query, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id,
               i.print_id,
               SUM(i.quantity)::integer AS quantity,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id
    ),
    priced AS (
        SELECT m.*,
               -- Édition précisée : son prix effectif fait foi, emprunté à son
               -- équivalent anglais si la version localisée n'est pas cotée.
               -- Sinon, le moins cher connu — l'exemplaire n'étant pas
               -- identifié, mieux vaut sous-estimer.
               COALESCE(pp.price_eur, cheap.price_eur) AS unit_price,
               pr.set_code,
               pr.set_name,
               pr.collector_number,
               COALESCE(pr.printed_name, fr.name) AS shown_name
        FROM mine m
        LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
        LEFT JOIN public.card_print_price pp ON pp.scryfall_id = m.print_id
        LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id
        LEFT JOIN LATERAL (
            SELECT s.name
            FROM public.card_search_names s
            WHERE s.oracle_id = m.oracle_id AND s.lang = 'fr'
            LIMIT 1
        ) fr ON true
    )
    SELECT p.oracle_id,
           p.print_id,
           c.name,
           p.shown_name,
           c.type_line,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.quantity,
           p.unit_price,
           p.unit_price * p.quantity,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           p.added_at
    FROM priced p
    JOIN public.cards c ON c.oracle_id = p.oracle_id
    WHERE (SELECT n FROM needle) = ''
       OR EXISTS (
            SELECT 1 FROM public.card_search_names s
            WHERE s.oracle_id = p.oracle_id
              AND s.normalized LIKE '%' || (SELECT n FROM needle) || '%'
       )
    ORDER BY
        CASE WHEN p_sort = 'price'    THEN p.unit_price * p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' THEN p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   THEN p.added_at END DESC NULLS LAST,
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMIT;
