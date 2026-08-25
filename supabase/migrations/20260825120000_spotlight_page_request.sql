-- 20260825120000 — une désignation peut porter une page, et plus seulement une carte.
--
-- Motivation : `!page msh 3` répond dans le chat « 4/9 — manquent #20, #21,
-- #23 ». C'est exact et illisible : personne ne se représente trois numéros. La
-- même page **montrée** dit la même chose d'un coup d'œil, avec le fantôme de
-- chaque carte manquante à sa place. Le calque sait déjà dessiner cette page —
-- c'est celle qu'il pose au bout du feuilletage de `!montre`.
--
-- Ce qui change, et c'est tout : la ligne de désignation gagne un **genre**.
-- `card` fait sortir une carte de sa case ; `page` s'arrête une fois la page
-- posée. Une seule ligne par collection, comme avant — l'écran n'a qu'une
-- place, et une demande de page remplace une demande de carte comme une
-- demande de carte remplace une demande de page.
--
-- **La portée reste sur la lecture.** Rien n'est ajouté ici de ce côté : une
-- page d'extension retirée du partage disparaît du calque par le même filtre
-- que les cartes, et pour la même raison — le partage est révocable a
-- posteriori.
--
-- Refs : #21

BEGIN;

-- ---------------------------------------------------------------------------
-- La table — un genre, et une page
-- ---------------------------------------------------------------------------

ALTER TABLE public.collection_spotlight
    ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'card',
    ADD COLUMN IF NOT EXISTS page integer;

-- **Le numéro de case cesse d'être obligatoire.** Une demande de page n'en a
-- pas, et lui en inventer un — zéro, chaîne vide — ferait une case qui n'existe
-- pas plutôt qu'une absence.
ALTER TABLE public.collection_spotlight
    ALTER COLUMN collector_number DROP NOT NULL;

-- Le genre décide de ce qui doit être renseigné. Sans cette contrainte, une
-- ligne `page` sans numéro de page passerait, et le calque afficherait un
-- classeur ouvert sur rien.
ALTER TABLE public.collection_spotlight
    DROP CONSTRAINT IF EXISTS collection_spotlight_kind_payload;
ALTER TABLE public.collection_spotlight
    ADD CONSTRAINT collection_spotlight_kind_payload CHECK (
        (kind = 'card' AND collector_number IS NOT NULL)
     OR (kind = 'page' AND page IS NOT NULL AND page >= 1)
    );

COMMENT ON COLUMN public.collection_spotlight.kind IS
    'card : une carte sort de sa case. page : le classeur s''ouvre sur une page '
    'et s''y arrête.';
COMMENT ON COLUMN public.collection_spotlight.page IS
    'Numéro de page demandé, pour kind = page. NULL pour une carte, dont la '
    'page est calculée à la lecture.';

-- ---------------------------------------------------------------------------
-- L'écriture — la seconde, et la dernière, ouverte à anon
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.public_request_spotlight_page(
    p_handle       text,
    p_set_code     text,
    p_page         integer,
    p_requested_by text DEFAULT NULL,
    p_game         text DEFAULT 'magic'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_collection uuid;
    v_last       timestamptz;
BEGIN
    -- Verrou 1 — collection publiée. Rend false sinon, comme pour les cartes :
    -- l'anti-énumération vaut ici aussi, une adresse inconnue et une collection
    -- non publiée donnent la même réponse.
    v_collection := public.collection_by_handle(p_handle);
    IF v_collection IS NULL THEN
        RETURN false;
    END IF;

    IF p_page IS NULL OR p_page < 1 THEN
        RETURN false;
    END IF;

    -- Verrou 2 — l'extension est dans le classeur. Le jumeau exact du verrou de
    -- `public_request_spotlight` : là-bas « cette case est possédée », ici
    -- « cette extension l'est ». La lecture ne rend rien, elle répond oui ou
    -- non ; la portée, elle, s'applique côté lecture.
    IF NOT EXISTS (
        SELECT 1
        FROM public.collection_items i
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards c ON c.oracle_id = i.oracle_id AND c.game = p_game
        WHERE i.collection_id = v_collection
          AND p.set_code      = p_set_code
    ) THEN
        RETURN false;
    END IF;

    -- Verrou 3 — le délai de garde, **partagé avec les cartes**. C'est la même
    -- ligne et le même écran : deux commandes différentes ne donnent pas droit
    -- à deux fois plus de temps d'antenne.
    SELECT s.requested_at INTO v_last
    FROM public.collection_spotlight s
    WHERE s.collection_id = v_collection;

    IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '30 seconds' THEN
        RETURN false;
    END IF;

    INSERT INTO public.collection_spotlight (
        collection_id, request_id, kind, set_code, collector_number, page,
        requested_by, requested_at
    )
    VALUES (
        v_collection,
        nextval('public.collection_spotlight_request_seq'),
        'page',
        p_set_code,
        NULL,
        p_page,
        NULLIF(left(COALESCE(p_requested_by, ''), 40), ''),
        NOW()
    )
    ON CONFLICT (collection_id) DO UPDATE SET
        request_id       = EXCLUDED.request_id,
        kind             = EXCLUDED.kind,
        set_code         = EXCLUDED.set_code,
        collector_number = EXCLUDED.collector_number,
        page             = EXCLUDED.page,
        requested_by     = EXCLUDED.requested_by,
        requested_at     = EXCLUDED.requested_at;

    RETURN true;
END;
$$;

COMMENT ON FUNCTION public.public_request_spotlight_page IS
    'Fait monter une page du classeur sur l''overlay. Refuse (false) une '
    'collection non publiée, une extension absente du classeur, ou une demande '
    'arrivée moins de 30 s après la précédente — délai partagé avec les cartes.';

GRANT EXECUTE ON FUNCTION
    public.public_request_spotlight_page(text, text, integer, text, text)
    TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- La lecture — un genre de plus, et le reste inchangé
-- ---------------------------------------------------------------------------

-- Le type de retour change : il faut détruire avant de recréer. **Et un DROP
-- emporte les GRANT** — sans la reprise explicite plus bas, la fonction
-- existerait en refusant `anon`, ce qui se lit comme un calque muet.
DROP FUNCTION IF EXISTS public.public_spotlight(text, text, integer);

CREATE FUNCTION public.public_spotlight(
    p_handle   text,
    p_game     text DEFAULT 'magic',
    p_per_page integer DEFAULT 9
)
RETURNS TABLE (
    request_id       bigint,
    requested_at     timestamptz,
    requested_by     text,
    kind             text,
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
        -- nouveauté.
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
          ON a.kind = 'card'
         AND a.set_code = p.set_code
         AND a.collector_number = p.collector_number
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
    -- Les cases de l'extension demandée, classées comme le classeur les classe.
    -- **Depuis `asked` et non depuis `chosen`** : une demande de page n'a pas
    -- de carte, et partir de la carte laisserait la page sans compte de pages.
    cells AS (
        SELECT DISTINCT
               p.collector_number,
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT a.set_code FROM asked a)
    ),
    ranked AS (
        SELECT cl.collector_number,
               row_number() OVER (
                   ORDER BY cl.number_rank NULLS LAST, cl.collector_number
               )::integer AS position,
               COUNT(*) OVER ()::integer AS total
        FROM cells cl
    ),
    -- Le nombre de pages de l'extension, qu'on ait demandé une carte ou une
    -- page. Une seule ligne : `ranked` porte le même total partout.
    compte AS (
        SELECT MAX(r.total) AS total FROM ranked r
    )
    SELECT a.request_id,
           a.requested_at,
           a.requested_by,
           a.kind,
           c.name,
           COALESCE(NULLIF(ch.printed_name, ''), c.name),
           a.set_code,
           (SELECT MIN(s.set_name) FROM public.card_prints s WHERE s.set_code = a.set_code),
           ch.collector_number,
           ch.art_crop_url,
           public.print_price(ch.scryfall_id, COALESCE(h.foil, false)),
           COALESCE(h.copies, 0),
           -- Une carte : la page où elle vit. Une page : celle qu'on a demandée.
           COALESCE(((r.position - 1) / b.per)::integer + 1, a.page),
           ((r.position - 1) % b.per)::integer + 1,
           ((cp.total + b.per - 1) / b.per)::integer
    FROM asked a
    -- **En LEFT JOIN, et c'est ce qui laisse passer une page.** En jointure
    -- interne, une demande sans carte disparaissait purement et simplement.
    LEFT JOIN chosen ch ON ch.set_code = a.set_code
                       AND ch.collector_number = a.collector_number
    LEFT JOIN public.cards c ON c.oracle_id = ch.oracle_id AND c.game = p_game
    LEFT JOIN ranked r ON r.collector_number = ch.collector_number
    CROSS JOIN scope sc
    CROSS JOIN bornes b
    LEFT JOIN compte cp ON TRUE
    LEFT JOIN held h ON TRUE
    -- **Le filtre de portée, et il n'existe qu'ici.** Une extension retirée du
    -- partage après la demande la fait disparaître du calque, ce qui est
    -- exactement ce qu'on veut : le partage est révocable, y compris a
    -- posteriori. Il porte sur `asked` plutôt que sur la carte, pour valoir
    -- aussi quand il n'y a pas de carte.
    WHERE (sc.shared_sets IS NULL OR a.set_code = ANY(sc.shared_sets))
      -- Une demande de carte dont l'impression a disparu du catalogue ne rend
      -- rien, comme avant. Sans cette garde, le LEFT JOIN la ferait remonter
      -- avec des colonnes vides et le calque ouvrirait un classeur sur rien.
      AND (a.kind = 'page' OR ch.collector_number IS NOT NULL);
$$;

COMMENT ON FUNCTION public.public_spotlight IS
    'Ce qu''un spectateur a fait monter sur l''overlay d''une collection '
    'publiée : une carte avec sa page et sa case, ou une page seule (kind). '
    'Applique shared_sets — une extension retirée du partage disparaît du '
    'calque même si la demande est antérieure au retrait.';

GRANT EXECUTE ON FUNCTION
    public.public_spotlight(text, text, integer)
    TO anon, authenticated;

COMMIT;
