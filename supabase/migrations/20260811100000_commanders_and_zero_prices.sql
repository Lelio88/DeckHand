-- 032 — Le commandant d'un deck, et l'absence de prix rangée avec le zéro.
--
-- **Un prix inconnu se range où on le cherche.** Le tri par valeur plaçait les
-- cartes sans cote en queue de liste dans les deux sens : en ordre croissant,
-- elles arrivaient donc *après* les plus chères. Or personne ne cherche une
-- carte sans prix à côté des plus précieuses ; on la cherche là où sont les
-- cartes qui ne valent rien. La valorisation compte déjà ces cartes pour zéro
-- dans le total de la collection — le rangement dit désormais la même chose.
--
-- Ce n'est pas inventer un prix : la ligne continue d'afficher un tiret. Seul
-- l'ordre change.
--
-- **Le commandant identifie un deck mieux que sa source.** `decks` porte déjà
-- `commander_oracle_id`, rempli pour les 190 précons Commander, mais rien ne le
-- remontait à l'application, qui affichait à la place la provenance de la liste
-- — une information que le bandeau d'attribution donne déjà, et qui ne dit rien
-- de ce qu'on va jouer. Le nom du commandant part donc avec la suggestion, et
-- l'identifiant avec lui : c'est ce qui permet d'ouvrir la carte en grand.
--
-- **Chercher un deck par son commandant** est la façon dont on choisit un deck
-- Commander : on part du général qu'on veut jouer. La recherche passe par
-- `card_search_names`, donc accepte le nom français comme l'anglais et tolère
-- les fautes de frappe au même titre que la saisie de collection.
--
-- Les deux fonctions changent de signature : supprimées avant d'être recréées,
-- sous peine de surcharge PostgREST (migration 012).

BEGIN;

-- ---------------------------------------------------------------------------
-- Collection : l'absence de cote vaut zéro pour le rangement
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.my_collection(
    text, text, integer, integer, text, boolean, boolean, text, boolean);

CREATE FUNCTION public.my_collection(
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
        -- `COALESCE(…, 0)` et non `NULLS LAST` : une carte sans cote se range
        -- avec celles qui ne valent rien, pas après les plus chères.
        CASE WHEN p_sort = 'price'    AND     p_descending THEN COALESCE(p.unit_price * p.quantity, 0) END DESC,
        CASE WHEN p_sort = 'price'    AND NOT p_descending THEN COALESCE(p.unit_price * p.quantity, 0) END ASC,
        CASE WHEN p_sort = 'quantity' AND     p_descending THEN p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' AND NOT p_descending THEN p.quantity END ASC  NULLS LAST,
        CASE WHEN p_sort = 'recent'   AND     p_descending THEN p.added_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   AND NOT p_descending THEN p.added_at END ASC  NULLS LAST,
        CASE WHEN p_sort = 'number'   AND     p_descending THEN p.number_rank END DESC NULLS LAST,
        CASE WHEN p_sort = 'number'   AND NOT p_descending THEN p.number_rank END ASC  NULLS LAST,
        CASE WHEN p_sort = 'rarity'   AND     p_descending THEN p.rarity_rank END DESC NULLS LAST,
        CASE WHEN p_sort = 'rarity'   AND NOT p_descending THEN p.rarity_rank END ASC  NULLS LAST,
        CASE WHEN p_sort = 'name'     AND     p_descending THEN COALESCE(p.shown_name, c.name) END DESC,
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST,
        p.is_foil
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection(text, text, integer, integer, text, boolean, boolean, text, boolean) IS
    'Page de collection : cherchable, triable dans les deux sens, restreignable '
    'à une finition, aux pleines illustrations ou à ce qui reste à préciser. '
    'Une carte sans cote se range avec celles qui valent zéro.';

GRANT EXECUTE ON FUNCTION public.my_collection(text, text, integer, integer, text, boolean, boolean, text, boolean)
    TO authenticated;

-- ---------------------------------------------------------------------------
-- Suggestions : le commandant, affiché et cherchable
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.deck_suggestions(
    text, integer, integer, numeric, text, text, text[]);

CREATE FUNCTION public.deck_suggestions(
    p_format      text,
    p_max_missing integer DEFAULT 100,
    p_max_results integer DEFAULT 30,
    p_max_cost    numeric DEFAULT NULL,
    p_tier        text    DEFAULT NULL,
    p_game        text    DEFAULT 'magic',
    p_colors      text[]  DEFAULT NULL,
    p_commander   text    DEFAULT NULL
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
    commander_name      text
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
          -- Le commandant se cherche par n'importe lequel de ses noms, français
          -- comme anglais : c'est le même index que la saisie de collection.
          AND ((SELECT n FROM wanted) = ''
               OR EXISTS (
                    SELECT 1 FROM public.card_search_names s
                    WHERE s.oracle_id = d.commander_oracle_id
                      AND s.normalized LIKE '%' || (SELECT n FROM wanted) || '%'
               ))
    ),
    needs AS (
        SELECT dc.deck_id,
               dc.oracle_id,
               SUM(dc.quantity)::integer AS needed
        FROM public.deck_cards dc
        JOIN chosen ON chosen.id = dc.deck_id
        WHERE dc.board = 'main'
        GROUP BY dc.deck_id, dc.oracle_id
    ),
    deck_colors AS (
        SELECT n.deck_id,
               COALESCE(
                   array_agg(DISTINCT ci ORDER BY ci) FILTER (WHERE ci IS NOT NULL),
                   ARRAY[]::text[]
               ) AS colors
        FROM needs n
        JOIN public.cards c ON c.oracle_id = n.oracle_id
        LEFT JOIN LATERAL unnest(c.color_identity) AS ci ON true
        GROUP BY n.deck_id
    ),
    gaps AS (
        SELECT n.deck_id,
               n.oracle_id,
               n.needed,
               GREATEST(n.needed - COALESCE(m.owned, 0), 0) AS missing
        FROM needs n
        LEFT JOIN mine m ON m.oracle_id = n.oracle_id
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
           COALESCE(fr.name, cmd.name)
    FROM totals t
    JOIN public.decks d ON d.id = t.deck_id
    JOIN public.deck_sources s ON s.id = d.source_id
    JOIN deck_colors dc ON dc.deck_id = t.deck_id
    LEFT JOIN public.cards cmd ON cmd.oracle_id = d.commander_oracle_id
    -- Le nom français quand il existe : c'est celui de la carte qu'on a en main.
    LEFT JOIN LATERAL (
        SELECT sn.name
        FROM public.card_search_names sn
        WHERE sn.oracle_id = d.commander_oracle_id AND sn.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE t.missing_cards <= p_max_missing
      AND (p_max_cost IS NULL OR t.missing_cost_eur <= p_max_cost)
      AND (p_colors IS NULL OR cardinality(p_colors) = 0 OR dc.colors <@ p_colors)
    ORDER BY t.missing_cards, t.missing_cost_eur, d.name
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$$;

COMMENT ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text) IS
    'Decks du corpus confrontés à la collection, filtrables par cartes '
    'manquantes, budget, provenance, identité couleur et nom de commandant. '
    'Porte le commandant, qui identifie un deck mieux que sa source.';

GRANT EXECUTE ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text)
    TO anon, authenticated;

COMMIT;
