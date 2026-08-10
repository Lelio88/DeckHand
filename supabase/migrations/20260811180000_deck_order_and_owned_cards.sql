-- 035 — Classer les decks sur ce qu'on affiche, et montrer ce qu'on a déjà.
--
-- **Le classement contredisait le chiffre.** Les suggestions étaient rangées par
-- nombre de cartes manquantes, l'écran affichait un pourcentage : « Forged In
-- Stone » à 0 % passait devant « Token Triumph » à 1 % parce qu'il lui manquait
-- deux cartes de moins — sur un deck plus court. Les deux critères sont
-- défendables ; les mélanger ne l'est pas. Le tri suit désormais la complétion,
-- c'est-à-dire ce que la ligne montre.
--
-- Le nombre de cartes manquantes reste en second : entre deux decks également
-- complets, celui qui demande le moins d'achats passe devant. Le coût vient
-- ensuite, puis le nom, pour que l'ordre soit total — deux pages successives
-- d'une même liste ne doivent pas se recouvrir.
--
-- **Le détail montre aussi ce qu'on possède.** `deck_missing_cards` écartait les
-- cartes déjà en collection (`WHERE n.needed > owned`), si bien qu'un deck
-- entièrement constructible ouvrait sur une liste vide, et qu'on ne pouvait
-- jamais vérifier ce qu'on avait. La fonction rend maintenant toutes les cartes
-- du deck ; `missing = 0` distingue celles qui sont acquises, et l'interface
-- les regroupe en fin de liste.
--
-- Le nom ne change pas malgré l'élargissement : renommer la fonction romprait
-- l'application déployée sans rien apprendre à personne.

BEGIN;

-- ---------------------------------------------------------------------------
-- Le détail d'un deck : ce qui manque, puis ce qu'on a
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.deck_missing_cards(p_deck_id uuid)
RETURNS TABLE (
    oracle_id      uuid,
    name           text,
    printed_name   text,
    needed         integer,
    owned          integer,
    missing        integer,
    unit_price_eur numeric,
    line_cost_eur  numeric
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    ),
    needs AS (
        SELECT dc.oracle_id, SUM(dc.quantity)::integer AS needed
        FROM public.deck_cards dc
        WHERE dc.deck_id = p_deck_id AND dc.board = 'main'
        GROUP BY dc.oracle_id
    )
    SELECT c.oracle_id,
           c.name,
           fr.name,
           n.needed,
           COALESCE(m.owned, 0),
           GREATEST(n.needed - COALESCE(m.owned, 0), 0),
           p.price_eur,
           GREATEST(n.needed - COALESCE(m.owned, 0), 0) * COALESCE(p.price_eur, 0)
    FROM needs n
    JOIN public.cards c ON c.oracle_id = n.oracle_id
    LEFT JOIN mine m ON m.oracle_id = n.oracle_id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = n.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = n.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    -- Ce qui manque d'abord, du plus cher au moins cher — c'est la liste de
    -- courses. Ce qu'on possède ferme la marche, par ordre alphabétique : on n'y
    -- cherche pas un prix, on vérifie une présence.
    ORDER BY (n.needed > COALESCE(m.owned, 0)) DESC,
             (GREATEST(n.needed - COALESCE(m.owned, 0), 0) * COALESCE(p.price_eur, 0)) DESC,
             COALESCE(fr.name, c.name);
$$;

COMMENT ON FUNCTION public.deck_missing_cards(uuid) IS
    'Toutes les cartes du deck : ce qui manque en tête, ce qu''on possède '
    'ensuite. `missing = 0` distingue les secondes.';

-- ---------------------------------------------------------------------------
-- Les suggestions se classent sur la complétion
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.deck_suggestions(
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
             -- La complétion d'abord : c'est le chiffre que la ligne affiche, et
             -- classer sur un autre critère rendait l'ordre incompréhensible.
             (t.owned_cards::real / NULLIF(t.total_cards, 0)) DESC NULLS LAST,
             -- Puis le nombre de cartes à acheter, entre deux decks également
             -- complets, puis leur coût.
             t.missing_cards,
             t.missing_cost_eur,
             d.name
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$$;

COMMENT ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text, boolean) IS
    'Decks du corpus confrontés à la collection, classés sur la complétion — '
    'le chiffre que l''interface affiche.';

COMMIT;
