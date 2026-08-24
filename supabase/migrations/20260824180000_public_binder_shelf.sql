-- « T'en es où sur cette extension ? » — le rayonnage d'un classeur partagé.
--
-- **Pourquoi une fonction de plus alors que `my_binder_shelf` existe.** Celle-ci
-- filtre sur `c.owner_id = auth.uid()` : elle rend le rayonnage de *l'appelant*.
-- Sous la clé anonyme, `auth.uid()` est nul et elle ne rend rien — elle est donc
-- inutilisable par un visiteur comme par le bot de chat, bien qu'elle soit
-- accordée à `anon`. Le droit d'exécution ne dit rien de ce qu'une fonction
-- accepte en argument ; c'est la signature qui décide.
--
-- **Elle ne voit rien de plus que la page publique**, et pour les mêmes deux
-- raisons que `binder_locate` : `collection_by_handle` ne rend que des
-- collections publiées, et la lecture de `collection_items` reste soumise à
-- `collection_item_is_readable`, qui applique la portée extension par extension.
-- D'où `SECURITY INVOKER`, délibérément — en `DEFINER` elle deviendrait un
-- chemin d'accès parallèle, et le partage restreint ne vaudrait plus rien pour
-- qui connaît son nom.
--
-- **Une extension non partagée n'apparaît pas du tout**, plutôt que d'apparaître
-- à zéro : un compte « 0/453 » révélerait qu'elle existe et que le propriétaire
-- a choisi de la cacher. C'est une conséquence de la RLS, pas une clause d'ici —
-- les lignes filtrées ne sont simplement jamais comptées.
--
-- **`total_cells` compte les cases de l'extension, possédées ou non**, et se
-- déduit du catalogue : il ne dépend d'aucune ligne de collection, donc d'aucune
-- règle de partage. C'est le dénominateur d'un « 234/453 », et il doit rester
-- vrai même quand rien n'est partagé.

BEGIN;

CREATE OR REPLACE FUNCTION public.public_binder_shelf(
    p_handle text,
    p_game   text DEFAULT 'magic'
)
RETURNS TABLE (
    set_code     text,
    set_name     text,
    total_cells  integer,
    owned_cells  integer,
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
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE i.collection_id = public.collection_by_handle(p_handle)
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
           (SELECT MIN(s.set_name) FROM public.card_prints s WHERE s.set_code = o.set_code),
           (SELECT COUNT(DISTINCT t.collector_number)::integer
            FROM public.card_prints t
            WHERE t.set_code = o.set_code),
           o.cells,
           o.copies
    FROM owned o
    ORDER BY o.cells DESC, o.set_code;
$$;

COMMENT ON FUNCTION public.public_binder_shelf IS
    'Rayonnage d''un classeur partagé, par son adresse publique. Rend les '
    'extensions visibles du demandeur et leur remplissage. Rien pour une '
    'collection non publiée, et rien pour une extension non partagée : une '
    'adresse essayée au hasard ne doit pas révéler ce qu''elle cache.';

GRANT EXECUTE ON FUNCTION public.public_binder_shelf(text, text) TO anon, authenticated;

COMMIT;
