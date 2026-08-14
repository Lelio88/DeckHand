-- 20260816170000 — L'étagère rend la parenté et la nature de chaque extension.
--
-- Motivation : une sortie Magic ne produit pas une extension mais une famille.
-- « Marvel Super Heroes » en a quatre — l'extension de boosters (`msh`, 453
-- cartes), les decks Commander (`msc`, 866), et un jeu de jetons pour chacune
-- (`tmsh`, `tmsc`). L'étagère les présentait à plat, comme s'ils n'avaient aucun
-- rapport : cinq classeurs en vrac pour une seule sortie, et rien ne disait
-- lequel dépendait duquel.
--
-- La base le savait pourtant déjà. `card_sets.parent_set_code` est ingéré depuis
-- l'origine et n'était **lu nulle part** — ni ici, ni côté application. Cette
-- migration l'expose, avec `set_type` qui distingue les jetons.
--
-- Ce que la parenté ne doit PAS faire : fusionner les classeurs. Chaque
-- extension a sa propre numérotation, et les numéros se chevauchent — le n° 1
-- vaut « Agent 13, Sharon Carter » dans `msh`, « Invisible Woman » dans `msc` et
-- « Wall » dans `tmsh`. Trois cartes ne tiennent pas dans une case. Le
-- regroupement est donc une affaire d'affichage, et le tri reste à
-- l'application : la base rend les faits, l'écran décide de l'ordre.
--
-- Refs : garde-fou §IV.11 — la fonction est recréée, jamais éditée sur place.

BEGIN;

DROP FUNCTION IF EXISTS public.my_binder_shelf(text, uuid);

CREATE OR REPLACE FUNCTION public.my_binder_shelf(
    p_game text DEFAULT 'magic'::text,
    p_collection uuid DEFAULT NULL::uuid
)
 RETURNS TABLE(
    set_code text,
    set_name text,
    released_at date,
    total_cells integer,
    owned_cells integer,
    owned_copies integer,
    art_crop_url text,
    icon_svg_uri text,
    parent_set_code text,
    set_type text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH mine AS (
        SELECT p.set_code,
               p.collector_number,
               SUM(i.quantity)::integer AS copies
        FROM public.collection_items i
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE i.collection_id = public.readable_collection(p_collection)
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
    -- **La carte-vedette de l'extension**, et non la plus chère qu'on possède :
    -- un classeur s'identifie comme un produit, pas comme un inventaire. Le
    -- prix se lit sur `card_prints` sans repli linguistique, à dessein — la
    -- version anglaise porte la cote, la française porte la même illustration,
    -- et c'est l'illustration qu'on cherche ici.
    --
    -- Une extension de jetons n'a aucune cote : la première case fait alors une
    -- couverture stable, là où l'ordre du moteur en changerait à chaque appel.
    star AS (
        SELECT DISTINCT ON (p.set_code)
               p.set_code,
               p.art_crop_url
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT o.set_code FROM owned o)
          AND p.art_crop_url IS NOT NULL
        ORDER BY p.set_code,
                 p.price_eur DESC NULLS LAST,
                 p.collector_number
    )
    SELECT s.set_code,
           s.set_name,
           s.released_at,
           s.total,
           o.cells,
           o.copies,
           st.art_crop_url,
           cs.icon_svg_uri,
           cs.parent_set_code,
           cs.set_type
    FROM sizes s
    JOIN owned o ON o.set_code = s.set_code
    LEFT JOIN star st ON st.set_code = s.set_code
    LEFT JOIN public.card_sets cs ON cs.code = s.set_code
    -- Le classeur le plus rempli d'abord : c'est celui qu'on vient regarder.
    -- L'application regroupe ensuite par famille, ce tri restant celui qui
    -- désigne la tête de chaque groupe.
    ORDER BY o.cells DESC, s.set_code;
$function$;

COMMENT ON FUNCTION public.my_binder_shelf(text, uuid) IS
    'Étagère des classeurs : un par extension possédée, avec sa parenté '
    '(parent_set_code) et sa nature (set_type). Le regroupement par famille est '
    'affaire d''affichage — les numérotations se chevauchent, deux extensions '
    'ne peuvent pas partager un classeur.';

GRANT EXECUTE ON FUNCTION public.my_binder_shelf(text, uuid) TO anon, authenticated;

COMMIT;
