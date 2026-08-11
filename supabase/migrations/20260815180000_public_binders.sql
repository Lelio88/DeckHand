-- Une collection peut se donner à lire, et à personne d'autre.
--
-- **Le drapeau est par collection et vaut `false` par défaut.** Une politique
-- publique sans drapeau s'appliquerait à *toutes* les collections, y compris
-- celles d'amis qui n'ont rien demandé. Le défaut à faux rend la publication
-- explicite et révocable, sans imposer de jeton ni de cérémonie.
--
-- **Ce qui sort, et rien de plus.** `anon` reçoit un droit de lecture sur trois
-- colonnes de `collections` — `id`, `name`, `is_public` — et sur aucune autre :
-- `owner_id` reste invisible, si bien qu'une collection publique ne se rattache
-- à aucun compte. Les droits par colonne existent précisément pour ça ; une
-- politique seule aurait ouvert la ligne entière.
--
-- **La politique est le seul garde-fou, et c'est assumé.** `anon` n'avait aucun
-- droit de lecture sur `collection_items` ; lui en donner un fait reposer toute
-- la confidentialité sur le `USING`. Il tient en une ligne, il est vérifiable,
-- et il est vérifié sous le rôle `anon` — sur une collection publiée *et* sur
-- une collection qui ne l'est pas, car seul le second cas prouve quelque chose.
--
-- **La résolution vit à un seul endroit.** `readable_collection` répond à la
-- question « quelle collection ai-je le droit de lire » : la mienne quand on ne
-- demande rien, celle qu'on désigne si elle est publique ou si elle m'appartient,
-- et rien sinon. Les fonctions de classeur l'appellent au lieu de comparer
-- `owner_id` à `auth.uid()` — une seule règle, un seul endroit où se tromper.
--
-- Les deux fonctions changent de signature et doivent donc être supprimées avant
-- d'être recréées : ajouter un paramètre en créerait une surcharge, et PostgREST
-- ne saurait plus laquelle appeler. Le paramètre est ajouté **en dernier** et
-- porte un défaut : les appels existants de l'application restent valides.

BEGIN;

ALTER TABLE public.collections
    ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.collections.is_public IS
    'Rend la collection lisible sans compte. Faux par défaut : la publication '
    'est un geste, jamais un effet de bord.';

-- ---------------------------------------------------------------------------
-- Ce qu'un inconnu peut lire
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS collections_public_read ON public.collections;
CREATE POLICY collections_public_read
    ON public.collections FOR SELECT
    TO anon, authenticated
    USING (is_public);

-- Trois colonnes, pas la ligne. `owner_id` n'en fait pas partie.
GRANT SELECT (id, name, is_public) ON public.collections TO anon;

DROP POLICY IF EXISTS collection_items_public_read ON public.collection_items;
CREATE POLICY collection_items_public_read
    ON public.collection_items FOR SELECT
    TO anon, authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.collections c
            WHERE c.id = collection_items.collection_id AND c.is_public
        )
    );

GRANT SELECT ON public.collection_items TO anon;

-- ---------------------------------------------------------------------------
-- Quelle collection ai-je le droit de lire ?
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.readable_collection(p_collection uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT c.id
    FROM public.collections c
    WHERE CASE
              -- Rien de demandé : la mienne, comme avant.
              WHEN p_collection IS NULL THEN c.owner_id = auth.uid()
              -- Une collection désignée : la sienne, ou une publiée.
              ELSE c.id = p_collection
                   AND (c.is_public OR c.owner_id = auth.uid())
          END
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.readable_collection IS
    'Collection que l''appelant a le droit de lire : la sienne sans argument, '
    'celle qu''il désigne si elle est publique ou lui appartient, rien sinon.';

GRANT EXECUTE ON FUNCTION public.readable_collection(uuid) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Le classeur accepte de parler d'une autre collection que la mienne
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.my_binder_shelf(text);
DROP FUNCTION IF EXISTS public.my_binder_page(text, integer, integer, text, text, boolean);

CREATE OR REPLACE FUNCTION public.my_binder_shelf(p_game text DEFAULT 'magic'::text, p_collection uuid DEFAULT NULL::uuid)
 RETURNS TABLE(set_code text, set_name text, released_at date, total_cells integer, owned_cells integer, owned_copies integer, art_crop_url text, icon_svg_uri text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH mine AS (
        SELECT p.set_code,
               p.collector_number,
               SUM(i.quantity)::integer AS copies
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.id = public.readable_collection(p_collection)
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
           cs.icon_svg_uri
    FROM sizes s
    JOIN owned o ON o.set_code = s.set_code
    LEFT JOIN star st ON st.set_code = s.set_code
    LEFT JOIN public.card_sets cs ON cs.code = s.set_code
    -- Le classeur le plus rempli d'abord : c'est celui qu'on vient regarder.
    ORDER BY o.cells DESC, s.set_code;
$function$;

CREATE OR REPLACE FUNCTION public.my_binder_page(p_set_code text, p_page integer DEFAULT 1, p_per_page integer DEFAULT 9, p_sort text DEFAULT 'number'::text, p_finish text DEFAULT NULL::text, p_descending boolean DEFAULT false, p_collection uuid DEFAULT NULL::uuid)
 RETURNS TABLE(collector_number text, oracle_id uuid, print_id uuid, name text, printed_name text, rarity text, art_crop_url text, price_eur numeric, price_eur_foil numeric, owned integer, has_foil boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
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
    mine AS (
        SELECT p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil,
               -- Le plus récent des ajouts de la case : une case peut réunir
               -- plusieurs lignes — deux langues, deux finitions — et c'est le
               -- dernier geste qui la fait remonter.
               MAX(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        WHERE c.id = public.readable_collection(p_collection)
          AND p.set_code = p_set_code
          AND (p_finish IS NULL
               OR (p_finish = 'foil' AND i.is_foil)
               OR (p_finish = 'nonfoil' AND NOT i.is_foil))
        GROUP BY p.collector_number
    ),
    -- **Les prix ne se calculent que pour ce qui sera rendu.**
    -- `print_price` n'est pas inlinable — elle porte un `SET search_path` —,
    -- et la calculer pour toute l'extension coûtait 1 732 appels de fonction
    -- pour neuf cases : 770 ms mesurées sur `msh`. Les cases dont on a besoin
    -- sont pourtant connues d'avance, et de deux façons selon le tri.
    --
    -- Rangé par numéro, l'ordre ne dépend d'aucun prix : la page se découpe
    -- avant de coter quoi que ce soit, et l'ordre reproduit exactement celui de
    -- la sortie — s'ils divergeaient, on coterait les mauvaises cases.
    --
    -- Rangé autrement, les cases vides disparaissent de toute façon : seules
    -- celles qu'on possède peuvent survivre, et elles sont peu nombreuses.
    wanted AS (
        -- Le découpage vit dans une sous-requête : un `ORDER BY … LIMIT` ne
        -- s'attache pas au bras gauche d'une union, il la termine.
        SELECT page.collector_number
        FROM (
            SELECT cl.collector_number
            FROM cells cl
            WHERE p_sort = 'number'
            ORDER BY
                CASE WHEN p_descending THEN cl.number_rank END DESC NULLS LAST,
                cl.number_rank NULLS LAST,
                cl.collector_number
            LIMIT GREATEST(1, LEAST(p_per_page, 60))
            OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60))
        ) page
        UNION ALL
        SELECT m.collector_number
        FROM mine m
        WHERE p_sort <> 'number'
    ),
    -- `print_price` porte le repli linguistique — Scryfall ne cote
    -- pratiquement que l'anglais — et distingue les deux finitions.
    prices AS (
        SELECT p.collector_number,
               MAX(public.print_price(p.scryfall_id, false)) AS price_eur,
               MAX(public.print_price(p.scryfall_id, true))  AS price_eur_foil
        FROM public.card_prints p
        WHERE p.set_code = p_set_code
          AND p.collector_number IN (SELECT w.collector_number FROM wanted w)
        GROUP BY p.collector_number
    ),
    joined AS (
        SELECT cl.*,
               pr.price_eur,
               pr.price_eur_foil,
               COALESCE(m.copies, 0)   AS owned,
               COALESCE(m.foil, false) AS has_foil,
               m.added_at,
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
        -- ni exemplaires, ni date d'entrée, ni place dans un ordre qui ne
        -- connaît pas les numéros.
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
        -- La dernière entrée d'abord : on trie par date pour vérifier ce qu'on
        -- vient de saisir, jamais pour remonter à ses débuts.
        CASE WHEN p_sort = 'recent' AND NOT p_descending THEN j.added_at END DESC,
        CASE WHEN p_sort = 'recent' AND     p_descending THEN j.added_at END ASC,
        CASE WHEN p_sort = 'name'  AND NOT p_descending THEN COALESCE(j.printed_name, c.name) END ASC,
        CASE WHEN p_sort = 'name'  AND     p_descending THEN COALESCE(j.printed_name, c.name) END DESC,
        CASE WHEN p_sort = 'number' AND p_descending THEN j.number_rank END DESC NULLS LAST,
        -- À égalité — deux cartes entrées dans le même lot, deux cases au même
        -- nombre d'exemplaires — l'ordre du rangement reprend la main.
        j.number_rank NULLS LAST,
        j.collector_number
    LIMIT GREATEST(1, LEAST(p_per_page, 60))
    OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60));
$function$;


GRANT EXECUTE ON FUNCTION public.my_binder_shelf(text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.my_binder_page(text, integer, integer, text, text, boolean, uuid) TO anon, authenticated;

COMMIT;
