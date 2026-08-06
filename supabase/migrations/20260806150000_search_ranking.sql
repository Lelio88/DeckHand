-- 003 — Classement des résultats de recherche.
--
-- Problème corrigé : la version précédente attribuait un score constant à toute
-- correspondance par préfixe. Les résultats se retrouvaient donc triés par ordre
-- alphabétique, ce qui remontait « Soldat ardent » avant « Sol Ring » pour la
-- saisie « sol », et « Foudre du jugement » avant « Foudre » pour « foudr ».
--
-- Nouveau barème, du plus fort au plus faible :
--   1.00          nom exactement égal à la saisie
--   0.70 → 0.95   préfixe, d'autant mieux classé que le nom est court — donc
--                 proche de ce qui a été tapé
--   < 0.70        simple proximité trigram (tolérance aux fautes de frappe)
--
-- Le ratio de longueur est ce qui fait remonter la carte dont le nom « colle »
-- à la saisie plutôt que celle qui ne fait que commencer pareil.

BEGIN;

CREATE OR REPLACE FUNCTION public.search_cards(q text, max_results integer DEFAULT 20)
RETURNS TABLE (
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
    score           real
)
LANGUAGE sql
STABLE
SET search_path = public, extensions
AS $$
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
                       WHEN s.normalized LIKE (SELECT n FROM needle) || '%'
                           THEN 0.70 + 0.25 * (
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
    -- Une carte peut correspondre par son nom anglais ET son nom français ;
    -- on ne la propose qu'une fois, via sa meilleure correspondance.
    best AS (
        SELECT DISTINCT ON (m.oracle_id) m.*
        FROM matches m
        ORDER BY m.oracle_id, m.score DESC
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
           b.score
    FROM best b
    JOIN public.cards c ON c.oracle_id = b.oracle_id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = b.oracle_id
    ORDER BY b.score DESC, length(c.name), c.name
    LIMIT GREATEST(1, LEAST(max_results, 50));
$$;

COMMIT;
