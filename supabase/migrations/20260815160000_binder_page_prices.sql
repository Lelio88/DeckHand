-- Une page de classeur ne cote plus toute l'extension.
--
-- **Mesuré avant d'y toucher** : 770 ms pour rendre neuf cases de `msh`, 384 ms
-- au milieu du classeur. Pour neuf lignes, c'est le serveur qui fait attendre,
-- pas le réseau.
--
-- La cause est dans le CTE `prices` : il appelait `print_price` pour **chaque
-- impression de l'extension et chaque finition** — 866 × 2 = 1 732 appels — puis
-- jetait tout sauf neuf lignes. Et `print_price` n'est pas inlinable par
-- Postgres : elle porte un `SET search_path`, ce qui en fait une boîte noire
-- exécutée ligne à ligne, chacune avec sa sous-requête corrélée pour le repli
-- linguistique.
--
-- **Les cases utiles sont pourtant connues d'avance.** Rangé par numéro, l'ordre
-- ne dépend d'aucun prix : la page se découpe avant de coter. Rangé autrement,
-- les cases vides disparaissent de toute façon — seules celles qu'on possède
-- peuvent survivre. Le CTE `wanted` réunit ces deux cas, et `prices` s'y
-- restreint.
--
-- L'ordre de `wanted` reproduit **exactement** celui de la sortie pour le tri
-- par numéro. S'ils divergeaient, on coterait les mauvaises cases et les prix
-- afficheraient ceux des voisines — un défaut silencieux, plausible à l'écran.
--
-- Rien d'autre ne change : mêmes paramètres, mêmes colonnes, même ordre.

BEGIN;

CREATE OR REPLACE FUNCTION public.my_binder_page(p_set_code text, p_page integer DEFAULT 1, p_per_page integer DEFAULT 9, p_sort text DEFAULT 'number'::text, p_finish text DEFAULT NULL::text, p_descending boolean DEFAULT false)
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
        WHERE c.owner_id = auth.uid()
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

GRANT EXECUTE ON FUNCTION public.my_binder_page(text, integer, integer, text, text, boolean) TO anon, authenticated;

COMMIT;
