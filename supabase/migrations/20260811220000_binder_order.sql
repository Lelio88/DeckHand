-- 037 — Ranger la collection comme un classeur : l'extension, puis le numéro.
--
-- **Le numéro seul ne range pas une boîte.** Le tri `number` existant met
-- `MAR #43` juste avant `MSH #43`, alors que ces deux cartes sont dans deux
-- classeurs différents. Le numéro n'a de sens qu'à l'intérieur d'une extension —
-- c'est elle qui désigne le classeur, lui qui désigne la case.
--
-- **L'ordre des extensions est alphabétique par code** (`mar`, `msc`, `msh`).
-- Par date de sortie serait plus proche d'une étagère réelle, mais deux
-- extensions parues le même jour deviendraient arbitraires, et l'ordre changerait
-- sous les yeux de l'utilisateur au gré des rééditions. L'alphabétique est
-- prévisible : on sait d'avance où chercher.
--
-- **Inverser le classeur l'inverse en entier** — dernière extension, dernier
-- numéro. Le critère étant le couple, n'en renverser qu'une moitié donnerait des
-- extensions à l'envers contenant des pages à l'endroit, ce que personne ne
-- demande. C'est aussi la convention des autres tris : re-choisir un critère
-- renverse ce critère, pas une partie de lui.
--
-- **Les cartes sans édition ferment la marche dans les deux sens.** Elles n'ont
-- ni extension ni numéro : elles ne sont rangeables nulle part, et le `NULLS
-- LAST` explicite les désigne du même geste comme celles qui restent à préciser.
-- Sans lui, l'ordre descendant les remonterait en tête (défaut PostgreSQL).
--
-- Seul le `ORDER BY` change ; la signature et le corps de la requête sont ceux
-- de la migration 034.

BEGIN;

CREATE OR REPLACE FUNCTION public.my_collection(
    p_query            text    DEFAULT NULL,
    p_sort             text    DEFAULT 'name',
    p_limit            integer DEFAULT 50,
    p_offset           integer DEFAULT 0,
    p_game             text    DEFAULT 'magic',
    p_unspecified_only boolean DEFAULT false,
    p_descending       boolean DEFAULT false,
    p_finish           text    DEFAULT NULL,
    p_full_art         boolean DEFAULT NULL
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
    rarity           text,
    full_art         boolean,
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
          AND (p_finish IS NULL
               OR (p_finish = 'foil' AND i.is_foil)
               OR (p_finish = 'nonfoil' AND NOT i.is_foil))
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    priced AS (
        SELECT m.*,
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur
               ) AS unit_price,
               pr.set_code,
               pr.set_name,
               pr.collector_number,
               pr.rarity,
               pr.full_art,
               public.rarity_rank(pr.rarity) AS rarity_rank,
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
        WHERE p_full_art IS NULL
           OR COALESCE(pr.full_art, false) = p_full_art
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
           p.rarity,
           p.full_art,
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
        CASE WHEN p_sort = 'price'    AND     p_descending THEN COALESCE(p.unit_price * p.quantity, 0) END DESC,
        CASE WHEN p_sort = 'price'    AND NOT p_descending THEN COALESCE(p.unit_price * p.quantity, 0) END ASC,
        CASE WHEN p_sort = 'quantity' AND     p_descending THEN p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' AND NOT p_descending THEN p.quantity END ASC  NULLS LAST,
        CASE WHEN p_sort = 'recent'   AND     p_descending THEN p.added_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   AND NOT p_descending THEN p.added_at END ASC  NULLS LAST,
        CASE WHEN p_sort = 'rarity'   AND     p_descending THEN p.rarity_rank END DESC NULLS LAST,
        CASE WHEN p_sort = 'rarity'   AND NOT p_descending THEN p.rarity_rank END ASC  NULLS LAST,
        CASE WHEN p_sort = 'name'     AND     p_descending THEN COALESCE(p.shown_name, c.name) END DESC,
        CASE WHEN p_sort = 'name'     AND NOT p_descending THEN COALESCE(p.shown_name, c.name) END ASC,
        -- **Le classeur : l'extension d'abord.** Elle désigne le volume ; le
        -- numéro, plus bas, désigne la case à l'intérieur. C'est la seule clé
        -- propre à ce tri — tout le reste lui est déjà commun.
        CASE WHEN p_sort = 'binder'   AND     p_descending THEN p.set_code END DESC NULLS LAST,
        CASE WHEN p_sort = 'binder'   AND NOT p_descending THEN p.set_code END ASC  NULLS LAST,
        -- **Le numéro départage tout le reste.** À rareté égale, à prix égal,
        -- l'ordre paraissait aléatoire à qui range une boîte, où les numéros se
        -- suivent. Il porte aussi les tris « numéro » et « classeur », dont il
        -- est la clé de rangement — d'où sa présence ici plutôt qu'au-dessus.
        CASE WHEN p_sort IN ('number', 'binder') AND p_descending THEN p.number_rank END DESC NULLS LAST,
        p.number_rank ASC NULLS LAST,
        p.collector_number ASC NULLS LAST,
        -- Dernier recours : sans lui, deux cartes du même numéro dans deux
        -- extensions pourraient changer de place d'une page à l'autre.
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST,
        p.is_foil
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection(text, text, integer, integer, text, boolean, boolean, text, boolean) IS
    'Page de collection. Le tri « classeur » range par extension puis par '
    'numéro, comme une boîte ; le numéro seul départage tous les autres tris.';

COMMIT;
