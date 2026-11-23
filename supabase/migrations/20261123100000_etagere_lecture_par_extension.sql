-- L'étagère lit le catalogue extension par extension, au lieu de le balayer.
--
-- Symptôme (issue n°52) : la page publique d'un classeur recevait une erreur
-- 500 de `my_binder_shelf` au premier chargement — « canceling statement due
-- to statement timeout » (57014). Le rôle `anon` coupe à 3 s, `authenticated`
-- à 8 s : la même lenteur frappait le propriétaire, simplement sans le faire
-- échouer. La page finissait par s'afficher parce qu'un appel suivant, cache
-- chaud, passait sous les 3 s.
--
-- Cause, mesurée sous `anon` sur une collection publiée de 87 extensions :
-- la lecture de la collection (RLS comprise) coûte 75 ms. Le reste — taille
-- de chaque extension (`sizes`) et carte-vedette (`star`) — passait par un
-- `Merge Semi Join` qui parcourt **tout** l'index `idx_card_prints_set`, deux
-- fois, soit les 176 k impressions, pour n'en garder que les 87 extensions
-- possédées : 364 k pages lues, 1,0 s cache chaud, 5,3 s à froid. Le
-- planificateur estime à 200 les lignes de `owned` (estimation par défaut d'un
-- CTE) et préfère alors la fusion au parcours ciblé.
--
-- **Correctif : un `LATERAL` par extension possédée.** Chaque extension lit
-- ses seules impressions par l'index `(set_code, collector_number)`, et la
-- carte-vedette s'arrête à la première (`LIMIT 1`). Même jeu de lignes, au
-- bit près (vérifié sur la collection de mesure) : 90 k pages, 0,29 s cache
-- chaud, 0,48 s à froid. Aucun index ajouté — celui qui existe suffit dès
-- qu'on le lit par extension.
--
-- Rien ne change de ce que la fonction rend ni de ce qu'elle laisse voir : la
-- lecture de `collection_items` (CTE `mine`) est reprise telle quelle, donc
-- soumise à la même RLS (`collection_item_is_readable`) ; la fonction reste
-- `SECURITY INVOKER`. Signature et type de retour sont identiques, d'où
-- `CREATE OR REPLACE` sans `DROP`.
--
-- Refs : issue n°52 ; garde-fou §IV.12 — la fonction est recréée par une
-- nouvelle migration, jamais éditée sur place.

BEGIN;

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
    )
    SELECT o.set_code,
           sz.set_name,
           sz.released_at,
           sz.total,
           o.cells,
           o.copies,
           st.art_crop_url,
           cs.icon_svg_uri,
           cs.parent_set_code,
           cs.set_type
    FROM owned o
    -- La taille d'un classeur est celle de l'édition entière, pas de ce qu'on
    -- en possède : c'est ce qui rend le taux de complétion lisible.
    CROSS JOIN LATERAL (
        SELECT MIN(p.set_name)                             AS set_name,
               MIN(p.released_at)                          AS released_at,
               COUNT(DISTINCT p.collector_number)::integer AS total
        FROM public.card_prints p
        WHERE p.set_code = o.set_code
    ) sz
    -- **La carte-vedette de l'extension**, et non la plus chère qu'on possède :
    -- un classeur s'identifie comme un produit, pas comme un inventaire. Le
    -- prix se lit sur `card_prints` sans repli linguistique, à dessein — la
    -- version anglaise porte la cote, la française porte la même illustration,
    -- et c'est l'illustration qu'on cherche ici.
    --
    -- Une extension de jetons n'a aucune cote : la première case fait alors une
    -- couverture stable, là où l'ordre du moteur en changerait à chaque appel.
    LEFT JOIN LATERAL (
        SELECT p.art_crop_url
        FROM public.card_prints p
        WHERE p.set_code = o.set_code
          AND p.art_crop_url IS NOT NULL
        ORDER BY p.price_eur DESC NULLS LAST, p.collector_number
        LIMIT 1
    ) st ON true
    LEFT JOIN public.card_sets cs ON cs.code = o.set_code
    -- Le classeur le plus rempli d'abord : c'est celui qu'on vient regarder.
    -- L'application regroupe ensuite par famille, ce tri restant celui qui
    -- désigne la tête de chaque groupe.
    ORDER BY o.cells DESC, o.set_code;
$function$;

COMMENT ON FUNCTION public.my_binder_shelf(text, uuid) IS
    'Étagère des classeurs : un par extension possédée, avec sa parenté '
    '(parent_set_code) et sa nature (set_type). Le catalogue se lit extension '
    'par extension (LATERAL) : un balayage de card_prints dépassait les 3 s du '
    'rôle anon. Le regroupement par famille est affaire d''affichage — les '
    'numérotations se chevauchent, deux extensions ne peuvent pas partager un '
    'classeur.';

GRANT EXECUTE ON FUNCTION public.my_binder_shelf(text, uuid) TO anon, authenticated;

COMMIT;
