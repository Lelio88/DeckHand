-- Les extensions de jetons sortent aussi du COMPTE d'extensions entamees.
--
-- Motivation : la migration 20260824120000 les ecartait deja du « meilleur
-- classeur », et le disait — elles sont petites (27 cartes pour tmsh contre 453
-- pour msh), se completent donc mecaniquement plus vite, et aucune de leurs
-- cartes n'est legale en construit. Le COMPTE, lui, les gardait. Une meme
-- sortie produit jusqu'a quatre extensions — boosters, decks Commander, jetons
-- de chacune — si bien qu'un joueur qui a ouvert deux boites s'entendait dire
-- qu'il etait « etale sur six extensions ». Le nombre etait exact et la
-- reponse fausse : personne ne collectionne un jeu de jetons.
--
-- La coherence compte autant que le chiffre. Les deux indicateurs voisinent
-- dans la meme tuile et defilent l'un apres l'autre ; ecarter les jetons de
-- l'un et pas de l'autre donnait deux assiettes differentes a un lecteur qui
-- n'a aucun moyen de le deviner. L'ecran le DIT desormais — « entamees, hors
-- jetons » — parce qu'un total qui exclut quelque chose sans le dire se lit
-- comme un bug.
--
-- Le critere est celui de l'etagere et du meilleur classeur : `card_sets.
-- set_type = 'token'`. Une extension inconnue de `card_sets` est comptee — le
-- COALESCE la laisse passer — parce qu'ignorer une extension au motif qu'on ne
-- sait rien d'elle ferait disparaitre des cartes reellement possedees.
--
-- Le reste de la fonction est repris a l'identique : une migration jouee ne se
-- modifie pas (CLAUDE.md §IV.12), donc on la recree entiere.
--
-- ATTENTION — un DROP emporte les GRANT. La reprise explicite en fin de fichier
-- n'est pas decorative : sans elle la fonction existerait en refusant
-- `authenticated`, et la page de profil afficherait « Collection illisible ».
--
-- Refs: page de profil, indicateurs defilants

BEGIN;

DROP FUNCTION IF EXISTS public.my_collection_summary(text);

CREATE FUNCTION public.my_collection_summary(p_game text DEFAULT 'magic')
RETURNS TABLE(
    total_cards integer,
    distinct_cards integer,
    total_value_eur numeric,
    unspecified_prints integer,
    unique_value_eur numeric,
    top_card_name text,
    top_card_eur numeric,
    distinct_sets integer,
    best_set_name text,
    best_set_owned integer,
    best_set_total integer
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
    WITH mine AS MATERIALIZED (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    cotee AS MATERIALIZED (
        SELECT m.oracle_id,
               m.print_id,
               m.quantity,
               pr.set_code,
               pr.collector_number,
               -- Le type d'extension descend jusqu'ici pour que le COMPTE et le
               -- MEILLEUR classeur partagent exactement le meme critere.
               COALESCE(cs.set_type, '') = 'token' AS est_jeton,
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur,
                   0
               ) AS unite,
               -- La même clé de référence que `distinct_cards`, pour que « une
               -- de chaque » compte exactement les lignes que ce nombre annonce.
               m.oracle_id::text || ':' ||
               COALESCE(
                   pr.set_code || '#' || COALESCE(pr.collector_number, ''),
                   ''
               ) AS reference
        FROM mine m
        LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
        LEFT JOIN public.card_sets cs ON cs.code = pr.set_code
        LEFT JOIN public.card_cheapest_price cheap
               ON cheap.oracle_id = m.oracle_id
    ),
    totaux AS (
        SELECT COALESCE(SUM(quantity), 0)::integer AS total_cards,
               COUNT(DISTINCT reference)::integer AS distinct_cards,
               COALESCE(SUM(quantity * unite), 0) AS total_value,
               COALESCE(SUM(quantity) FILTER (WHERE print_id IS NULL), 0)::integer
                   AS unspecified,
               -- Les cartes sans édition précisée n'appartiennent a aucune
               -- extension : `set_code` y est NULL, et COUNT l'ignore — ce qui
               -- est exactement le comportement voulu.
               (COUNT(DISTINCT set_code)
                    FILTER (WHERE NOT est_jeton))::integer AS distinct_sets
        FROM cotee
    ),
    -- Une référence peut exister en plusieurs lignes — ordinaire et brillante.
    -- « Une de chaque » retient la plus chère : c'est celle qu'on garderait.
    une_de_chaque AS (
        SELECT COALESCE(SUM(unite), 0) AS valeur
        FROM (SELECT reference, MAX(unite) AS unite FROM cotee GROUP BY reference) r
    ),
    -- Trier d'abord, nommer ensuite : joindre `cards` avant le tri joindrait
    -- toute la collection pour n'en garder qu'une ligne.
    plus_chere AS (
        SELECT oracle_id, unite FROM cotee ORDER BY unite DESC LIMIT 1
    ),
    -- Cases occupees par extension. Une case est le couple (extension, numero),
    -- comme au classeur : deux langues d'une meme carte n'en font qu'une.
    par_set AS (
        SELECT set_code, COUNT(DISTINCT collector_number)::integer AS occupees
        FROM cotee
        WHERE set_code IS NOT NULL
          AND NOT est_jeton
        GROUP BY set_code
    ),
    tailles AS (
        SELECT p.set_code,
               MIN(p.set_name) AS set_name,
               COUNT(DISTINCT p.collector_number)::integer AS total
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT set_code FROM par_set)
        GROUP BY p.set_code
    ),
    meilleur AS (
        SELECT t.set_name, s.occupees, t.total
        FROM par_set s
        JOIN tailles t ON t.set_code = s.set_code
        WHERE t.total > 0
        -- Le taux d'abord ; a taux egal, la plus grosse extension, qui est le
        -- plus bel accomplissement des deux.
        ORDER BY s.occupees::numeric / t.total DESC, t.total DESC
        LIMIT 1
    )
    SELECT t.total_cards,
           t.distinct_cards,
           t.total_value,
           t.unspecified,
           u.valeur,
           (SELECT ca.name FROM public.cards ca
             WHERE ca.oracle_id = (SELECT oracle_id FROM plus_chere)),
           COALESCE((SELECT unite FROM plus_chere), 0),
           t.distinct_sets,
           (SELECT set_name FROM meilleur),
           COALESCE((SELECT occupees FROM meilleur), 0),
           COALESCE((SELECT total FROM meilleur), 0)
    FROM totaux t, une_de_chaque u;
$$;

COMMENT ON FUNCTION public.my_collection_summary(text) IS
    'Agregats de la collection entiere, en une passe. Les extensions de jetons '
    'sont ecartees du compte d''extensions comme du meilleur classeur : personne '
    'ne collectionne un jeu de jetons. Les CTE sont MATERIALIZED a dessein : '
    'inlinees, elles recalculaient les prix une fois par lecture et la fonction '
    'depassait le statement_timeout du role authenticated.';

GRANT EXECUTE ON FUNCTION public.my_collection_summary(text) TO authenticated;

COMMIT;
