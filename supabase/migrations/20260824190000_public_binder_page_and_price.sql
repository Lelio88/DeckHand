-- « Qu'est-ce qu'il y a sur cette page ? » et « elle vaut combien ? » (#21)
--
-- Deux ajouts au service du bot de chat, et rien d'autre.
--
-- **1. `public_binder_page`** — le calque de `my_binder_page` pour une adresse
-- de partage. Celle-ci filtre sur `auth.uid()` et ne rend donc rien sous la clé
-- anonyme, comme `my_binder_shelf` avant elle : ce n'est pas le droit
-- d'exécution qui décide, c'est la signature.
--
-- **Ce que le chat en fait tenir dans une ligne.** Pas les neuf noms — une page
-- de classeur ne se récite pas. Le bot compte les cases pleines et **nomme les
-- vides par leur numéro**, ce qui tient parce qu'une page en compte neuf au
-- plus. C'est la question « qu'est-ce qui te manque » ramenée à une échelle où
-- elle a une réponse : sur l'extension entière, il manquait deux cent
-- dix-neuf cases, et aucune troncature n'en faisait une phrase utile.
--
-- **Une extension non partagée ne rend rien**, plutôt qu'une page de neuf cases
-- vides : le catalogue est public, mais « le propriétaire n'a rien ici » ne l'est
-- pas. La garde est `EXISTS (SELECT 1 FROM mine)` — si aucune ligne de collection
-- n'est lisible dans cette extension, la fonction se tait. La RLS fait le reste.
--
-- **2. `binder_locate` rend le prix.** Aujourd'hui elle situe la carte sans la
-- coter, et en direct « tu l'as déjà ? » est presque toujours suivi de « elle
-- vaut combien ? ». Deux réponses en un appel valent mieux qu'un second aller-
-- retour sur **chaque** réponse réussie.
--
-- Le prix se prend par `print_price`, avec la finition réellement possédée —
-- même règle que le classeur : Scryfall ne cote pratiquement que l'anglais, et
-- `print_price` porte déjà le repli sur la version anglaise de la même case.
--
-- **Un DROP est nécessaire, et il coûte les droits.** Postgres refuse de
-- remplacer une fonction dont le type de retour change. La reconstruire perd
-- ses `GRANT` — d'où leur reprise explicite plus bas. Sans elle, la fonction
-- existerait et `anon` serait refusé : le bot se tairait sur tout, ce qui se lit
-- comme un classeur vide.
--
-- `binder_locate` n'est appelée par aucun écran de l'application : le bot est
-- son seul client, et ce changement de signature ne casse donc rien d'autre.

BEGIN;

-- ---------------------------------------------------------------------------
-- La page d'un classeur partagé
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.public_binder_page(
    p_handle   text,
    p_set_code text,
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 9,
    p_game     text    DEFAULT 'magic'
)
RETURNS TABLE (
    collector_number text,
    name             text,
    printed_name     text,
    owned            integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH bornes AS (
        SELECT GREATEST(1, LEAST(p_per_page, 60)) AS per,
               GREATEST(1, p_page)                AS num
    ),
    -- Ce que le propriétaire possède ici, dans la limite de ce qu'il partage :
    -- la RLS sur `collection_items` applique `shared_sets`, cette requête ne la
    -- répète pas.
    mine AS (
        SELECT p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE i.collection_id = public.collection_by_handle(p_handle)
          AND p.set_code = p_set_code
        GROUP BY p.collector_number
    ),
    -- Les cases de l'extension, même choix d'impression représentative et même
    -- ordre que `my_binder_page` : s'ils divergeaient, la page nommée ici ne
    -- serait pas celle qu'on voit à l'écran.
    cells AS (
        SELECT DISTINCT ON (p.collector_number)
               p.collector_number,
               p.oracle_id,
               p.printed_name,
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code = p_set_code
        ORDER BY p.collector_number,
                 (p.lang = 'fr') DESC,
                 (p.lang = 'en') DESC,
                 p.scryfall_id
    ),
    ranked AS (
        SELECT cl.*,
               row_number() OVER (
                   ORDER BY cl.number_rank NULLS LAST, cl.collector_number
               )::integer AS position
        FROM cells cl
    )
    SELECT r.collector_number,
           c.name,
           COALESCE(NULLIF(r.printed_name, ''), c.name),
           COALESCE(m.copies, 0)
    FROM ranked r
    JOIN public.cards c ON c.oracle_id = r.oracle_id
    LEFT JOIN mine m ON m.collector_number = r.collector_number
    CROSS JOIN bornes b
    WHERE EXISTS (SELECT 1 FROM mine)
      AND r.position > (b.num - 1) * b.per
      AND r.position <= b.num * b.per
    ORDER BY r.position;
$$;

COMMENT ON FUNCTION public.public_binder_page IS
    'Une page d''un classeur partagé, par son adresse publique. Les cases vides '
    'y figurent — c''est ce qui manque. Rien pour une collection non publiée, ni '
    'pour une extension retirée du partage : une adresse essayée au hasard ne '
    'doit pas révéler ce qu''elle cache.';

GRANT EXECUTE ON FUNCTION
    public.public_binder_page(text, text, integer, integer, text)
    TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- `binder_locate` rend désormais le prix de la case
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.binder_locate(text, text, text, integer);

CREATE FUNCTION public.binder_locate(
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
    has_foil         boolean,
    price_eur        numeric
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
               bool_or(i.is_foil)       AS foil,
               -- **Le prix de la case, à la finition de chaque exemplaire.**
               -- `print_price` porte déjà le repli sur la version anglaise de la
               -- même case : Scryfall ne cote pratiquement que l'anglais, et la
               -- plupart des impressions françaises n'ont pas de cote propre.
               --
               -- La finition se lit sur **la ligne**, pas sur l'agrégat : SQL
               -- refuse un agrégat dans un agrégat, et `MAX` sur les
               -- exemplaires possédés donne la meilleure des finitions
               -- détenues — ce que la case vaut au mieux.
               MAX(public.print_price(p.scryfall_id, i.is_foil)) AS price_eur
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
           m.foil,
           m.price_eur
    FROM mine m
    JOIN ranked r
      ON r.set_code = m.set_code AND r.collector_number = m.collector_number
    CROSS JOIN needle nd
    ORDER BY m.copies DESC, r.set_code, r.position;
$$;

COMMENT ON FUNCTION public.binder_locate IS
    'Où se range cette carte dans un classeur partagé, et ce qu''elle vaut. '
    'Rien pour une collection non publiée, une extension retirée du partage, ou '
    'une carte absente : les trois se disent pareil.';

-- **Reprise obligatoire.** Un DROP emporte les droits ; sans ces lignes la
-- fonction existerait et `anon` serait refusé — le bot se tairait sur tout.
GRANT EXECUTE ON FUNCTION
    public.binder_locate(text, text, text, integer)
    TO anon, authenticated;

COMMIT;
