-- Ce que je possède déjà, sur les deux voies du scan photo et non sur une seule
--
-- L'écran qui suit une photo annonce désormais, ligne par ligne, le nombre
-- d'exemplaires déjà en collection : carte en main, on sait si l'on ajoute une
-- quatrième copie ou une première. `search_cards_bulk` rend ce chiffre depuis
-- toujours — la voie des noms lus, c'est-à-dire le cas ordinaire, l'avait donc
-- gratuitement.
--
-- **Le recours par illustration passe, lui, par `cards_by_oracle_ids`, qui ne
-- le rendait pas.** Le laisser ainsi aurait fait afficher « rien en
-- collection » sur une carte possédée en trois exemplaires, et ce mensonge
-- aurait été muet : rien, à l'écran, ne distingue « zéro » de « je n'en sais
-- rien ». L'écran doit dire la même chose quelle que soit la voie qui a parlé.
--
-- Le calcul est copié mot pour mot de `search_cards_bulk` : somme des
-- quantités de toutes les impressions et finitions de la carte, dans les
-- collections du demandeur. C'est la granularité choisie — la question posée
-- devant un carton est « est-ce que je l'ai ? », pas « est-ce que j'ai ce
-- tirage-là ? », à quoi le sélecteur d'édition répond déjà par son « Déjà N »
-- ligne à ligne.
--
-- **Sous `anon`, le chiffre vaut zéro et c'est correct** : `auth.uid()` y est
-- nul, la jointure ne retient aucune collection. La fonction reste
-- `SECURITY INVOKER`, donc la RLS de `collection_items` continue de décider —
-- `search_cards_bulk`, accordée aux mêmes rôles, fait exactement cela depuis
-- son écriture.
--
-- **Le type de retour change, donc la fonction est reconstruite** — et un
-- `DROP` emporte les `GRANT`. Sans leur reprise explicite en fin de fichier, la
-- fonction existerait en refusant ses appelants, ce qui se lit à l'écran comme
-- un catalogue muet.

BEGIN;

DROP FUNCTION IF EXISTS public.cards_by_oracle_ids(uuid[], uuid[]);

CREATE FUNCTION public.cards_by_oracle_ids(
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
    WITH mine AS (
        -- Une seule fois pour tout le lot, et non par carte demandée.
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    )
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
    LEFT JOIN mine m ON m.oracle_id = c.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    ORDER BY requested.position;
$$;

COMMENT ON FUNCTION public.cards_by_oracle_ids(uuid[], uuid[]) IS
    'Cartes dans l''ordre demandé. `p_prints` désigne, position par position, '
    'l''impression reconnue : son illustration est alors celle rendue, faute de '
    'quoi l''écran montrerait une autre version de la même carte. `owned` '
    'compte les exemplaires déjà en collection, toutes éditions confondues, '
    'comme le fait `search_cards_bulk` — l''écran de scan doit annoncer le '
    'même chiffre quelle que soit la voie qui a reconnu la carte.';

GRANT EXECUTE ON FUNCTION public.cards_by_oracle_ids(uuid[], uuid[])
    TO anon, authenticated;

COMMIT;
