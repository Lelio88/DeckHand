-- 042 — Les deux prix d'une case, et le sens de lecture.
--
-- **Une case a deux prix, pas un.** Le brillant et le normal partagent la même
-- case — deux cases pour un même numéro casseraient la grille — mais se vendent
-- couramment du simple au triple. La feuille d'action doit donc pouvoir
-- afficher l'un ou l'autre selon la finition qu'on s'apprête à ajouter, sans
-- rappeler le serveur : les deux voyagent ensemble.
--
-- **Le sens de lecture se renverse.** Re-choisir un critère de tri l'inversait
-- dans la liste de collection ; le classeur avait perdu ce geste en passant aux
-- menus. `p_descending` le rend, avec la même règle qu'ailleurs : par numéro on
-- part de la dernière page, par valeur des cartes les moins chères, par nom de
-- Z vers A.
--
-- Une carte sans cote vaut zéro plutôt que rien : en ordre décroissant,
-- `NULLS FIRST` la placerait avant les plus chères.
--
-- `my_binder_page` change de signature ; l'ancienne est supprimée.

BEGIN;

DROP FUNCTION IF EXISTS public.my_binder_page(text, integer, integer, text, text);

CREATE OR REPLACE FUNCTION public.my_binder_page(
    p_set_code   text,
    p_page       integer DEFAULT 1,
    p_per_page   integer DEFAULT 9,
    p_sort       text    DEFAULT 'number',
    p_finish     text    DEFAULT NULL,
    p_descending boolean DEFAULT false
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
    price_eur_foil   numeric,
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
    -- `print_price` porte le repli linguistique — Scryfall ne cote
    -- pratiquement que l'anglais — et distingue les deux finitions.
    prices AS (
        SELECT p.collector_number,
               MAX(public.print_price(p.scryfall_id, false)) AS price_eur,
               MAX(public.print_price(p.scryfall_id, true))  AS price_eur_foil
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
               pr.price_eur_foil,
               COALESCE(m.copies, 0)   AS owned,
               COALESCE(m.foil, false) AS has_foil,
               -- Le tri par valeur porte sur la finition regardée : filtrer les
               -- brillants en classant sur des prix de cartes mates n'aurait
               -- aucun sens.
               COALESCE(
                   CASE WHEN p_finish = 'foil' THEN pr.price_eur_foil ELSE pr.price_eur END,
                   0
               ) AS sort_price
        FROM cells cl
        LEFT JOIN prices pr ON pr.collector_number = cl.collector_number
        LEFT JOIN mine m ON m.collector_number = cl.collector_number
        -- Hors du rangement, une case vide n'a rien à dire : ni valeur, ni nom,
        -- ni place dans un ordre qui ne connaît pas les numéros.
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
           j.price_eur_foil,
           j.owned,
           j.has_foil
    FROM joined j
    LEFT JOIN public.cards c ON c.oracle_id = j.oracle_id
    ORDER BY
        CASE WHEN p_sort = 'price' AND NOT p_descending THEN j.sort_price END DESC,
        CASE WHEN p_sort = 'price' AND     p_descending THEN j.sort_price END ASC,
        CASE WHEN p_sort = 'name'  AND NOT p_descending THEN COALESCE(j.printed_name, c.name) END ASC,
        CASE WHEN p_sort = 'name'  AND     p_descending THEN COALESCE(j.printed_name, c.name) END DESC,
        CASE WHEN p_sort = 'number' AND p_descending THEN j.number_rank END DESC NULLS LAST,
        j.number_rank NULLS LAST,
        j.collector_number
    LIMIT GREATEST(1, LEAST(p_per_page, 60))
    OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60));
$$;

COMMENT ON FUNCTION public.my_binder_page(text, integer, integer, text, text, boolean) IS
    'Une page de classeur, avec les deux prix de chaque case. Trié par numéro, '
    'les cases vides figurent — c''est une complétion. Trié par valeur ou par '
    'nom, elles disparaissent. `p_descending` renverse le sens de lecture.';

GRANT EXECUTE ON FUNCTION public.my_binder_page(text, integer, integer, text, text, boolean)
    TO anon, authenticated;

COMMIT;
