-- 004 — Privilégier les correspondances sur un mot entier.
--
-- Problème corrigé : à score de préfixe égal, seul le rapport de longueur
-- départageait les résultats. Taper « sol » remontait donc « Soliton » (7
-- caractères) avant « Sol Ring » (8), alors que l'intention est manifestement le
-- second — « sol » y est un mot complet, pas un fragment.
--
-- Le barème distingue désormais trois qualités de préfixe :
--   1.00          égalité stricte
--   0.85 → 0.98   la saisie couvre un mot entier du nom (« sol » dans « sol ring »)
--   0.70 → 0.84   simple fragment initial (« sol » dans « soliton »)
--   < 0.70        proximité trigram, pour absorber les fautes de frappe

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
