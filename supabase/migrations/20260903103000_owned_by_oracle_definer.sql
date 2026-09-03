-- Compter ce que je possède sans exiger de lire à qui sont les collections
--
-- Correction de `20260903100000_cards_by_oracle_ids_owned.sql`, dont le défaut
-- n'a été vu qu'**en appelant la fonction sous les deux rôles** : la somme y
-- joignait `public.collections` pour retrouver le propriétaire, or `anon` a le
-- `SELECT` sur `collection_items` (les classeurs publics en dépendent) et **pas**
-- sur `collections` — un inconnu ne doit pas pouvoir rattacher une collection à
-- un compte. L'appel anonyme passait donc de 200 à
-- `42501 permission denied for table collections`.
--
-- Sans conséquence dans l'application, toujours authentifiée. Mais
-- `cards_by_oracle_ids` est accordée à `anon` depuis son écriture, et retirer
-- en silence un accès que le bot de chat pourrait vouloir demain est
-- exactement le piège que ce projet documente ailleurs : une fonction reste
-- accordée tout en cessant de répondre.
--
-- `search_cards_bulk` porte le même défaut depuis son écriture — vérifié, elle
-- rend le même 401 sous `anon`. Ce n'est pas une raison de l'imiter.
--
-- **La fonction a besoin de consulter `collections.owner_id`, pas de le
-- rendre** : c'est mot pour mot le cas de `readable_collection`, et la réponse
-- est la même. `owned_by_oracle` s'exécute avec les droits du propriétaire, ne
-- rend qu'un couple (carte, quantité), et son `WHERE` tient en une ligne —
-- `c.owner_id = auth.uid()`. Sous `anon`, `auth.uid()` est nul, la comparaison
-- ne retient aucune collection, et la fonction rend zéro ligne au lieu d'un
-- refus. C'est la réponse juste : un inconnu ne possède rien.

BEGIN;

CREATE OR REPLACE FUNCTION public.owned_by_oracle(p_ids uuid[])
RETURNS TABLE(oracle_id uuid, owned integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT i.oracle_id, SUM(i.quantity)::integer
    FROM public.collection_items i
    JOIN public.collections c ON c.id = i.collection_id
    WHERE c.owner_id = auth.uid()
      AND i.oracle_id = ANY(p_ids)
    GROUP BY i.oracle_id;
$$;

COMMENT ON FUNCTION public.owned_by_oracle(uuid[]) IS
    'Exemplaires possédés par l''appelant, toutes éditions et finitions '
    'confondues, pour les cartes demandées. SECURITY DEFINER pour consulter '
    'collections.owner_id sans jamais le rendre — `anon` n''y a pas le SELECT, '
    'et une jointure directe le lui refusait tout l''appel.';

-- Même signature de retour qu'à la migration précédente : `CREATE OR REPLACE`
-- suffit, les droits survivent. Ils sont malgré tout réaffirmés plus bas — la
-- ligne est idempotente, et l'oubli inverse coûte une fonction qui existe en
-- refusant ses appelants.
CREATE OR REPLACE FUNCTION public.cards_by_oracle_ids(
    p_ids uuid[],
    p_prints uuid[] DEFAULT NULL
)
RETURNS TABLE(
    oracle_id uuid,
    name text,
    printed_name text,
    type_line text,
    price_eur numeric,
    legal_pauper boolean,
    legal_modern boolean,
    legal_commander boolean,
    art_url text,
    owned integer
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
    SELECT c.oracle_id,
           c.name,
           fr.name,
           c.type_line,
           p.price_eur,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           -- L'illustration reconnue d'abord ; à défaut, celle d'origine.
           -- Le repli compte : `p_prints` est absent des appels qui ne viennent
           -- pas d'un scan (une liste de decks, un classeur), et une impression
           -- peut n'avoir aucune illustration servie.
           COALESCE(
               (SELECT pr.art_crop_url
                FROM public.card_prints pr
                WHERE pr.scryfall_id = requested.print_id
                  AND pr.art_crop_url IS NOT NULL),
               (SELECT pr.art_crop_url
                FROM public.card_prints pr
                WHERE pr.oracle_id = c.oracle_id AND pr.art_crop_url IS NOT NULL
                ORDER BY (pr.lang = 'en') DESC, pr.released_at NULLS LAST,
                         pr.scryfall_id
                LIMIT 1)
           ),
           COALESCE(m.owned, 0)
    FROM unnest(
             p_ids,
             COALESCE(
                 p_prints,
                 array_fill(NULL::uuid, ARRAY[coalesce(cardinality(p_ids), 0)])
             )
         ) WITH ORDINALITY AS requested(id, print_id, position)
    JOIN public.cards c ON c.oracle_id = requested.id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = c.oracle_id
    LEFT JOIN public.owned_by_oracle(p_ids) m ON m.oracle_id = c.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    ORDER BY requested.position;
$$;

GRANT EXECUTE ON FUNCTION public.owned_by_oracle(uuid[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cards_by_oracle_ids(uuid[], uuid[])
    TO anon, authenticated;

COMMIT;
