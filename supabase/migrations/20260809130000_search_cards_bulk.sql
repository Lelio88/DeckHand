-- Recherche de plusieurs noms en un seul aller-retour.
--
-- Motivation : le scan d'étalement cherchait un nom par appel HTTP. Mesuré sur
-- une photo de dix-sept cartes — 112 lignes candidates — cela donnait 112
-- requêtes et **77 secondes**. Les lancer par vagues de 25 ne changeait rien :
-- chaque vague prenait 15 secondes, soit exactement 25 × 600 ms. Le serveur les
-- traite l'une après l'autre ; le parallélisme côté client n'achète rien, et le
-- total est mécaniquement « nombre de lignes × 600 ms ».
--
-- Pire, 18 requêtes sur 112 mouraient en route (connexion fermée par l'hôte)
-- depuis un poste filaire. Depuis un téléphone tenant 25 connexions TLS
-- ouvertes pendant quinze secondes, elles y passaient toutes : l'écran ne
-- montrait aucune carte.
--
-- Cette fonction prend le tableau de noms d'un coup. Un aller-retour, une
-- exécution, un plan de requête — les 600 ms de latence ne sont plus payées
-- qu'une fois au lieu de 112.
--
-- Elle ne remplace pas `search_cards` : celle-ci sert la recherche interactive,
-- où l'utilisateur veut *plusieurs* propositions pour un nom. Ici c'est
-- l'inverse — un seul résultat, mais pour beaucoup de noms.

BEGIN;

-- Plafond du tableau accepté. Au-delà, la requête est refusée plutôt que
-- tronquée en silence : une troncature muette ferait disparaître des cartes de
-- l'étalement sans que rien ne le signale.
CREATE OR REPLACE FUNCTION public.search_cards_bulk(
    p_names text[],
    p_game  text DEFAULT 'magic'
)
RETURNS TABLE(
    query           text,
    oracle_id       uuid,
    name            text,
    matched_name    text,
    matched_lang    text,
    type_line       text,
    mana_cost       text,
    price_eur       numeric,
    legal_pauper    boolean,
    legal_modern    boolean,
    legal_commander boolean,
    score           real,
    owned           integer,
    art_url         text
)
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
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = b.oracle_id
    LEFT JOIN mine m ON m.oracle_id = b.oracle_id;
$function$;

COMMENT ON FUNCTION public.search_cards_bulk(text[], text) IS
    'Meilleure correspondance pour chaque nom d''un lot, en un aller-retour. '
    'Destinée au scan d''étalement ; la recherche interactive utilise search_cards.';

GRANT EXECUTE ON FUNCTION public.search_cards_bulk(text[], text) TO anon, authenticated;

COMMIT;
