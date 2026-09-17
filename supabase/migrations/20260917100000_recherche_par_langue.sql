-- La recherche par nom peut se borner aux langues demandées
--
-- **Ce paramètre n'est pas une optimisation, et la mesure l'a démenti.** Il a
-- été écrit pour réparer une régression supposée : verser les dix-huit langues
-- de noms fait passer `card_search_names` de 145 189 à 348 518 lignes, et un
-- relevé fait juste après l'ingestion donnait 3,28 s pour 68 noms là où le
-- chiffre d'avant, noté dans `card_repository.dart`, était 1,40 s.
--
-- **Ce relevé mesurait un cache froid, pas la taille de la table.** Repris le
-- lendemain, base au repos, le même banc rend 1,44 s pour 68 noms — la valeur
-- d'avant l'ingestion. Et le filtre lui-même n'apporte quasiment rien :
--
--       100 noms neufs, ordre des appels alterné
--       18 langues   1,82 s
--       en + fr      1,75 s        écart 4 %
--
-- L'alternance est ce qui a révélé l'erreur : sans elle, le second appel hérite
-- du cache que le premier vient de remplir, et la mesure conclut en faveur de
-- celui qui passe en second, quel qu'il soit. Un premier protocole donnait
-- ainsi « -63 % » ; c'était l'ordre, pas la langue.
--
-- **Pourquoi le paramètre reste malgré tout.** L'index trigramme se parcourt
-- avant que la langue ne soit connue : le filtre écarte des lignes après coup,
-- donc il ne peut pas rendre ce que le parcours a déjà coûté. Il ne sert donc
-- pas la vitesse — mais il sert le produit, en laissant l'appelant restreindre
-- la recherche aux langues qu'il lit. C'est la brique d'un réglage utilisateur,
-- pas un correctif de performance, et rien dans ce fichier ne doit laisser
-- croire le contraire.
--
-- Retirer les langues, en revanche, n'a jamais été une option : une carte
-- allemande, italienne ou japonaise n'est trouvable par son nom que depuis
-- qu'elles sont là.
--
-- **`NULL` cherche partout**, et c'est le défaut : un appelant qui ne sait rien
-- de ce paramètre se comporte exactement comme avant cette migration. Le
-- tableau vide vaut `NULL` — une préférence utilisateur non renseignée ne doit
-- pas rendre la recherche muette.
--
-- **`DROP` puis `CREATE`, et non `CREATE OR REPLACE`.** Ajouter un paramètre
-- change la signature : `REPLACE` créerait une surcharge, laisserait l'ancienne
-- en place, et PostgREST ne saurait plus laquelle appeler. Les droits partent
-- avec la fonction, d'où les `GRANT` en fin de fichier.

BEGIN;

DROP FUNCTION IF EXISTS public.search_cards(text, integer, text, text[]);

CREATE FUNCTION public.search_cards(
    q text,
    max_results integer DEFAULT 20,
    p_game text DEFAULT 'magic'::text,
    p_types text[] DEFAULT NULL::text[],
    p_langs text[] DEFAULT NULL::text[]
)
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
          -- Le filtre de langue est écrit avant celui de similarité, mais c'est
          -- de la lisibilité, pas de l'ordonnancement : le planificateur choisit
          -- seul, et il attaque par l'index trigramme. D'où les 4 % mesurés.
          AND (p_langs IS NULL OR cardinality(p_langs) = 0
               OR s.lang = ANY(p_langs))
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

COMMENT ON FUNCTION public.search_cards(text, integer, text, text[], text[]) IS
    'Recherche floue par nom, cloisonnée par jeu. p_langs borne les langues '
    'interrogées ; NULL ou vide les interroge toutes, ce qui est le défaut. '
    'Ce n''est pas un levier de performance : mesuré, restreindre à deux '
    'langues fait gagner 4 %, le parcours de l''index trigramme précédant le '
    'filtre.';

DROP FUNCTION IF EXISTS public.search_cards_bulk(text[], text);

CREATE FUNCTION public.search_cards_bulk(
    p_names text[],
    p_game text DEFAULT 'magic'::text,
    p_langs text[] DEFAULT NULL::text[]
)
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
        WHERE (p_langs IS NULL OR cardinality(p_langs) = 0
               OR s.lang = ANY(p_langs))
          AND (s.normalized % nd.n
               OR s.normalized LIKE nd.n || '%')
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

COMMENT ON FUNCTION public.search_cards_bulk(text[], text, text[]) IS
    'Recherche floue en lot, une carte par nom. p_langs borne les langues '
    'interrogées ; NULL ou vide les interroge toutes, ce qui est le défaut. '
    'Ce n''est pas un levier de performance : voir search_cards.';

GRANT EXECUTE ON FUNCTION public.search_cards(text, integer, text, text[], text[])
    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.search_cards_bulk(text[], text, text[])
    TO anon, authenticated;

COMMIT;
