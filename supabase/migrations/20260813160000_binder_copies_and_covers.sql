-- 044 — Trier par exemplaires, et donner une couverture à chaque classeur.
--
-- **« Combien en ai-je » est une question de rangement.** Les doublons se
-- comptent déjà case par case (`×3` au coin d'une carte), mais rien ne
-- rassemblait ce qu'on possède en nombre : pour trouver les quatre exemplaires
-- d'une commune, il fallait parcourir le classeur en entier. C'est pourtant la
-- question qu'on pose avant de bâtir un deck — un playset se repère, il ne se
-- cherche pas.
--
-- Le tri par exemplaires **inventorie**, comme la valeur et le nom : une case
-- vide en compte zéro, et une page de zéros n'apprend rien. Elle disparaît
-- donc, conformément au régime déjà en place (migration 040). À égalité — et
-- l'égalité est la règle, la plupart des cartes étant possédées en un seul
-- exemplaire — l'ordre du rangement reprend la main.
--
-- **Une étagère de noms ne se distingue pas.** Cinq lignes de texte gris se
-- ressemblent toutes ; un classeur physique se reconnaît de loin, à sa tranche.
-- Chaque édition remonte donc l'illustration de **la plus chère des cartes
-- qu'on y possède** — le joyau du classeur, celui qu'on a envie d'aller
-- revoir. Elle est calculée et non stockée, comme tout le reste de la vue : on
-- ne peut donc pas la désynchroniser, et elle change d'elle-même quand la
-- collection grandit.
--
-- Le prix est celui de `print_price`, avec son repli linguistique : Scryfall ne
-- cote pratiquement que l'anglais, et se fier à la cote de l'impression
-- possédée élirait une carte au hasard sur une collection française.
--
-- `my_binder_page` garde sa signature (`CREATE OR REPLACE` suffit) ;
-- `my_binder_shelf` gagne une colonne et doit donc être supprimée d'abord.

BEGIN;

-- ---------------------------------------------------------------------------
-- Trier une page par nombre d'exemplaires
-- ---------------------------------------------------------------------------

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
        -- ni exemplaires, ni place dans un ordre qui ne connaît pas les
        -- numéros.
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
        -- Les plus nombreuses d'abord : « ai-je un playset ? » se lit en tête
        -- de classeur, pas en le parcourant.
        CASE WHEN p_sort = 'copies' AND NOT p_descending THEN j.owned END DESC,
        CASE WHEN p_sort = 'copies' AND     p_descending THEN j.owned END ASC,
        CASE WHEN p_sort = 'name'  AND NOT p_descending THEN COALESCE(j.printed_name, c.name) END ASC,
        CASE WHEN p_sort = 'name'  AND     p_descending THEN COALESCE(j.printed_name, c.name) END DESC,
        CASE WHEN p_sort = 'number' AND p_descending THEN j.number_rank END DESC NULLS LAST,
        -- À égalité d'exemplaires — le cas courant, la plupart des cartes étant
        -- possédées une seule fois — l'ordre du rangement reprend la main.
        j.number_rank NULLS LAST,
        j.collector_number
    LIMIT GREATEST(1, LEAST(p_per_page, 60))
    OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60));
$$;

COMMENT ON FUNCTION public.my_binder_page(text, integer, integer, text, text, boolean) IS
    'Une page de classeur, avec les deux prix de chaque case. Trié par numéro, '
    'les cases vides figurent — c''est une complétion. Trié par valeur, par '
    'exemplaires ou par nom, elles disparaissent. `p_descending` renverse le '
    'sens de lecture.';

GRANT EXECUTE ON FUNCTION public.my_binder_page(text, integer, integer, text, text, boolean)
    TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- La couverture d'un classeur : sa plus belle carte
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.my_binder_shelf(text);

CREATE FUNCTION public.my_binder_shelf(
    p_game text DEFAULT 'magic'
)
RETURNS TABLE (
    set_code     text,
    set_name     text,
    released_at  date,
    total_cells  integer,
    owned_cells  integer,
    owned_copies integer,
    art_crop_url text
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
    ),
    -- **La plus chère qu'on y possède**, et non une carte représentative de
    -- l'édition : le classeur est le sien, sa couverture doit l'être aussi.
    -- Une illustration inconnue disqualifie l'impression plutôt que le
    -- classeur — la suivante prend sa place.
    cover AS (
        SELECT DISTINCT ON (p.set_code)
               p.set_code,
               p.art_crop_url
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        WHERE c.owner_id = auth.uid()
          AND p.art_crop_url IS NOT NULL
          AND p.set_code IN (SELECT o.set_code FROM owned o)
        ORDER BY p.set_code,
                 public.print_price(i.print_id, i.is_foil) DESC NULLS LAST,
                 -- Sans cote — le cas d'une collection entièrement française —
                 -- la première case du classeur fait une couverture stable,
                 -- là où l'ordre du moteur en changerait à chaque requête.
                 p.collector_number
    )
    SELECT s.set_code,
           s.set_name,
           s.released_at,
           s.total,
           o.cells,
           o.copies,
           cv.art_crop_url
    FROM sizes s
    JOIN owned o ON o.set_code = s.set_code
    LEFT JOIN cover cv ON cv.set_code = s.set_code
    -- Le classeur le plus rempli d'abord : c'est celui qu'on vient regarder.
    ORDER BY o.cells DESC, s.set_code;
$$;

COMMENT ON FUNCTION public.my_binder_shelf(text) IS
    'Éditions dont au moins une carte est possédée, avec la taille du classeur, '
    'ce qui y est rangé, et l''illustration de la plus chère carte qu''on y '
    'possède — une étagère de noms ne se distingue pas.';

GRANT EXECUTE ON FUNCTION public.my_binder_shelf(text) TO anon, authenticated;

COMMIT;
