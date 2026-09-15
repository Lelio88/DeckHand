-- Lire la collection que les écritures visent, et seulement la case demandée.
--
-- **Deux collections sont possibles.** Rien n'impose l'unicité de
-- `collections.owner_id` : `ensure_my_collection` cherche la collection de
-- l'appelant puis la crée, et deux premiers ajouts simultanés passeraient tous
-- deux la recherche. Aucun propriétaire n'en a deux aujourd'hui (vérifié le
-- 15 septembre 2026), mais trois fonctions ne s'accordaient pas sur ce cas :
--
-- - `ensure_my_collection`, qui sert toutes les écritures, prend la **plus
--   ancienne** (`ORDER BY created_at`) ;
-- - `readable_collection(NULL)`, qui sert le classeur, en prenait **une
--   quelconque** (`LIMIT 1` sans ordre) ;
-- - `my_binder_case_editions` additionnait **toutes** celles du propriétaire.
--
-- Le classeur aurait alors proposé de retirer un exemplaire rangé dans une
-- collection où le retrait ne va pas le chercher. `readable_collection` suit
-- désormais l'ordre des écritures, et `my_binder_case_editions` lit par elle.
--
-- **La case seule.** `my_binder_case_editions` agrégeait toute la collection
-- avant de n'en garder que les impressions de la case ; elle part maintenant de
-- la case. `readable_collection` y est évaluée une fois, en sous-requête : c'est
-- une fonction SECURITY DEFINER, donc jamais dépliée dans la requête.

BEGIN;

CREATE OR REPLACE FUNCTION public.readable_collection(p_collection uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.id
    FROM public.collections c
    WHERE CASE
              -- Rien de demandé : la mienne — la plus ancienne, comme
              -- `ensure_my_collection`, qui sert les écritures.
              WHEN p_collection IS NULL THEN c.owner_id = auth.uid()
              -- Une collection désignée : la sienne, ou une publiée.
              ELSE c.id = p_collection
                   AND (c.is_public OR c.owner_id = auth.uid())
          END
    ORDER BY c.created_at, c.id
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.my_binder_case_editions(p_print_id uuid)
RETURNS TABLE (
    print_id     uuid,
    lang         text,
    printed_name text,
    qty_normal   integer,
    qty_foil     integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    -- La case se déduit de l'impression de départ : même extension, même
    -- numéro.
    WITH la_case AS (
        SELECT set_code, collector_number
        FROM public.card_prints
        WHERE scryfall_id = p_print_id
    ),
    impressions AS (
        SELECT p.scryfall_id, p.lang, p.printed_name
        FROM public.card_prints p
        JOIN la_case lc ON lc.set_code = p.set_code
                       AND lc.collector_number IS NOT DISTINCT FROM p.collector_number
    ),
    mine AS (
        SELECT i.print_id,
               SUM(i.quantity) FILTER (WHERE NOT i.is_foil)::integer AS qty_normal,
               SUM(i.quantity) FILTER (WHERE i.is_foil)::integer     AS qty_foil
        FROM public.collection_items i
        JOIN impressions im ON im.scryfall_id = i.print_id
        WHERE i.collection_id = (SELECT public.readable_collection(NULL))
        GROUP BY i.print_id
    )
    SELECT im.scryfall_id,
           im.lang,
           im.printed_name,
           COALESCE(m.qty_normal, 0),
           COALESCE(m.qty_foil, 0)
    FROM impressions im
    LEFT JOIN mine m ON m.print_id = im.scryfall_id
    ORDER BY im.lang;
$$;

COMMIT;
