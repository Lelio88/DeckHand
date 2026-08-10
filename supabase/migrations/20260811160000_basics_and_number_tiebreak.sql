-- 034 — Les terrains de base hors du compte, et le numéro comme départage.
--
-- **Un terrain de base ne se possède pas, il se prend.** Un deck Commander en
-- contient une trentaine, et personne n'achète des Plaines : on les prend dans
-- la boîte, en quantité illimitée. Les compter comme des cartes à acquérir
-- donnait 30 % de complétion à toute une collection qui ne partage avec ces
-- decks que ses terrains — même chiffre pour un deck dont on a le thème et un
-- deck dont on n'a rien, ce qui rendait le classement muet.
--
-- **Les terrains spéciaux restent comptés**, et c'est la distinction qui
-- compte : une fetchland vaut vingt euros et se cherche vraiment. Le critère est
-- `type_line LIKE 'Basic Land%'`, qui couvre aussi les versions enneigées
-- (« Basic Snow Land ») sans attraper les terrains légendaires ni les bicolores.
--
-- Les terrains de base sortent de **tout** le calcul — cartes attendues,
-- possédées, manquantes, coût — et non du seul pourcentage : deux nombres qui
-- ne compteraient pas la même chose se contrediraient sur la même ligne.
--
-- **Le numéro de collection départage tous les tris.** Trier par rareté rangeait
-- ensuite par nom : à l'intérieur des communes, l'ordre paraissait aléatoire à
-- qui range une boîte, puisque les numéros s'y succèdent. Le numéro devient donc
-- le second critère de tous les tris — y compris par valeur, où deux cartes au
-- même prix se suivent désormais dans l'ordre du classeur.
--
-- Les deux fonctions changent de corps ; `deck_suggestions` change aussi de
-- signature et doit être supprimée avant d'être recréée (migration 012).

BEGIN;

-- ---------------------------------------------------------------------------
-- Collection : le numéro départage
-- ---------------------------------------------------------------------------

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
        -- **Le numéro départage tout le reste.** À rareté égale, à prix égal,
        -- l'ordre paraissait aléatoire à qui range une boîte, où les numéros se
        -- suivent. Il porte aussi le tri « numéro », dont il est alors la seule
        -- clé active — d'où sa présence ici plutôt qu'au-dessus.
        CASE WHEN p_sort = 'number' AND p_descending THEN p.number_rank END DESC NULLS LAST,
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
    'Page de collection. Le numéro de collection départage tous les tris : à '
    'rareté ou à prix égal, les cartes se suivent comme dans un classeur.';

-- ---------------------------------------------------------------------------
-- Suggestions : les terrains de base hors du compte
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.deck_suggestions(
    text, integer, integer, numeric, text, text, text[], text, boolean);

CREATE FUNCTION public.deck_suggestions(
    p_format           text,
    p_max_missing      integer DEFAULT 100,
    p_max_results      integer DEFAULT 30,
    p_max_cost         numeric DEFAULT NULL,
    p_tier             text    DEFAULT NULL,
    p_game             text    DEFAULT 'magic',
    p_colors           text[]  DEFAULT NULL,
    p_commander        text    DEFAULT NULL,
    p_owned_commander  boolean DEFAULT false
)
RETURNS TABLE (
    deck_id             uuid,
    deck_name           text,
    tier                text,
    source_id           text,
    source_name         text,
    attribution         text,
    total_cards         integer,
    owned_cards         integer,
    missing_cards       integer,
    completion          real,
    missing_cost_eur    numeric,
    colors              text[],
    commander_oracle_id uuid,
    commander_name      text,
    commander_owned     boolean,
    basic_lands         integer
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
    WITH wanted AS (
        SELECT public.normalize_card_name(COALESCE(p_commander, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    ),
    chosen AS (
        SELECT d.id
        FROM public.decks d
        WHERE d.format = p_format
          AND d.game = p_game
          AND (p_tier IS NULL OR d.tier = p_tier)
          AND ((SELECT n FROM wanted) = ''
               OR EXISTS (
                    SELECT 1 FROM public.card_search_names s
                    WHERE s.oracle_id = d.commander_oracle_id
                      AND s.normalized LIKE '%' || (SELECT n FROM wanted) || '%'
               ))
          AND (NOT p_owned_commander
               OR EXISTS (
                    SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id
               ))
    ),
    entries AS (
        SELECT dc.deck_id,
               dc.oracle_id,
               SUM(dc.quantity)::integer AS needed,
               -- « Basic Land — Plains », « Basic Snow Land — Island ». Ni les
               -- terrains légendaires, ni les bicolores, qui eux s'achètent.
               bool_or(c.type_line LIKE 'Basic Land%') AS is_basic
        FROM public.deck_cards dc
        JOIN chosen ON chosen.id = dc.deck_id
        JOIN public.cards c ON c.oracle_id = dc.oracle_id
        WHERE dc.board = 'main'
        GROUP BY dc.deck_id, dc.oracle_id
    ),
    basics AS (
        SELECT e.deck_id, COALESCE(SUM(e.needed) FILTER (WHERE e.is_basic), 0)::integer AS basic_lands
        FROM entries e
        GROUP BY e.deck_id
    ),
    -- L'identité couleur se lit sur le deck entier, terrains compris : un deck
    -- qui ne contient de rouge que dans ses Montagnes reste un deck rouge.
    deck_colors AS (
        SELECT e.deck_id,
               COALESCE(
                   array_agg(DISTINCT ci ORDER BY ci) FILTER (WHERE ci IS NOT NULL),
                   ARRAY[]::text[]
               ) AS colors
        FROM entries e
        JOIN public.cards c ON c.oracle_id = e.oracle_id
        LEFT JOIN LATERAL unnest(c.color_identity) AS ci ON true
        GROUP BY e.deck_id
    ),
    gaps AS (
        SELECT e.deck_id,
               e.oracle_id,
               e.needed,
               GREATEST(e.needed - COALESCE(m.owned, 0), 0) AS missing
        FROM entries e
        LEFT JOIN mine m ON m.oracle_id = e.oracle_id
        WHERE NOT e.is_basic
    ),
    totals AS (
        SELECT g.deck_id,
               SUM(g.needed)::integer                      AS total_cards,
               SUM(g.needed - g.missing)::integer          AS owned_cards,
               SUM(g.missing)::integer                     AS missing_cards,
               SUM(g.missing * COALESCE(p.price_eur, 0))   AS missing_cost_eur
        FROM gaps g
        LEFT JOIN public.card_cheapest_price p ON p.oracle_id = g.oracle_id
        GROUP BY g.deck_id
    )
    SELECT d.id,
           d.name,
           d.tier,
           d.source_id,
           s.display_name,
           s.attribution_text,
           t.total_cards,
           t.owned_cards,
           t.missing_cards,
           (t.owned_cards::real / NULLIF(t.total_cards, 0))::real,
           t.missing_cost_eur,
           dc.colors,
           d.commander_oracle_id,
           COALESCE(fr.name, cmd.name),
           d.commander_oracle_id IS NOT NULL
               AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id),
           b.basic_lands
    FROM totals t
    JOIN public.decks d ON d.id = t.deck_id
    JOIN public.deck_sources s ON s.id = d.source_id
    JOIN deck_colors dc ON dc.deck_id = t.deck_id
    JOIN basics b ON b.deck_id = t.deck_id
    LEFT JOIN public.cards cmd ON cmd.oracle_id = d.commander_oracle_id
    LEFT JOIN LATERAL (
        SELECT sn.name
        FROM public.card_search_names sn
        WHERE sn.oracle_id = d.commander_oracle_id AND sn.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE t.missing_cards <= p_max_missing
      AND (p_max_cost IS NULL OR t.missing_cost_eur <= p_max_cost)
      AND (p_colors IS NULL OR cardinality(p_colors) = 0 OR dc.colors <@ p_colors)
    ORDER BY (d.commander_oracle_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id)) DESC,
             t.missing_cards,
             t.missing_cost_eur,
             d.name
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$$;

COMMENT ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text, boolean) IS
    'Decks du corpus confrontés à la collection, terrains de base exclus du '
    'compte — on ne les achète pas, on les prend dans la boîte. Leur nombre est '
    'rendu à part pour que l''interface puisse le dire.';

GRANT EXECUTE ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text, boolean)
    TO anon, authenticated;

COMMIT;
