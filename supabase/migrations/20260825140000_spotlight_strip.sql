-- 20260825140000 — une désignation peut porter un tapis : toutes les versions d'une carte.
--
-- Motivation : `!card trésor` répond « 3 cases (+5 autres) ». Les cinq autres,
-- personne ne saura jamais à quoi elles ressemblent — et c'est précisément ce
-- qu'on voudrait voir, puisque la question qu'on se pose devant une carte qu'on
-- possède en plusieurs exemplaires est « lesquelles ai-je ». Un **tapis de
-- présentation** en bas d'écran les montre côte à côte : moins de place qu'une
-- page de classeur, et rien qui prétende être une page.
--
-- **Une par illustration, pas une par impression.** Un Trésor imprimé dans cinq
-- extensions avec le même dessin s'afficherait cinq fois ; `illustration_id`,
-- que Scryfall publie et que le catalogue porte, dit lesquelles sont vraiment
-- différentes. Quand il manque — les autres jeux ne le publient pas tous —, on
-- retombe sur la case, ce qui ne dédoublonne rien mais n'invente rien non plus.
--
-- **Le verrou qui rend la commande gratuite dans le cas courant.** `!card` est
-- la commande banale : tapée sans y penser, gratuite, en lecture seule. Si
-- chaque appel prenait l'écran, le calque ne se reposerait jamais et `!montre`
-- n'aurait plus de raison d'être. Le tapis ne monte donc **que si la carte a au
-- moins deux illustrations possédées** — c'est-à-dire exactement quand il
-- apprend quelque chose que le chat ne peut pas dire. Mesuré sur la collection
-- réelle : 18 noms sur 265, soit 6,8 %.
--
-- **La règle vit ici et non dans le bot**, parce qu'elle se lit dans les
-- données : compter les illustrations demanderait au bot une seconde lecture,
-- et deux endroits pour décider d'une même chose finissent par diverger.
--
-- Refs : #21

BEGIN;

-- ---------------------------------------------------------------------------
-- Le genre s'élargit
-- ---------------------------------------------------------------------------

ALTER TABLE public.collection_spotlight
    DROP CONSTRAINT IF EXISTS collection_spotlight_kind_payload;
ALTER TABLE public.collection_spotlight
    ADD CONSTRAINT collection_spotlight_kind_payload CHECK (
        (kind = 'card'  AND collector_number IS NOT NULL)
     OR (kind = 'page'  AND page IS NOT NULL AND page >= 1)
        -- Un tapis désigne **une impression représentative** de la carte ; la
        -- lecture en déduit toutes les versions possédées. Pas de colonne de
        -- plus : la case suffit à retrouver l'oracle.
     OR (kind = 'strip' AND collector_number IS NOT NULL)
    );

COMMENT ON COLUMN public.collection_spotlight.kind IS
    'card : une carte sort de sa case. page : le classeur s''ouvre sur une page '
    'et s''y arrête. strip : un tapis montre toutes les versions possédées.';

-- ---------------------------------------------------------------------------
-- L'écriture — la troisième et dernière ouverte à anon
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.public_request_spotlight_strip(
    p_handle           text,
    p_set_code         text,
    p_collector_number text,
    p_requested_by     text DEFAULT NULL,
    p_game             text DEFAULT 'magic'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_collection uuid;
    v_oracle     uuid;
    v_variantes  integer;
    v_last       timestamptz;
BEGIN
    v_collection := public.collection_by_handle(p_handle);
    IF v_collection IS NULL THEN
        RETURN false;
    END IF;

    -- L'oracle de la case désignée. Absent : la case n'existe pas.
    SELECT p.oracle_id INTO v_oracle
    FROM public.card_prints p
    JOIN public.cards c ON c.oracle_id = p.oracle_id AND c.game = p_game
    WHERE p.set_code = p_set_code AND p.collector_number = p_collector_number
    LIMIT 1;

    IF v_oracle IS NULL THEN
        RETURN false;
    END IF;

    -- **Le verrou qui compte** : combien d'illustrations différentes de cette
    -- carte la collection tient-elle ? En dessous de deux, le tapis
    -- n'apprendrait rien que `!card` ne dise déjà, et prendrait l'écran pour
    -- rien.
    SELECT COUNT(DISTINCT COALESCE(
               p.illustration_id::text,
               p.set_code || '/' || p.collector_number
           ))
    INTO v_variantes
    FROM public.collection_items i
    JOIN public.card_prints p ON p.scryfall_id = i.print_id
    WHERE i.collection_id = v_collection
      AND i.oracle_id     = v_oracle;

    IF COALESCE(v_variantes, 0) < 2 THEN
        RETURN false;
    END IF;

    -- Le délai de garde, partagé avec les cartes et les pages : même écran.
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
        'strip',
        p_set_code,
        p_collector_number,
        NULL,
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

COMMENT ON FUNCTION public.public_request_spotlight_strip IS
    'Fait monter le tapis des versions possédées d''une carte. Refuse (false) '
    'une collection non publiée, une case inconnue, une carte dont la '
    'collection ne tient qu''une illustration, ou une demande arrivée moins de '
    '30 s après la précédente.';

GRANT EXECUTE ON FUNCTION
    public.public_request_spotlight_strip(text, text, text, text, text)
    TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- La lecture — une ligne pour une carte ou une page, N pour un tapis
-- ---------------------------------------------------------------------------

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
    cells AS (
        SELECT DISTINCT
               p.collector_number,
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT a.set_code FROM asked a WHERE a.kind <> 'strip')
    ),
    ranked AS (
        SELECT cl.collector_number,
               row_number() OVER (
                   ORDER BY cl.number_rank NULLS LAST, cl.collector_number
               )::integer AS position,
               COUNT(*) OVER ()::integer AS total
        FROM cells cl
    ),
    compte AS (
        SELECT MAX(r.total) AS total FROM ranked r
    ),
    -- ----------------------------------------------------------------------
    -- Le tapis : l'oracle visé, puis ses versions possédées, une par dessin.
    -- ----------------------------------------------------------------------
    cible AS (
        SELECT DISTINCT p.oracle_id
        FROM public.card_prints p
        JOIN asked a
          ON a.kind = 'strip'
         AND a.set_code = p.set_code
         AND a.collector_number = p.collector_number
    ),
    tenues AS (
        SELECT p.set_code,
               p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN scope sc ON sc.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN cible ci ON ci.oracle_id = i.oracle_id
        GROUP BY p.set_code, p.collector_number
    ),
    representatives AS (
        SELECT DISTINCT ON (p.set_code, p.collector_number)
               p.set_code, p.collector_number, p.scryfall_id, p.oracle_id,
               p.printed_name, p.art_crop_url, p.illustration_id
        FROM public.card_prints p
        JOIN tenues t ON t.set_code = p.set_code
                     AND t.collector_number = p.collector_number
        ORDER BY p.set_code, p.collector_number,
                 (p.lang = 'fr') DESC, (p.lang = 'en') DESC, p.scryfall_id
    ),
    -- **Une entrée par dessin.** Deux extensions au même dessin ne font qu'une
    -- carte à montrer ; `illustration_id` est ce qui le dit, et sa clé de repli
    -- — la case — ne dédoublonne rien mais n'invente rien.
    variantes AS (
        SELECT DISTINCT ON (
                   COALESCE(r.illustration_id::text,
                            r.set_code || '/' || r.collector_number))
               r.set_code, r.collector_number, r.scryfall_id, r.oracle_id,
               r.printed_name, r.art_crop_url
        FROM representatives r
        ORDER BY COALESCE(r.illustration_id::text,
                          r.set_code || '/' || r.collector_number),
                 r.set_code, r.collector_number
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
           COALESCE(((r.position - 1) / b.per)::integer + 1, a.page),
           ((r.position - 1) % b.per)::integer + 1,
           ((cp.total + b.per - 1) / b.per)::integer
    FROM asked a
    LEFT JOIN chosen ch ON ch.set_code = a.set_code
                       AND ch.collector_number = a.collector_number
    LEFT JOIN public.cards c ON c.oracle_id = ch.oracle_id AND c.game = p_game
    LEFT JOIN ranked r ON r.collector_number = ch.collector_number
    CROSS JOIN scope sc
    CROSS JOIN bornes b
    LEFT JOIN compte cp ON TRUE
    LEFT JOIN held h ON TRUE
    WHERE a.kind IN ('card', 'page')
      AND (sc.shared_sets IS NULL OR a.set_code = ANY(sc.shared_sets))
      AND (a.kind = 'page' OR ch.collector_number IS NOT NULL)

    UNION ALL

    -- **Une ligne par version, toutes portant le même `request_id`.** Le calque
    -- les regroupe ; la base, elle, n'a pas à savoir combien il en affichera.
    SELECT a.request_id,
           a.requested_at,
           a.requested_by,
           a.kind,
           c.name,
           COALESCE(NULLIF(v.printed_name, ''), c.name),
           v.set_code,
           (SELECT MIN(s.set_name) FROM public.card_prints s WHERE s.set_code = v.set_code),
           v.collector_number,
           v.art_crop_url,
           public.print_price(v.scryfall_id, COALESCE(t.foil, false)),
           COALESCE(t.copies, 0),
           NULL::integer,
           NULL::integer,
           NULL::integer
    FROM asked a
    JOIN variantes v ON TRUE
    JOIN public.cards c ON c.oracle_id = v.oracle_id AND c.game = p_game
    LEFT JOIN tenues t ON t.set_code = v.set_code
                      AND t.collector_number = v.collector_number
    CROSS JOIN scope sc
    WHERE a.kind = 'strip'
      -- **La portée s'applique version par version.** Une carte possédée dans
      -- quatre extensions dont deux sont partagées n'en montre que deux : le
      -- partage est révocable, et il l'est case par case.
      AND (sc.shared_sets IS NULL OR v.set_code = ANY(sc.shared_sets))

    ORDER BY 7, 9;
$$;

COMMENT ON FUNCTION public.public_spotlight IS
    'Ce qu''un spectateur a fait monter sur l''overlay d''une collection '
    'publiée : une carte avec sa page et sa case, une page seule, ou le tapis '
    'des versions possédées d''une carte (une ligne par version). Applique '
    'shared_sets — une extension retirée du partage disparaît du calque, y '
    'compris version par version.';

GRANT EXECUTE ON FUNCTION
    public.public_spotlight(text, text, integer)
    TO anon, authenticated;

COMMIT;
