-- `public_spotlight` rend la page et la case — le calque va dessiner le classeur.
--
-- **Pourquoi la base et pas le client.** L'overlay doit ouvrir le classeur à la
-- bonne page et faire sortir la carte de la bonne case. Recalculer ces deux
-- nombres côté Dart demanderait d'y porter le classement des cases — l'ordre par
-- numéro, le repli sur le texte quand le numéro n'est pas un nombre, le choix de
-- l'impression représentative — c'est-à-dire un jumeau de plus sur exactement le
-- genre de règle qui dérive en silence. Un calque qui ouvre la page 46 quand le
-- classeur en montre 45 n'affiche aucune erreur : il montre une page fausse.
--
-- **L'arithmétique est copiée de `binder_locate`, à l'identique.** Même CTE
-- `cells` (DISTINCT sur le couple extension/numéro), même `ORDER BY number_rank
-- NULLS LAST, collector_number`, même division. C'est ce qui garantit que la
-- page annoncée par `!card` — « page 3 case 4 » — est celle que le calque
-- dessine et celle que l'écran de classeur affiche.
--
-- **Le nombre de pages est rendu aussi** (`pages`), pour le défilé : le calque
-- feuillette depuis la première page jusqu'à la bonne, et sans ce total il ne
-- saurait pas si la page 46 est au milieu du classeur ou à sa fin.
--
-- **Un DROP emporte les GRANT.** Le type de retour change, donc la fonction doit
-- être reconstruite ; sans reprise explicite des droits elle existerait en
-- refusant `anon`, ce qui se lit comme un calque qui ne montre jamais rien.

BEGIN;

DROP FUNCTION IF EXISTS public.public_spotlight(text, text);

CREATE FUNCTION public.public_spotlight(
    p_handle   text,
    p_game     text DEFAULT 'magic',
    p_per_page integer DEFAULT 9
)
RETURNS TABLE (
    request_id       bigint,
    requested_at     timestamptz,
    requested_by     text,
    name             text,
    printed_name     text,
    set_code         text,
    set_name         text,
    collector_number text,
    art_crop_url     text,
    price_eur        numeric,
    copies           integer,
    page             integer,
    slot             integer,
    pages            integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
    WITH bornes AS (
        SELECT GREATEST(1, LEAST(p_per_page, 60)) AS per
    ),
    scope AS (
        SELECT c.id, c.shared_sets
        FROM public.collections c
        WHERE c.id = public.collection_by_handle(p_handle)
    ),
    asked AS (
        SELECT s.*
        FROM public.collection_spotlight s
        JOIN scope sc ON sc.id = s.collection_id
        -- **Une demande périmée ne remonte pas.** Sans cette borne, un overlay
        -- rouvert le lendemain afficherait la carte de la veille comme une
        -- nouveauté. Le calque a sa propre logique de première réponse, mais
        -- elle protège le lancement, pas une reprise en cours de direct.
        WHERE s.requested_at > NOW() - INTERVAL '10 minutes'
    ),
    -- Même impression représentative que `public_binder_page` : français, puis
    -- anglais, puis identifiant. Divergentes, le calque et la page montreraient
    -- deux illustrations pour la même case.
    chosen AS (
        SELECT DISTINCT ON (p.set_code, p.collector_number)
               p.set_code, p.collector_number, p.scryfall_id, p.oracle_id,
               p.printed_name, p.art_crop_url
        FROM public.card_prints p
        JOIN asked a
          ON a.set_code = p.set_code AND a.collector_number = p.collector_number
        ORDER BY p.set_code, p.collector_number,
                 (p.lang = 'fr') DESC, (p.lang = 'en') DESC, p.scryfall_id
    ),
    held AS (
        SELECT SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN scope sc ON sc.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN chosen ch ON ch.set_code = p.set_code
                      AND ch.collector_number = p.collector_number
    ),
    -- Les cases de l'extension, classées comme le classeur les classe.
    cells AS (
        SELECT DISTINCT
               p.collector_number,
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT ch.set_code FROM chosen ch)
    ),
    ranked AS (
        SELECT cl.collector_number,
               row_number() OVER (
                   ORDER BY cl.number_rank NULLS LAST, cl.collector_number
               )::integer AS position,
               COUNT(*) OVER ()::integer AS total
        FROM cells cl
    )
    SELECT a.request_id,
           a.requested_at,
           a.requested_by,
           c.name,
           COALESCE(NULLIF(ch.printed_name, ''), c.name),
           ch.set_code,
           (SELECT MIN(s.set_name) FROM public.card_prints s WHERE s.set_code = ch.set_code),
           ch.collector_number,
           ch.art_crop_url,
           public.print_price(ch.scryfall_id, COALESCE(h.foil, false)),
           COALESCE(h.copies, 0),
           ((r.position - 1) / b.per)::integer + 1,
           ((r.position - 1) % b.per)::integer + 1,
           ((r.total + b.per - 1) / b.per)::integer
    FROM asked a
    JOIN chosen ch ON ch.set_code = a.set_code
                  AND ch.collector_number = a.collector_number
    JOIN public.cards c ON c.oracle_id = ch.oracle_id AND c.game = p_game
    JOIN ranked r ON r.collector_number = ch.collector_number
    CROSS JOIN scope sc
    CROSS JOIN bornes b
    LEFT JOIN held h ON TRUE
    -- **Le filtre de portée, et il n'existe qu'ici.** Une extension retirée du
    -- partage après la demande fait disparaître la carte du calque, ce qui est
    -- exactement ce qu'on veut : le partage est révocable, y compris a
    -- posteriori.
    WHERE sc.shared_sets IS NULL
       OR ch.set_code = ANY(sc.shared_sets);
$$;

COMMENT ON FUNCTION public.public_spotlight IS
    'La carte désignée sur l''overlay d''une collection publiée, avec sa page et '
    'sa case — mêmes nombres que binder_locate. Applique shared_sets : une '
    'extension retirée du partage disparaît du calque même si la demande est '
    'antérieure au retrait.';

GRANT EXECUTE ON FUNCTION
    public.public_spotlight(text, text, integer)
    TO anon, authenticated;

COMMIT;
