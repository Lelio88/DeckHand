-- « Cette carte, je l'ai ? Et où ? » — en une question.
--
-- **La réponse cesse d'être un oui/non pour devenir une localisation.** C'est le
-- classeur-par-édition qui la permet : une case étant `(set_code,
-- collector_number)`, la page et l'emplacement se **calculent** et ne se
-- stockent nulle part. Le rang d'une case parmi celles de son extension,
-- divisé par neuf, donne la feuille ; le reste donne la pochette.
--
-- **L'ordre reproduit celui de `my_binder_page` rangé par numéro**, à la
-- virgule près (`number_rank NULLS LAST, collector_number`). S'ils divergeaient,
-- la fonction nommerait une page où la carte n'est pas — un mensonge pire que
-- l'absence de réponse.
--
-- **Elle ne voit rien de plus que la page publique.** Deux raisons, et aucune
-- n'est le corps de cette fonction : `collection_by_handle` ne rend que des
-- collections publiées, et la lecture de `collection_items` reste soumise à
-- `collection_item_is_readable`, qui applique la portée extension par
-- extension. La fonction est donc `SECURITY INVOKER` — délibérément. En
-- `DEFINER` elle deviendrait un chemin d'accès parallèle, et le partage
-- restreint ne vaudrait plus rien pour qui connaît son nom.
--
-- **Une adresse inconnue et une carte absente rendent la même chose : rien.**
-- Un bot de chat répond « je ne l'ai pas » dans les deux cas, ce qui est la
-- bonne réponse : distinguer confirmerait l'existence d'une collection fermée à
-- qui essaie des noms au hasard.

BEGIN;

CREATE OR REPLACE FUNCTION public.binder_locate(
    p_handle   text,
    p_query    text,
    p_game     text DEFAULT 'magic',
    p_per_page integer DEFAULT 9
)
RETURNS TABLE(
    name             text,
    matched_name     text,
    score            real,
    set_code         text,
    set_name         text,
    collector_number text,
    page             integer,
    slot             integer,
    copies           integer,
    has_foil         boolean
)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'extensions'
AS $$
    WITH needle AS (
        SELECT public.normalize_card_name(p_query) AS n,
               GREATEST(1, LEAST(p_per_page, 60))  AS per
    ),
    -- Même départage que `search_cards_bulk` : un nom tapé dans un chat est mal
    -- orthographié une fois sur deux, et à score égal le nom le plus court
    -- gagne — sans quoi deux fois la même commande rendraient deux cartes.
    best AS (
        SELECT c.oracle_id,
               c.name,
               s.name AS matched_name,
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
        FROM needle nd
        JOIN public.card_search_names s
          ON s.normalized % nd.n OR s.normalized LIKE nd.n || '%'
        JOIN public.cards c
          ON c.oracle_id = s.oracle_id AND c.game = p_game
        WHERE nd.n <> ''
        ORDER BY score DESC, length(c.name), c.name
        LIMIT 1
    ),
    -- La collection lue est celle de l'adresse, et seulement si elle est
    -- publiée. Une adresse qui ne mène nulle part donne `NULL`, donc aucune
    -- ligne : le silence, pas une erreur.
    mine AS (
        SELECT p.set_code,
               p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN best b               ON b.oracle_id  = i.oracle_id
        WHERE i.collection_id = public.collection_by_handle(p_handle)
        GROUP BY p.set_code, p.collector_number
    ),
    -- Une case n'est pas une impression : l'anglais et le français partagent le
    -- #412. On compte donc les numéros distincts, pas les lignes du catalogue.
    cells AS (
        SELECT DISTINCT
               p.set_code,
               p.collector_number,
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT DISTINCT m.set_code FROM mine m)
    ),
    ranked AS (
        SELECT cl.set_code,
               cl.collector_number,
               row_number() OVER (
                   PARTITION BY cl.set_code
                   ORDER BY cl.number_rank NULLS LAST, cl.collector_number
               )::integer AS position
        FROM cells cl
    )
    SELECT b.name,
           b.matched_name,
           b.score,
           r.set_code,
           (SELECT MIN(s.set_name) FROM public.card_prints s WHERE s.set_code = r.set_code),
           r.collector_number,
           ((r.position - 1) / nd.per)::integer + 1,
           ((r.position - 1) % nd.per)::integer + 1,
           m.copies,
           m.foil
    FROM mine m
    JOIN ranked r
      ON r.set_code = m.set_code AND r.collector_number = m.collector_number
    CROSS JOIN best b
    CROSS JOIN needle nd
    -- Le classeur où l'on en a le plus d'abord : c'est celui qu'on ira ouvrir.
    ORDER BY m.copies DESC, r.set_code, r.position;
$$;

COMMENT ON FUNCTION public.binder_locate(text, text, text, integer) IS
    'Où se range une carte dans les classeurs donnés à lire sous cette adresse : '
    'extension, page et pochette, calculées et non stockées. Ne voit rien de '
    'plus que la page publique — SECURITY INVOKER, la portée du partage '
    's''applique.';

GRANT EXECUTE ON FUNCTION public.binder_locate(text, text, text, integer) TO anon, authenticated;

COMMIT;
