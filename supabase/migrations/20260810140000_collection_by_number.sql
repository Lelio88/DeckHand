-- 026 — Ranger la collection par numéro de collection.
--
-- Les tris existants répondent à des questions d'inventaire : ce qui vaut le
-- plus, ce qu'on a en plusieurs exemplaires, ce qui vient d'entrer. Aucun ne
-- répond à celle qu'on se pose une carte à la main devant une boîte : où
-- va-t-elle ?
--
-- **Le tri est numérique, pas alphabétique.** `collector_number` est un `text`
-- parce que Scryfall y met aussi des suffixes (`43a`, `★43`, `T2`). Trié comme
-- du texte, 100 précède 2 et le rangement devient inutilisable. On trie donc sur
-- la partie chiffrée, en gardant le texte entier comme départage — c'est lui qui
-- sépare 43a de 43b.
--
-- **Les cartes sans édition précisée ferment la marche.** Elles n'ont pas de
-- numéro, et leur en inventer un les placerait au milieu des autres. `NULLS
-- LAST` les regroupe à la fin, ce qui les désigne aussi comme celles qui
-- restent à préciser.
--
-- Signature inchangée : `CREATE OR REPLACE` suffit, sans risque de surcharge
-- PostgREST (migration 012).

BEGIN;

CREATE OR REPLACE FUNCTION public.my_collection(
    p_query  text    DEFAULT NULL,
    p_sort   text    DEFAULT 'name',
    p_limit  integer DEFAULT 50,
    p_offset integer DEFAULT 0,
    p_game   text    DEFAULT 'magic'
)
RETURNS TABLE (
    oracle_id        uuid,
    print_id         uuid,
    is_foil          boolean,
    name             text,
    printed_name     text,
    type_line        text,
    set_code         text,
    set_name         text,
    collector_number text,
    quantity         integer,
    unit_price_eur   numeric,
    line_price_eur   numeric,
    legal_pauper     boolean,
    legal_modern     boolean,
    legal_commander  boolean,
    added_at         timestamptz
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
    WITH needle AS (
        SELECT public.normalize_card_name(COALESCE(p_query, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    priced AS (
        SELECT m.*,
               -- Édition précisée : son prix dans la finition possédée. Sinon le
               -- moins cher connu — l'exemplaire n'étant pas identifié, mieux
               -- vaut sous-estimer que d'inventer.
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur
               ) AS unit_price,
               pr.set_code,
               pr.set_name,
               pr.collector_number,
               -- Partie chiffrée du numéro, seule comparable d'une carte à
               -- l'autre. Vide (`★`, `T`) ou absente : la ligne passe en fin de
               -- liste plutôt qu'en tête, où un zéro implicite l'aurait mise.
               NULLIF(regexp_replace(COALESCE(pr.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank,
               COALESCE(pr.printed_name, fr.name) AS shown_name
        FROM mine m
        LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
        LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id
        LEFT JOIN LATERAL (
            SELECT s.name
            FROM public.card_search_names s
            WHERE s.oracle_id = m.oracle_id AND s.lang = 'fr'
            LIMIT 1
        ) fr ON true
    )
    SELECT p.oracle_id,
           p.print_id,
           p.is_foil,
           c.name,
           p.shown_name,
           c.type_line,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.quantity,
           p.unit_price,
           p.unit_price * p.quantity,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           p.added_at
    FROM priced p
    JOIN public.cards c ON c.oracle_id = p.oracle_id AND c.game = p_game
    WHERE (SELECT n FROM needle) = ''
       OR EXISTS (
            SELECT 1 FROM public.card_search_names s
            WHERE s.oracle_id = p.oracle_id
              AND s.normalized LIKE '%' || (SELECT n FROM needle) || '%'
       )
    ORDER BY
        CASE WHEN p_sort = 'price'    THEN p.unit_price * p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' THEN p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   THEN p.added_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'number'   THEN p.number_rank END ASC NULLS LAST,
        -- Le texte entier départage deux mêmes chiffres : 43a avant 43b.
        CASE WHEN p_sort = 'number'   THEN p.collector_number END ASC NULLS LAST,
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST,
        p.is_foil
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection(text, text, integer, integer, text) IS
    'Page de collection, cherchable et triable par nom, valeur, quantité, date '
    'd''entrée ou numéro de collection.';

COMMIT;
