-- Le prix le moins cher, joint carte par carte plutôt que catalogue entier
--
-- Corrige le `canceling statement due to statement timeout` (57014) que le scan
-- d'un étalement rendait régulièrement. **Le volume n'y était pour rien** :
-- mesuré sous le rôle `authenticated`, cent cinquante noms tiennent en trois
-- secondes, et du texte qui ne ressemble à aucune carte coûte *moins* cher
-- qu'un vrai nom — la recherche floue ne trouve rien à relire.
--
-- Le coupable est `card_cheapest_price`, une vue
-- `SELECT oracle_id, min(price_eur) ... GROUP BY oracle_id`. Postgres ne pousse
-- pas le filtre à travers son agrégat : il la calcule **pour tout le
-- catalogue** — 245 468 impressions, 76 873 cartes — puis joint les quelques
-- cartes trouvées.
--
-- **Ce qui se mesure n'est pas la moyenne mais la queue.** Sur dix noms, la
-- vue a rendu 5,457 s contre 0,522 s de médiane — un facteur 10,5, c'est-à-dire
-- une bascule de plan, pas un ralentissement. C'est exactement la forme d'un
-- timeout qui frappe « de temps en temps » : la moyenne reste bonne, et le
-- pire cas dépasse les huit secondes du rôle. La latérale, elle, tient un
-- rapport de 1,0 à 1,1 et touche 3 à 32 fois moins de blocs — 298 Mio contre
-- 9 504 sur dix noms. Ces blocs sont ce qu'il faut lire au disque quand le
-- cache est froid, donc ce qui décide du premier appel après une pause.
--
-- **Trois fonctions seulement**, celles qui cherchent peu de cartes :
-- `search_cards` (vingt résultats), `search_cards_bulk` (cinquante noms) et
-- `cards_by_oracle_ids` (les cartes reconnues). Les six autres lectrices de la
-- vue portent sur des centaines ou des milliers de cartes — `my_collection`,
-- `deck_suggestions`, `my_collection_summary`, `my_buildable_cards`,
-- `my_unsorted_pile`, `deck_missing_cards` — et l'agrégat complet peut y être
-- le bon plan. Les changer sans les mesurer serait remplacer un pari par un
-- autre ; le banc `app.measure.price_join` est là pour ça.
--
-- La vue reste en place : elle sert encore ces six-là, et un `DROP` emporterait
-- leurs plans sans rien régler.

BEGIN;

CREATE OR REPLACE FUNCTION public.search_cards(q text, max_results integer DEFAULT 20, p_game text DEFAULT 'magic'::text, p_types text[] DEFAULT NULL::text[])
 RETURNS TABLE(oracle_id uuid, name text, matched_name text, matched_lang text, type_line text, mana_cost text, price_eur numeric, legal_pauper boolean, legal_modern boolean, legal_commander boolean, score real, owned integer, art_url text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
    WITH needle AS (
        SELECT public.normalize_card_name(q) AS n
    ),
    matches AS (
        SELECT s.oracle_id,
               s.name AS matched_name,
               s.lang AS matched_lang,
               GREATEST(
                   similarity(s.normalized, (SELECT n FROM needle)),
                   CASE
                       WHEN s.normalized = (SELECT n FROM needle) THEN 1.0
                       WHEN s.normalized LIKE (SELECT n FROM needle) || ' %'
                           THEN 0.85 + 0.13 * (
                               length((SELECT n FROM needle))::real
                               / GREATEST(length(s.normalized), 1)
                           )
                       WHEN s.normalized LIKE (SELECT n FROM needle) || '%'
                           THEN 0.70 + 0.14 * (
                               length((SELECT n FROM needle))::real
                               / GREATEST(length(s.normalized), 1)
                           )
                       ELSE 0
                   END
               )::real AS score
        FROM public.card_search_names s
        WHERE (SELECT n FROM needle) <> ''
          AND (s.normalized % (SELECT n FROM needle)
               OR s.normalized LIKE (SELECT n FROM needle) || '%')
    ),
    best AS (
        SELECT DISTINCT ON (m.oracle_id) m.*
        FROM matches m
        ORDER BY m.oracle_id, m.score DESC
    ),
    mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    )
    SELECT c.oracle_id,
           c.name,
           b.matched_name,
           b.matched_lang,
           c.type_line,
           c.mana_cost,
           p.price_eur,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           b.score,
           -- Zéro plutôt que NULL pour un visiteur non connecté : la recherche
           -- reste publique, et « possédé : 0 » est la vérité pour lui.
           COALESCE(m.owned, 0),
           (SELECT pr.art_crop_url
            FROM public.card_prints pr
            WHERE pr.oracle_id = c.oracle_id AND pr.art_crop_url IS NOT NULL
            ORDER BY (pr.lang = 'en') DESC, pr.released_at NULLS LAST, pr.scryfall_id
            LIMIT 1)
    FROM best b
    -- Le cloisonnement se fait ici plutôt que dans `matches` : la table des noms
    -- indexés ne porte pas le jeu, et l'y ajouter obligerait à la reconstruire
    -- entièrement pour un gain nul à cette échelle.
    JOIN public.cards c ON c.oracle_id = b.oracle_id AND c.game = p_game
    -- Le prix le moins cher, calculé pour les cartes trouvées et pour elles
    -- seules. La vue `card_cheapest_price` agrège `GROUP BY oracle_id` ;
    -- Postgres ne pousse pas le filtre à travers cet agrégat et la calcule
    -- pour tout le catalogue avant de joindre. Mesuré : 5,457 s sur dix noms
    -- là où la médiane est 0,522 s — une bascule de plan, donc un timeout
    -- qui frappe au hasard. Voir `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur
        FROM public.card_prints pr
        WHERE pr.oracle_id = b.oracle_id
    ) p ON true
    LEFT JOIN mine m ON m.oracle_id = b.oracle_id
    WHERE p_types IS NULL
       OR cardinality(p_types) = 0
       -- Une carte cumulant deux types répond aux deux filtres, ce qui est la
       -- lecture juste de « Artifact Creature ».
       OR EXISTS (
            SELECT 1 FROM unnest(p_types) AS t(kind)
            WHERE c.type_line ILIKE '%' || t.kind || '%'
       )
    ORDER BY b.score DESC, length(c.name), c.name
    LIMIT GREATEST(1, LEAST(max_results, 50));
$function$;

CREATE OR REPLACE FUNCTION public.search_cards_bulk(p_names text[], p_game text DEFAULT 'magic'::text)
 RETURNS TABLE(query text, oracle_id uuid, name text, matched_name text, matched_lang text, type_line text, mana_cost text, price_eur numeric, legal_pauper boolean, legal_modern boolean, legal_commander boolean, score real, owned integer, art_url text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
    WITH needles AS (
        -- `DISTINCT` : une photo d'étalement lit souvent deux fois le même nom
        -- (nom scindé, deux exemplaires côte à côte). Chercher deux fois la
        -- même chose coûterait le double pour rien.
        SELECT DISTINCT
               t.txt                                AS query,
               public.normalize_card_name(t.txt)    AS n
        FROM unnest(p_names) AS t(txt)
        WHERE public.normalize_card_name(t.txt) <> ''
    ),
    mine AS (
        -- Une seule fois pour tout le lot, et non par nom cherché.
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    )
    SELECT nd.query,
           b.oracle_id,
           b.name,
           b.matched_name,
           b.matched_lang,
           b.type_line,
           b.mana_cost,
           p.price_eur,
           b.legal_pauper,
           b.legal_modern,
           b.legal_commander,
           b.score,
           COALESCE(m.owned, 0),
           (SELECT pr.art_crop_url
            FROM public.card_prints pr
            WHERE pr.oracle_id = b.oracle_id AND pr.art_crop_url IS NOT NULL
            ORDER BY (pr.lang = 'en') DESC, pr.released_at NULLS LAST, pr.scryfall_id
            LIMIT 1)
    FROM needles nd
    -- **Le cloisonnement par jeu est dans la latérale, pas après.** Le mettre
    -- après reviendrait à élire la meilleure correspondance tous jeux
    -- confondus, puis à la jeter si elle vient du mauvais catalogue — en
    -- rendant vide un nom qui avait pourtant une réponse dans le bon.
    CROSS JOIN LATERAL (
        SELECT c.oracle_id,
               c.name,
               s.name AS matched_name,
               s.lang AS matched_lang,
               c.type_line,
               c.mana_cost,
               c.legal_pauper,
               c.legal_modern,
               c.legal_commander,
               GREATEST(
                   similarity(s.normalized, nd.n),
                   CASE
                       WHEN s.normalized = nd.n THEN 1.0
                       WHEN s.normalized LIKE nd.n || ' %'
                           THEN 0.85 + 0.13 * (
                               length(nd.n)::real / GREATEST(length(s.normalized), 1))
                       WHEN s.normalized LIKE nd.n || '%'
                           THEN 0.70 + 0.14 * (
                               length(nd.n)::real / GREATEST(length(s.normalized), 1))
                       ELSE 0
                   END
               )::real AS score
        FROM public.card_search_names s
        JOIN public.cards c
          ON c.oracle_id = s.oracle_id AND c.game = p_game
        WHERE s.normalized % nd.n
           OR s.normalized LIKE nd.n || '%'
        -- Même départage que `search_cards` : à score égal, le nom le plus
        -- court gagne, puis l'ordre alphabétique. Sans quoi deux scans de la
        -- même photo pourraient rendre deux cartes différentes.
        ORDER BY score DESC, length(c.name), c.name
        LIMIT 1
    ) b
    -- Le prix le moins cher, calculé pour les cartes trouvées et pour elles
    -- seules. La vue `card_cheapest_price` agrège `GROUP BY oracle_id` ;
    -- Postgres ne pousse pas le filtre à travers cet agrégat et la calcule
    -- pour tout le catalogue avant de joindre. Mesuré : 5,457 s sur dix noms
    -- là où la médiane est 0,522 s — une bascule de plan, donc un timeout
    -- qui frappe au hasard. Voir `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur
        FROM public.card_prints pr
        WHERE pr.oracle_id = b.oracle_id
    ) p ON true
    LEFT JOIN mine m ON m.oracle_id = b.oracle_id;
$function$;

CREATE OR REPLACE FUNCTION public.cards_by_oracle_ids(p_ids uuid[], p_prints uuid[] DEFAULT NULL::uuid[])
 RETURNS TABLE(oracle_id uuid, name text, printed_name text, type_line text, price_eur numeric, legal_pauper boolean, legal_modern boolean, legal_commander boolean, art_url text, owned integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
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
    -- Le prix le moins cher, calculé pour les cartes trouvées et pour elles
    -- seules. La vue `card_cheapest_price` agrège `GROUP BY oracle_id` ;
    -- Postgres ne pousse pas le filtre à travers cet agrégat et la calcule
    -- pour tout le catalogue avant de joindre. Mesuré : 5,457 s sur dix noms
    -- là où la médiane est 0,522 s — une bascule de plan, donc un timeout
    -- qui frappe au hasard. Voir `app.measure.price_join`.
    LEFT JOIN LATERAL (
        SELECT min(pr.price_eur) AS price_eur
        FROM public.card_prints pr
        WHERE pr.oracle_id = c.oracle_id
    ) p ON true
    LEFT JOIN public.owned_by_oracle(p_ids) m ON m.oracle_id = c.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    ORDER BY requested.position;
$function$;

COMMIT;
