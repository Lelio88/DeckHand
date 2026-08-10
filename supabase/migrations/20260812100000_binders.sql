-- 038 — Le classeur : une étagère d'éditions, et les cases de chacune.
--
-- **Un classeur est une édition, une case est un numéro.** Il n'y a donc rien à
-- stocker : la case est le couple `(set_code, collector_number)`, déjà porté par
-- `card_prints`. Le classeur se dérive de la collection, il ne s'y ajoute pas —
-- et l'on ne peut pas le désynchroniser, puisqu'il n'en est qu'une lecture.
--
-- **Une case n'est pas une impression.** Le catalogue porte l'anglais et le
-- français ; le #412 anglais et le #412 français partagent la même case, la
-- langue étant une propriété de ce qu'on y range et non de la case. Chaque case
-- élit donc une impression représentative pour son illustration et son nom, en
-- préférant le français quand il existe — c'est la langue de l'interface, et
-- l'illustration est de toute façon la même.
--
-- **Ce que le classeur montre vraiment, ce sont les cases vides.** C'est une vue
-- de complétion d'édition : la page part du catalogue et non de la collection,
-- si bien qu'une case non possédée existe, occupe sa place, et se voit.
--
-- **Les cartes sans édition précisée n'ont aucune case**, par construction.
-- Elles ne sont pas perdues pour autant : `my_collection_summary` les compte
-- déjà, et l'écran le rappelle — elles sont rangeables nulle part tant qu'on n'a
-- pas dit lesquelles.
--
-- Le brillant ne dédouble pas la case : deux cases pour le même numéro
-- casseraient la grille physique. Il est signalé sur la case qu'il occupe.

BEGIN;

-- ---------------------------------------------------------------------------
-- L'étagère : les éditions dont on possède au moins une carte
-- ---------------------------------------------------------------------------

-- 695 éditions au catalogue : l'entrée ne peut pas être un classeur, ce serait
-- 690 classeurs vides. Seules celles où quelque chose est rangé figurent ici.
CREATE OR REPLACE FUNCTION public.my_binder_shelf(
    p_game text DEFAULT 'magic'
)
RETURNS TABLE (
    set_code    text,
    set_name    text,
    released_at date,
    total_cells integer,
    owned_cells integer,
    owned_copies integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH mine AS (
        SELECT p.set_code,
               p.collector_number,
               SUM(i.quantity)::integer AS copies
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
        GROUP BY p.set_code, p.collector_number
    ),
    owned AS (
        SELECT m.set_code,
               COUNT(*)::integer      AS cells,
               SUM(m.copies)::integer AS copies
        FROM mine m
        GROUP BY m.set_code
    ),
    -- La taille d'un classeur est celle de l'édition entière, pas de ce qu'on
    -- en possède : c'est ce qui rend le taux de complétion lisible.
    sizes AS (
        SELECT p.set_code,
               MIN(p.set_name)                            AS set_name,
               MIN(p.released_at)                         AS released_at,
               COUNT(DISTINCT p.collector_number)::integer AS total
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT o.set_code FROM owned o)
        GROUP BY p.set_code
    )
    SELECT s.set_code,
           s.set_name,
           s.released_at,
           s.total,
           o.cells,
           o.copies
    FROM sizes s
    JOIN owned o ON o.set_code = s.set_code
    -- Le classeur le plus rempli d'abord : c'est celui qu'on vient regarder.
    ORDER BY o.cells DESC, s.set_code;
$$;

COMMENT ON FUNCTION public.my_binder_shelf(text) IS
    'Éditions dont au moins une carte est possédée, avec la taille du classeur '
    'et ce qui y est rangé. Les 690 autres éditions du catalogue seraient des '
    'classeurs vides.';

GRANT EXECUTE ON FUNCTION public.my_binder_shelf(text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Une page de classeur : neuf cases, vides comprises
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.my_binder_page(
    p_set_code text,
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 9
)
RETURNS TABLE (
    collector_number text,
    oracle_id        uuid,
    print_id         uuid,
    name             text,
    printed_name     text,
    rarity           text,
    art_crop_url     text,
    price_eur        numeric,
    owned            integer,
    has_foil         boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH cells AS (
        -- Une ligne par case, et non par impression : le #412 anglais et le
        -- #412 français sont la même case. Le français est préféré pour le nom
        -- imprimé, l'illustration étant identique de toute façon.
        SELECT DISTINCT ON (p.collector_number)
               p.collector_number,
               p.scryfall_id,
               p.oracle_id,
               p.printed_name,
               p.rarity,
               p.art_crop_url,
               p.price_eur,
               -- Le numéro est un `text` qui accepte les suffixes (`43a`,
               -- `★43`) : trié comme du texte, 100 précéderait 2.
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code = p_set_code
        ORDER BY p.collector_number,
                 (p.lang = 'fr') DESC,
                 (p.lang = 'en') DESC,
                 p.scryfall_id
    ),
    page AS (
        SELECT * FROM cells
        ORDER BY number_rank NULLS LAST, collector_number
        LIMIT GREATEST(1, LEAST(p_per_page, 60))
        OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60))
    ),
    -- Ce qu'on possède dans cette édition, toutes langues et finitions
    -- confondues : c'est la case qui est possédée, pas l'impression.
    mine AS (
        SELECT p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        WHERE c.owner_id = auth.uid()
          AND p.set_code = p_set_code
        GROUP BY p.collector_number
    )
    SELECT pg.collector_number,
           pg.oracle_id,
           pg.scryfall_id,
           c.name,
           pg.printed_name,
           pg.rarity,
           pg.art_crop_url,
           pg.price_eur,
           COALESCE(m.copies, 0),
           COALESCE(m.foil, false)
    FROM page pg
    LEFT JOIN public.cards c ON c.oracle_id = pg.oracle_id
    LEFT JOIN mine m ON m.collector_number = pg.collector_number
    ORDER BY pg.number_rank NULLS LAST, pg.collector_number;
$$;

COMMENT ON FUNCTION public.my_binder_page(text, integer, integer) IS
    'Une page de classeur : les cases de l''édition dans l''ordre des numéros, '
    'possédées ou non. Les cases vides sont l''intérêt de la vue — c''est une '
    'complétion d''édition, pas une liste de possessions.';

GRANT EXECUTE ON FUNCTION public.my_binder_page(text, integer, integer)
    TO anon, authenticated;

COMMIT;
