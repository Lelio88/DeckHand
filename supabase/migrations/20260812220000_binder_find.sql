-- 041 — Retrouver une carte dans ses classeurs.
--
-- **Le classeur suppose de savoir où chercher**, et c'est la seule chose qu'une
-- liste faisait mieux que lui : « où est ma Foudre ? » n'a pas de réponse quand
-- on n'a que l'ordre des numéros et 97 feuilles à tourner.
--
-- La fonction rend donc la **case** de chaque carte possédée dont le nom
-- correspond : son extension, son numéro, et surtout la **page** où la trouver.
-- La page est calculée dans l'ordre du rangement — le seul où la question se
-- pose, puisque c'est celui qui laisse des feuilles à parcourir.
--
-- La recherche s'appuie sur `card_search_names`, comme le reste de
-- l'application : le nom français comme l'anglais y répondent, et la
-- normalisation absorbe les accents et la casse.
--
-- **Seules les cartes possédées sont rendues.** Chercher dans un classeur, c'est
-- chercher parmi ses cartes ; proposer les 33 000 autres du catalogue ferait de
-- cette fonction une seconde recherche de cartes, qui existe déjà ailleurs.

BEGIN;

CREATE OR REPLACE FUNCTION public.my_binder_find(
    p_query    text,
    p_game     text    DEFAULT 'magic',
    p_per_page integer DEFAULT 9,
    p_limit    integer DEFAULT 20
)
RETURNS TABLE (
    oracle_id        uuid,
    name             text,
    printed_name     text,
    set_code         text,
    set_name         text,
    collector_number text,
    page             integer,
    owned            integer,
    art_crop_url     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH needle AS (
        SELECT public.normalize_card_name(COALESCE(p_query, '')) AS n
    ),
    mine AS (
        SELECT p.set_code,
               p.collector_number,
               i.oracle_id,
               SUM(i.quantity)::integer AS copies
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
          AND (SELECT n FROM needle) <> ''
          AND EXISTS (
                SELECT 1 FROM public.card_search_names s
                WHERE s.oracle_id = i.oracle_id
                  AND s.normalized LIKE '%' || (SELECT n FROM needle) || '%'
          )
        GROUP BY p.set_code, p.collector_number, i.oracle_id
    ),
    -- Le rang d'une case dans son classeur, d'où se déduit sa feuille. Calculé
    -- sur les seules extensions concernées : le faire sur tout le catalogue
    -- coûterait un balayage de 167 000 impressions pour trois résultats.
    ranked AS (
        SELECT p.set_code,
               p.collector_number,
               ROW_NUMBER() OVER (
                   PARTITION BY p.set_code
                   ORDER BY NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                            NULLS LAST,
                            p.collector_number
               ) AS position
        FROM (
            SELECT DISTINCT set_code, collector_number
            FROM public.card_prints
            WHERE set_code IN (SELECT DISTINCT m.set_code FROM mine m)
        ) p
    ),
    shown AS (
        SELECT DISTINCT ON (p.set_code, p.collector_number)
               p.set_code, p.collector_number, p.set_name, p.printed_name,
               p.art_crop_url
        FROM public.card_prints p
        JOIN mine m
          ON m.set_code = p.set_code
         AND m.collector_number = p.collector_number
        ORDER BY p.set_code, p.collector_number,
                 (p.lang = 'fr') DESC, (p.lang = 'en') DESC
    )
    SELECT m.oracle_id,
           c.name,
           s.printed_name,
           m.set_code,
           s.set_name,
           m.collector_number,
           ((r.position - 1) / GREATEST(1, LEAST(p_per_page, 60)))::integer + 1,
           m.copies,
           s.art_crop_url
    FROM mine m
    JOIN public.cards c ON c.oracle_id = m.oracle_id
    JOIN ranked r
      ON r.set_code = m.set_code AND r.collector_number = m.collector_number
    LEFT JOIN shown s
      ON s.set_code = m.set_code AND s.collector_number = m.collector_number
    ORDER BY m.set_code, r.position
    LIMIT GREATEST(1, LEAST(p_limit, 60));
$$;

COMMENT ON FUNCTION public.my_binder_find(text, text, integer, integer) IS
    'Où sont rangées les cartes possédées dont le nom correspond : leur '
    'extension, leur numéro, et la feuille où les trouver. C''est la seule '
    'chose qu''une liste faisait mieux qu''un classeur.';

GRANT EXECUTE ON FUNCTION public.my_binder_find(text, text, integer, integer)
    TO anon, authenticated;

COMMIT;
