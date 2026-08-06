-- 002 — Recherche de cartes exposée au client.
--
-- Motivation : l'opérateur de similarité trigram (`%`) et la fonction
-- `similarity()` ne sont pas exposables via l'API REST auto-générée. Sans cette
-- fonction, un client ne pourrait faire que de l'égalité stricte sur le nom
-- normalisé — donc échouer sur la moindre faute de frappe ou sur un accent.
--
-- `search_cards` est en SECURITY INVOKER : elle s'exécute avec les droits de
-- l'appelant et reste donc soumise aux policies de lecture du catalogue.

BEGIN;

CREATE EXTENSION IF NOT EXISTS unaccent;

-- Doit produire exactement le même résultat que `normalize_name` côté Python
-- (app/ingestion/scryfall_parse.py) : les deux alimentent la même colonne.
-- Toute divergence rendrait une partie de l'index inatteignable.
CREATE OR REPLACE FUNCTION public.normalize_card_name(input text)
RETURNS text
LANGUAGE sql
STABLE
STRICT
SET search_path = public, extensions
AS $$
    SELECT btrim(regexp_replace(
        lower(unaccent(regexp_replace(input, '[’ʼ‘´`]', '''', 'g'))),
        '\s+', ' ', 'g'))
$$;

COMMENT ON FUNCTION public.normalize_card_name IS
    'Forme comparable d''un nom de carte : minuscules, sans accent, apostrophes unifiées. '
    'Doit rester alignée sur normalize_name() en Python.';

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
               -- Un préfixe exact prime sur une simple proximité : taper « sol »
               -- doit remonter « Sol Ring » avant les noms vaguement ressemblants.
               GREATEST(
                   similarity(s.normalized, (SELECT n FROM needle)),
                   CASE WHEN s.normalized LIKE (SELECT n FROM needle) || '%'
                        THEN 0.95 ELSE 0 END
               ) AS score
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
    ORDER BY b.score DESC, c.name
    LIMIT GREATEST(1, LEAST(max_results, 50));
$$;

COMMENT ON FUNCTION public.search_cards IS
    'Recherche de cartes tolérante aux fautes et bilingue FR/EN, destinée au champ '
    'de saisie de collection. Renvoie une ligne par carte, jamais par nom.';

GRANT EXECUTE ON FUNCTION public.normalize_card_name(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.search_cards(text, integer) TO anon, authenticated;

COMMIT;
