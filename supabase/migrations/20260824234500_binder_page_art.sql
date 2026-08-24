-- `public_binder_page` rend l'illustration et la finition de chaque case.
--
-- **Pourquoi.** Le calque de désignation dessinait ses neuf cases en aplats, au
-- motif qu'à cette taille neuf illustrations se disputeraient le regard.
-- L'argument tombe devant l'écran de classeur, qui en affiche neuf depuis
-- toujours et reste lisible : c'est **la même page**, et elle doit se ressembler
-- des deux côtés. Sans ces colonnes, le calque n'a rien à dessiner.
--
-- **Les cases vides en ont besoin autant que les pleines.** L'écran de classeur
-- montre l'illustration manquante en fantôme à un quart d'opacité, le numéro
-- par-dessus : « un manque qu'on montre, pas une carte ». L'illustration de
-- l'impression représentative existe donc même pour une case qu'on ne possède
-- pas — c'est le catalogue, pas la collection.
--
-- **Rien n'est réhébergé** (§IV.3) : `art_crop_url` pointe chez l'éditeur, comme
-- partout ailleurs dans le projet.
--
-- **Un DROP emporte les GRANT.** Le type de retour change ; sans reprise
-- explicite des droits la fonction existerait en refusant `anon`, et `!page`
-- comme le calque se tairaient sans dire pourquoi.

BEGIN;

DROP FUNCTION IF EXISTS public.public_binder_page(text, text, integer, integer, text);

CREATE FUNCTION public.public_binder_page(
    p_handle   text,
    p_set_code text,
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 9,
    p_game     text DEFAULT 'magic'
)
RETURNS TABLE (
    collector_number text,
    name             text,
    printed_name     text,
    owned            integer,
    art_crop_url     text,
    has_foil         boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH bornes AS (
        SELECT GREATEST(1, LEAST(p_per_page, 60)) AS per,
               GREATEST(1, p_page)                AS num
    ),
    -- Ce que le propriétaire possède ici, dans la limite de ce qu'il partage :
    -- la RLS sur `collection_items` applique `shared_sets`, cette requête ne la
    -- répète pas.
    mine AS (
        SELECT p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE i.collection_id = public.collection_by_handle(p_handle)
          AND p.set_code = p_set_code
        GROUP BY p.collector_number
    ),
    -- Les cases de l'extension, même choix d'impression représentative et même
    -- ordre que `my_binder_page` : s'ils divergeaient, la page nommée ici ne
    -- serait pas celle qu'on voit à l'écran.
    cells AS (
        SELECT DISTINCT ON (p.collector_number)
               p.collector_number,
               p.oracle_id,
               p.printed_name,
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
    ranked AS (
        SELECT cl.*,
               row_number() OVER (
                   ORDER BY cl.number_rank NULLS LAST, cl.collector_number
               )::integer AS position
        FROM cells cl
    )
    SELECT r.collector_number,
           c.name,
           COALESCE(NULLIF(r.printed_name, ''), c.name),
           COALESCE(m.copies, 0),
           r.art_crop_url,
           COALESCE(m.foil, false)
    FROM ranked r
    JOIN public.cards c ON c.oracle_id = r.oracle_id
    LEFT JOIN mine m ON m.collector_number = r.collector_number
    CROSS JOIN bornes b
    WHERE EXISTS (SELECT 1 FROM mine)
      AND r.position > (b.num - 1) * b.per
      AND r.position <= b.num * b.per
    ORDER BY r.position;
$$;

COMMENT ON FUNCTION public.public_binder_page IS
    'Une page d''un classeur partagé, par son adresse publique. Les cases vides '
    'y figurent — c''est ce qui manque — avec l''illustration de leur impression '
    'représentative, que le classeur affiche en fantôme. Rien pour une '
    'collection non publiée, ni pour une extension retirée du partage.';

GRANT EXECUTE ON FUNCTION
    public.public_binder_page(text, text, integer, integer, text)
    TO anon, authenticated;

COMMIT;
