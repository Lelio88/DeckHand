-- 040 — Deux régimes de lecture pour un classeur : ranger, ou inventorier.
--
-- **Le tri par numéro range, les autres inventorient**, et la différence porte
-- sur les cases vides.
--
-- Trié par **numéro**, le classeur montre les cases vides : c'est une vue de
-- complétion d'édition, et « il me manque le #6 » est la question posée. Trié
-- par **valeur** ou par **nom**, la question change — « mes cartes, de la plus
-- chère à la moins chère » — et une case vide n'a plus ni valeur ni place. Elle
-- disparaît, et c'est ce que la demande implique : on ne regarde plus ce qui
-- manque, on regarde ce qu'on a.
--
-- **Le filtre de finition ne change pas de régime.** Restreindre au brillant ne
-- sort pas du rangement : le classeur reste ordonné par numéro, seule change la
-- définition de « possédé ». Une case vide y signifie « je n'ai pas cette carte
-- en brillant », ce qui est une complétion à part entière — celle d'un classeur
-- de brillants. Les trous restent donc, à dessein.
--
-- **Une page vide n'est pas une impasse.** Un filtre serré laisse des feuilles
-- entièrement creuses ; `my_binder_first_page` dit où commencer pour ne pas
-- feuilleter du vide.
--
-- `my_binder_page` change de signature et doit être supprimée avant d'être
-- recréée (migration 038).

BEGIN;

-- L'ancienne signature à trois arguments disparaît ; la nouvelle est créée en
-- `OR REPLACE` pour que la migration reste rejouable, comme le veut la
-- convention du projet.
DROP FUNCTION IF EXISTS public.my_binder_page(text, integer, integer);

CREATE OR REPLACE FUNCTION public.my_binder_page(
    p_set_code text,
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 9,
    p_sort     text    DEFAULT 'number',
    p_finish   text    DEFAULT NULL
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
        SELECT DISTINCT ON (p.collector_number)
               p.collector_number,
               p.scryfall_id,
               p.oracle_id,
               p.printed_name,
               p.rarity,
               p.art_crop_url,
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code = p_set_code
        ORDER BY p.collector_number,
                 (p.lang = 'fr') DESC,
                 (p.lang = 'en') DESC,
                 p.scryfall_id
    ),
    -- **Le prix se prend sur la case, pas sur l'impression représentative.**
    -- Celle-ci est choisie française pour son nom imprimé, or Scryfall ne cote
    -- pratiquement que l'anglais : trier par valeur ne triait rien, toutes les
    -- cases valant zéro. La case étant le même objet physique quelle que soit
    -- la langue, son prix est celui de la plus chère de ses impressions.
    prices AS (
        SELECT p.collector_number, MAX(p.price_eur) AS price_eur
        FROM public.card_prints p
        WHERE p.set_code = p_set_code
        GROUP BY p.collector_number
    ),
    mine AS (
        SELECT p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        WHERE c.owner_id = auth.uid()
          AND p.set_code = p_set_code
          AND (p_finish IS NULL
               OR (p_finish = 'foil' AND i.is_foil)
               OR (p_finish = 'nonfoil' AND NOT i.is_foil))
        GROUP BY p.collector_number
    ),
    joined AS (
        SELECT cl.*,
               pr.price_eur,
               COALESCE(m.copies, 0)    AS owned,
               COALESCE(m.foil, false)  AS has_foil
        FROM cells cl
        LEFT JOIN prices pr ON pr.collector_number = cl.collector_number
        LEFT JOIN mine m ON m.collector_number = cl.collector_number
        -- Hors du rangement, une case vide n'a rien à dire : ni valeur, ni
        -- nom, ni place dans un ordre qui ne connaît pas les numéros.
        WHERE p_sort = 'number' OR COALESCE(m.copies, 0) > 0
    )
    SELECT j.collector_number,
           j.oracle_id,
           j.scryfall_id,
           c.name,
           j.printed_name,
           j.rarity,
           j.art_crop_url,
           j.price_eur,
           j.owned,
           j.has_foil
    FROM joined j
    LEFT JOIN public.cards c ON c.oracle_id = j.oracle_id
    ORDER BY
        -- Le prix d'une case sans cote vaut zéro plutôt que rien : en ordre
        -- décroissant, `NULLS FIRST` les mettrait avant les plus chères.
        CASE WHEN p_sort = 'price' THEN COALESCE(j.price_eur, 0) END DESC,
        CASE WHEN p_sort = 'name'  THEN COALESCE(j.printed_name, c.name) END ASC,
        j.number_rank NULLS LAST,
        j.collector_number
    LIMIT GREATEST(1, LEAST(p_per_page, 60))
    OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60));
$$;

COMMENT ON FUNCTION public.my_binder_page(text, integer, integer, text, text) IS
    'Une page de classeur. Trié par numéro, les cases vides figurent — c''est '
    'une complétion. Trié par valeur ou par nom, elles disparaissent : la '
    'question posée n''est plus « que me manque-t-il » mais « qu''ai-je ».';

GRANT EXECUTE ON FUNCTION public.my_binder_page(text, integer, integer, text, text)
    TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Où commencer quand le filtre laisse des feuilles vides
-- ---------------------------------------------------------------------------

-- Un classeur de 97 feuilles dont on ne possède que douze cartes s'ouvre sinon
-- sur du vide, et il faut tourner des pages au hasard pour trouver la première
-- carte. Le rang est calculé dans l'ordre du rangement, seul cas où des feuilles
-- peuvent être entièrement creuses.
CREATE OR REPLACE FUNCTION public.my_binder_first_page(
    p_set_code text,
    p_per_page integer DEFAULT 9,
    p_finish   text    DEFAULT NULL
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH cells AS (
        SELECT DISTINCT ON (p.collector_number)
               p.collector_number,
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code = p_set_code
        ORDER BY p.collector_number
    ),
    ranked AS (
        SELECT cl.collector_number,
               ROW_NUMBER() OVER (ORDER BY cl.number_rank NULLS LAST, cl.collector_number)
                   AS position
        FROM cells cl
    ),
    mine AS (
        SELECT DISTINCT p.collector_number
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        WHERE c.owner_id = auth.uid()
          AND p.set_code = p_set_code
          AND (p_finish IS NULL
               OR (p_finish = 'foil' AND i.is_foil)
               OR (p_finish = 'nonfoil' AND NOT i.is_foil))
    )
    -- Aucune carte : on ouvre à la première page, qui dira au moins ce qui
    -- manque.
    SELECT COALESCE(
        MIN(((r.position - 1) / GREATEST(1, LEAST(p_per_page, 60)))::integer + 1),
        1
    )
    FROM ranked r
    JOIN mine m ON m.collector_number = r.collector_number;
$$;

COMMENT ON FUNCTION public.my_binder_first_page(text, integer, text) IS
    'Première feuille portant au moins une carte possédée, pour ne pas ouvrir '
    'un classeur sur du vide quand un filtre est actif.';

GRANT EXECUTE ON FUNCTION public.my_binder_first_page(text, integer, text)
    TO anon, authenticated;

COMMIT;
