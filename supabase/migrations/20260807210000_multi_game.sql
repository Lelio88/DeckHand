-- 022 — Deux jeux dans une même base : Magic et Riftbound.
--
-- Motivation :
--
-- * **Une colonne, pas un schéma séparé.** Tout ce qui fait la valeur du produit
--   — collection, impressions, empreintes, complétion de decks — est identique
--   d'un jeu à l'autre : on possède des cartes, elles ont des éditions, on
--   cherche ce qu'on peut construire. Dupliquer les tables dupliquerait aussi
--   les quatorze fonctions et les écrans. La seule chose qui manque au modèle
--   est de savoir *de quel jeu* une carte relève.
--
-- * **`magic` par défaut, pour que l'existant ne bouge pas.** Les 31 634 cartes
--   déjà en base prennent la valeur par défaut sans réécriture applicative, et
--   l'application, qui n'envoie pas encore ce paramètre, continue de ne voir que
--   Magic.
--
-- * **La recherche doit filtrer dès maintenant.** C'est le seul changement qui
--   ne peut pas attendre : sans lui, ingérer Riftbound polluerait la saisie
--   Magic dès la première frappe. Les autres fonctions suivront quand
--   l'application saura choisir un jeu.
--
-- * **`DROP` puis `CREATE`, jamais `CREATE OR REPLACE`.** La signature change ;
--   un remplacement créerait une surcharge, et PostgREST répond alors HTTP 300
--   (« Multiple Choices ») sur *tous* les appels de la fonction, y compris les
--   anciens. Piège déjà rencontré sur ce projet.
--
-- Ce qui n'est délibérément pas fait ici : la contrainte de format des decks
-- reste figée aux trois formats Magic. Les formats Riftbound ne sont pas encore
-- connus, et une contrainte inventée d'avance vaut moins qu'une contrainte
-- ajoutée quand la donnée existera.

BEGIN;

ALTER TABLE public.cards
    ADD COLUMN IF NOT EXISTS game text NOT NULL DEFAULT 'magic';

ALTER TABLE public.cards
    DROP CONSTRAINT IF EXISTS cards_game_known;

ALTER TABLE public.cards
    ADD CONSTRAINT cards_game_known CHECK (game IN ('magic', 'riftbound'));

COMMENT ON COLUMN public.cards.game IS
    'Jeu dont relève la carte. Cloisonne les catalogues : une recherche ne doit '
    'jamais mêler deux jeux, leurs cartes n''étant ni jouables ensemble ni '
    'comparables en prix.';

-- La recherche filtre sur cette colonne à chaque frappe.
CREATE INDEX IF NOT EXISTS idx_cards_game ON public.cards (game);

-- `card_prints` ne porte pas la colonne : une impression appartient au jeu de
-- sa carte, et la dupliquer autoriserait les deux à diverger.

DROP FUNCTION IF EXISTS public.search_cards(text, integer);

CREATE FUNCTION public.search_cards(
    q            text,
    max_results  integer DEFAULT 20,
    p_game       text    DEFAULT 'magic'
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
    owned           integer
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
           COALESCE(m.owned, 0)
    FROM best b
    -- Le cloisonnement se fait ici plutôt que dans `matches` : la table des noms
    -- indexés ne porte pas le jeu, et l'y ajouter obligerait à la reconstruire
    -- entièrement pour un gain nul à cette échelle.
    JOIN public.cards c ON c.oracle_id = b.oracle_id AND c.game = p_game
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = b.oracle_id
    LEFT JOIN mine m ON m.oracle_id = b.oracle_id
    ORDER BY b.score DESC, length(c.name), c.name
    LIMIT GREATEST(1, LEAST(max_results, 50));
$$;

COMMENT ON FUNCTION public.search_cards(text, integer, text) IS
    'Recherche de cartes par nom, tolérante aux fautes, cloisonnée par jeu. '
    'Le jeu vaut `magic` par défaut pour que les appels antérieurs à '
    'l''ouverture multi-jeu gardent leur comportement.';

GRANT EXECUTE ON FUNCTION public.search_cards(text, integer, text) TO anon, authenticated;

COMMIT;
