-- Un nom ne désigne pas une carte : les jetons le prouvent.
--
-- **Mesuré : 6 noms possédés sur 220 restaient sans réponse** — `Merfolk`,
-- `Alien`, `Hero`, `Soldier`, `Wall`, `Leviathan`. Tous des jetons, et tous
-- portés par **plusieurs cartes distinctes** : trois « Merfolk » au catalogue,
-- de statistiques différentes, donc trois `oracle_id`. `binder_locate` élisait
-- la meilleure correspondance et s'arrêtait là ; l'exemplaire possédé était
-- souvent l'un des autres, et la fonction répondait « je ne l'ai pas » sur une
-- carte rangée dans le classeur.
--
-- Le départage de `search_cards_bulk` — le nom le plus court, puis l'ordre
-- alphabétique — sert une recherche où l'on veut *une* proposition. Ici la
-- question n'est pas « quelle carte ? » mais « où est la mienne ? » : toutes
-- les cartes du meilleur score sont retenues, et la possession tranche. Pour
-- une carte ordinaire il n'y en a qu'une, et rien ne change.
--
-- Ce que cela ne fait pas : élargir la recherche. Seul le **meilleur** score
-- est gardé — une carte moins bien nommée n'entre pas parce qu'on la possède.

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
    scored AS (
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
    ),
    -- Toutes les cartes du meilleur score, et elles seules. Une carte porte
    -- deux lignes ici quand le catalogue la nomme en deux langues : on n'en
    -- garde qu'une, sans quoi chaque case serait annoncée deux fois.
    best AS (
        SELECT DISTINCT ON (sc.oracle_id) sc.oracle_id, sc.name, sc.matched_name, sc.score
        FROM scored sc
        WHERE sc.score = (SELECT MAX(sc2.score) FROM scored sc2)
          AND sc.score > 0
        ORDER BY sc.oracle_id, sc.score DESC, length(sc.matched_name), sc.matched_name
    ),
    mine AS (
        SELECT b.name,
               b.matched_name,
               b.score,
               p.set_code,
               p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN best b               ON b.oracle_id  = i.oracle_id
        WHERE i.collection_id = public.collection_by_handle(p_handle)
        GROUP BY b.name, b.matched_name, b.score, p.set_code, p.collector_number
    ),
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
    SELECT m.name,
           m.matched_name,
           m.score,
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
    CROSS JOIN needle nd
    ORDER BY m.copies DESC, r.set_code, r.position;
$$;

COMMIT;
