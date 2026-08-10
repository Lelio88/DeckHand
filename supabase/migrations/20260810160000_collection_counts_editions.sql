-- 027 — La collection compte des éditions, pas des cartes.
--
-- Le bandeau annonçait « 180 cartes dont 179 références distinctes » à un
-- propriétaire de deux Plaines portant les numéros 277 et 278. Le compte était
-- exact au sens où il était calculé — `COUNT(DISTINCT oracle_id)` — mais pas au
-- sens où il était lu : Scryfall donne un identifiant oracle unique à tous les
-- terrains de base d'un même type, si bien que 871 éditions de Plaine ne
-- comptent que pour une carte.
--
-- **Les deux lectures sont légitimes, mais pas au même endroit.** Le
-- deckbuilding raisonne en cartes : posséder deux Plaines, c'est pouvoir en
-- jouer deux exemplaires de la même. Une collection raisonne en objets : deux
-- illustrations différentes occupent deux cases d'un classeur. `deck_suggestions`
-- garde donc sa lecture, ce compteur change la sienne.
--
-- **L'unité retenue est le couple (extension, numéro).** C'est déjà la
-- définition d'une édition adoptée par `card_editions` (migration 025), et c'est
-- ce que porte le bas d'une carte. Conséquence assumée : la même édition en
-- français et en anglais compte pour une, comme partout ailleurs dans
-- l'application ; le brillant aussi, la finition n'étant pas un numéro.
--
-- **Une carte sans édition précisée compte pour une référence.** C'est le mieux
-- qu'on puisse affirmer sans inventer, et le bandeau dit par ailleurs combien
-- d'exemplaires restent à préciser. L'`oracle_id` entre dans la clé des deux
-- cas, ce qui rend impossible de fondre deux cartes distinctes.
--
-- Ajoute par ailleurs à `my_collection` un filtre sur ces mêmes cartes sans
-- édition : les compter sans donner le moyen de les atteindre laissait un
-- chantier visible et inaccessible. Ce paramètre change la signature — la
-- fonction est donc supprimée avant d'être recréée, sous peine de surcharge
-- PostgREST (migration 012).

BEGIN;

-- ---------------------------------------------------------------------------
-- Le compte des références
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.my_collection_summary(
    p_game text DEFAULT 'magic'
)
RETURNS TABLE (
    total_cards        integer,
    distinct_cards     integer,
    total_value_eur    numeric,
    unspecified_prints integer
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
    WITH mine AS (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    )
    SELECT COALESCE(SUM(m.quantity), 0)::integer,
           -- Clé d'une référence : la carte, puis son édition quand elle est
           -- connue. Une carte non précisée s'arrête donc à son oracle, et une
           -- carte possédée à la fois non précisée et en MH2 compte pour deux.
           COUNT(DISTINCT
               m.oracle_id::text || ':' ||
               COALESCE(pr.set_code || '#' || COALESCE(pr.collector_number, ''), '')
           )::integer,
           COALESCE(SUM(m.quantity * COALESCE(
               public.print_price(m.print_id, m.is_foil),
               cheap.price_eur,
               0
           )), 0),
           COALESCE(SUM(m.quantity) FILTER (WHERE m.print_id IS NULL), 0)::integer
    FROM mine m
    LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
    LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id;
$$;

COMMENT ON FUNCTION public.my_collection_summary(text) IS
    'Totaux de la collection entière. Une référence est un couple (extension, '
    'numéro) — une carte sans édition précisée en vaut une.';

-- ---------------------------------------------------------------------------
-- Atteindre les cartes qui restent à préciser
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.my_collection(text, text, integer, integer, text);

CREATE FUNCTION public.my_collection(
    p_query            text    DEFAULT NULL,
    p_sort             text    DEFAULT 'name',
    p_limit            integer DEFAULT 50,
    p_offset           integer DEFAULT 0,
    p_game             text    DEFAULT 'magic',
    p_unspecified_only boolean DEFAULT false
)
RETURNS TABLE (
    oracle_id        uuid,
    print_id         uuid,
    is_foil          boolean,
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
SET search_path TO 'public'
AS $$
    WITH needle AS (
        SELECT public.normalize_card_name(COALESCE(p_query, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
          AND (NOT p_unspecified_only OR i.print_id IS NULL)
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    priced AS (
        SELECT m.*,
               -- Édition précisée : son prix dans la finition possédée. Sinon le
               -- moins cher connu — l'exemplaire n'étant pas identifié, mieux
               -- vaut sous-estimer que d'inventer.
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur
               ) AS unit_price,
               pr.set_code,
               pr.set_name,
               pr.collector_number,
               -- Partie chiffrée du numéro, seule comparable d'une carte à
               -- l'autre. Vide (`★`, `T`) ou absente : la ligne passe en fin de
               -- liste plutôt qu'en tête, où un zéro implicite l'aurait mise.
               NULLIF(regexp_replace(COALESCE(pr.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank,
               COALESCE(pr.printed_name, fr.name) AS shown_name
        FROM mine m
        LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
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
           p.is_foil,
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
    JOIN public.cards c ON c.oracle_id = p.oracle_id AND c.game = p_game
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
        CASE WHEN p_sort = 'number'   THEN p.number_rank END ASC NULLS LAST,
        -- Le texte entier départage deux mêmes chiffres : 43a avant 43b.
        CASE WHEN p_sort = 'number'   THEN p.collector_number END ASC NULLS LAST,
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST,
        p.is_foil
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection(text, text, integer, integer, text, boolean) IS
    'Page de collection, cherchable, triable, et restreignable aux exemplaires '
    'dont l''édition reste à préciser.';

GRANT EXECUTE ON FUNCTION public.my_collection(text, text, integer, integer, text, boolean)
    TO authenticated;

COMMIT;
