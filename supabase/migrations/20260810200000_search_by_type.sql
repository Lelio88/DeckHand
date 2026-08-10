-- 029 — Restreindre la recherche à un type de carte.
--
-- Chercher « bolt » ou « marais » rend des dizaines de résultats dont l'écrasante
-- majorité n'est pas ce qu'on tient : la saisie d'une collection se fait carte en
-- main, et le type est ce que l'œil vérifie en premier après le nom. Le filtre
-- coupe la liste avant qu'elle n'oblige à lire.
--
-- **Le filtre porte sur `type_line`, en anglais et par sous-chaîne.** La ligne de
-- type d'une carte cumule ses types (« Artifact Creature — Golem ») ; chercher
-- une sous-chaîne fait donc apparaître cette carte sous « Artefact » comme sous
-- « Créature », ce qui est exact. Un tableau vide ou nul ne filtre rien.
--
-- **Les types sont ceux du jeu, et l'application les connaît** : Magic compte
-- huit types courants (créature, éphémère, rituel, artefact, enchantement,
-- terrain, planeswalker, bataille), Riftbound six (unité, sort, équipement,
-- légende, champ de bataille, rune). La fonction ne fixe aucune liste : elle
-- accepte les mots qu'on lui donne, ce qui évite d'avoir à la modifier chaque
-- fois qu'un jeu gagne un type.
--
-- Signature modifiée : la fonction est supprimée avant d'être recréée, sous
-- peine de surcharge PostgREST (migration 012). Les appels à trois arguments
-- restent valides, le nouveau paramètre ayant une valeur par défaut.

BEGIN;

DROP FUNCTION IF EXISTS public.search_cards(text, integer, text);

CREATE FUNCTION public.search_cards(
    q           text,
    max_results integer DEFAULT 20,
    p_game      text    DEFAULT 'magic',
    p_types     text[]  DEFAULT NULL
)
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
    score           real,
    owned           integer,
    art_url         text
)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'extensions'
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
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = b.oracle_id
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
$$;

COMMENT ON FUNCTION public.search_cards(text, integer, text, text[]) IS
    'Recherche interactive par nom, cloisonnée par jeu et restreignable à des '
    'types de carte (sous-chaînes de la ligne de type, en anglais).';

GRANT EXECUTE ON FUNCTION public.search_cards(text, integer, text, text[])
    TO anon, authenticated;

COMMIT;
