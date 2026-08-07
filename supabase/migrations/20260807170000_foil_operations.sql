-- 020 — La finition traverse toutes les opérations de collection.
--
-- Suite de la migration 019, qui a posé les colonnes. Ici les fonctions les
-- prennent en compte : ajouter, retirer, déplacer et lire une collection
-- distinguent désormais le brillant du normal, et valorisent chacun à son prix.
--
-- `card_printings` gagne par ailleurs un **filtre de langue**. Le sélecteur
-- montrait chaque édition deux fois, en français et en anglais, alors que la
-- langue est déjà connue : on a cherché la carte par son nom français, donc on
-- tient la version française. Afficher les deux doublait la liste sans rien
-- apprendre.
--
-- Toutes ces fonctions changent de signature : elles sont supprimées avant
-- d'être recréées, sous peine de surcharge PostgREST (HTTP 300, migration 012).

BEGIN;

DROP FUNCTION IF EXISTS public.add_to_collection(uuid, integer, uuid);
DROP FUNCTION IF EXISTS public.remove_from_collection(uuid, integer, uuid);
DROP FUNCTION IF EXISTS public.set_collection_print(uuid, uuid, uuid, integer);
DROP FUNCTION IF EXISTS public.card_printings(uuid, text, integer);
DROP FUNCTION IF EXISTS public.my_collection(text, text, integer, integer);
DROP FUNCTION IF EXISTS public.my_collection_summary();

-- ---------------------------------------------------------------------------
-- Éditions : filtrées par langue, avec leurs finitions
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.card_printings(
    p_oracle_id uuid,
    p_query     text    DEFAULT NULL,
    p_limit     integer DEFAULT 60,
    p_lang      text    DEFAULT NULL
)
RETURNS TABLE (
    print_id         uuid,
    set_code         text,
    set_name         text,
    collector_number text,
    rarity           text,
    lang             text,
    printed_name     text,
    price_eur        numeric,
    price_eur_foil   numeric,
    has_nonfoil      boolean,
    has_foil         boolean,
    released_at      date,
    owned            integer,
    art_crop_url     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH needle AS (
        SELECT lower(trim(COALESCE(p_query, ''))) AS n
    ),
    mine AS (
        SELECT i.print_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid() AND i.print_id IS NOT NULL
        GROUP BY i.print_id
    )
    SELECT p.scryfall_id,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.rarity,
           p.lang,
           p.printed_name,
           public.print_price(p.scryfall_id, false),
           public.print_price(p.scryfall_id, true),
           -- Une impression de bundle n'existe qu'en brillant : proposer
           -- « normal » n'aurait alors aucun sens.
           COALESCE('nonfoil' = ANY(p.finishes), true),
           COALESCE('foil' = ANY(p.finishes) OR 'etched' = ANY(p.finishes), false),
           p.released_at,
           COALESCE(m.owned, 0),
           p.art_crop_url
    FROM public.card_prints p
    LEFT JOIN mine m ON m.print_id = p.scryfall_id
    WHERE p.oracle_id = p_oracle_id
      AND (p_lang IS NULL OR p.lang = p_lang)
      AND ((SELECT n FROM needle) = ''
           OR lower(COALESCE(p.set_name, '')) LIKE '%' || (SELECT n FROM needle) || '%'
           OR lower(p.set_code) LIKE (SELECT n FROM needle) || '%')
    ORDER BY COALESCE(m.owned, 0) DESC,
             p.released_at DESC NULLS LAST,
             p.set_code,
             p.collector_number
    LIMIT GREATEST(1, LEAST(p_limit, 200));
$$;

COMMENT ON FUNCTION public.card_printings IS
    'Éditions d''une carte, filtrables par langue et cherchables par extension. '
    'Porte les deux cotes et les finitions réellement imprimées.';

-- ---------------------------------------------------------------------------
-- Ajout et retrait
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.add_to_collection(
    p_oracle_id uuid,
    p_quantity  integer DEFAULT 1,
    p_print_id  uuid    DEFAULT NULL,
    p_is_foil   boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_collection uuid;
    v_quantity   integer;
BEGIN
    IF p_quantity < 1 THEN
        RAISE EXCEPTION 'quantité invalide : %', p_quantity;
    END IF;

    -- Une édition doit appartenir à la carte annoncée : sans ce contrôle, une
    -- requête malformée rattacherait un exemplaire à l'édition d'une autre carte.
    IF p_print_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.card_prints
        WHERE scryfall_id = p_print_id AND oracle_id = p_oracle_id
    ) THEN
        RAISE EXCEPTION 'édition % étrangère à la carte %', p_print_id, p_oracle_id;
    END IF;

    v_collection := public.ensure_my_collection();

    INSERT INTO public.collection_items (collection_id, oracle_id, print_id, is_foil, quantity)
    VALUES (v_collection, p_oracle_id, p_print_id, COALESCE(p_is_foil, false), p_quantity)
    ON CONFLICT (collection_id, oracle_id, print_id, is_foil) DO UPDATE
        SET quantity = public.collection_items.quantity + EXCLUDED.quantity
    RETURNING quantity INTO v_quantity;

    RETURN v_quantity;
END;
$$;

CREATE FUNCTION public.remove_from_collection(
    p_oracle_id uuid,
    p_quantity  integer DEFAULT 1,
    p_print_id  uuid    DEFAULT NULL,
    p_is_foil   boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_collection uuid;
    v_current    integer;
    v_foil       boolean := COALESCE(p_is_foil, false);
BEGIN
    IF p_quantity < 1 THEN
        RAISE EXCEPTION 'quantité invalide : %', p_quantity;
    END IF;

    v_collection := public.ensure_my_collection();

    -- Lire puis décider : `CHECK (quantity > 0)` rejetterait une décrémentation
    -- sous zéro avant que la suppression puisse avoir lieu (migration 006).
    SELECT quantity INTO v_current
    FROM public.collection_items
    WHERE collection_id = v_collection
      AND oracle_id = p_oracle_id
      AND print_id IS NOT DISTINCT FROM p_print_id
      AND is_foil = v_foil
    FOR UPDATE;

    IF v_current IS NULL THEN
        RETURN 0;
    END IF;

    IF v_current <= p_quantity THEN
        DELETE FROM public.collection_items
        WHERE collection_id = v_collection
          AND oracle_id = p_oracle_id
          AND print_id IS NOT DISTINCT FROM p_print_id
          AND is_foil = v_foil;
        RETURN 0;
    END IF;

    UPDATE public.collection_items
    SET quantity = quantity - p_quantity
    WHERE collection_id = v_collection
      AND oracle_id = p_oracle_id
      AND print_id IS NOT DISTINCT FROM p_print_id
      AND is_foil = v_foil
    RETURNING quantity INTO v_current;

    RETURN v_current;
END;
$$;

-- ---------------------------------------------------------------------------
-- Préciser l'édition et la finition d'exemplaires déjà saisis
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_collection_print(
    p_oracle_id     uuid,
    p_from_print_id uuid,
    p_to_print_id   uuid,
    p_quantity      integer DEFAULT NULL,
    p_from_foil     boolean DEFAULT false,
    p_to_foil       boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_collection uuid;
    v_available  integer;
    v_move       integer;
    v_result     integer;
    v_from_foil  boolean := COALESCE(p_from_foil, false);
    v_to_foil    boolean := COALESCE(p_to_foil, false);
BEGIN
    IF p_to_print_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.card_prints
        WHERE scryfall_id = p_to_print_id AND oracle_id = p_oracle_id
    ) THEN
        RAISE EXCEPTION 'édition % étrangère à la carte %', p_to_print_id, p_oracle_id;
    END IF;

    v_collection := public.ensure_my_collection();

    SELECT quantity INTO v_available
    FROM public.collection_items
    WHERE collection_id = v_collection
      AND oracle_id = p_oracle_id
      AND print_id IS NOT DISTINCT FROM p_from_print_id
      AND is_foil = v_from_foil
    FOR UPDATE;

    IF v_available IS NULL THEN
        RETURN 0;
    END IF;

    -- Quantité omise : on déplace tout. C'est le geste courant — « ces
    -- quatre-là sont de cette édition ».
    v_move := LEAST(COALESCE(p_quantity, v_available), v_available);
    IF v_move < 1 THEN
        RETURN 0;
    END IF;

    IF p_from_print_id IS NOT DISTINCT FROM p_to_print_id AND v_from_foil = v_to_foil THEN
        RETURN v_available;
    END IF;

    IF v_move = v_available THEN
        DELETE FROM public.collection_items
        WHERE collection_id = v_collection
          AND oracle_id = p_oracle_id
          AND print_id IS NOT DISTINCT FROM p_from_print_id
          AND is_foil = v_from_foil;
    ELSE
        UPDATE public.collection_items
        SET quantity = quantity - v_move
        WHERE collection_id = v_collection
          AND oracle_id = p_oracle_id
          AND print_id IS NOT DISTINCT FROM p_from_print_id
          AND is_foil = v_from_foil;
    END IF;

    INSERT INTO public.collection_items (collection_id, oracle_id, print_id, is_foil, quantity)
    VALUES (v_collection, p_oracle_id, p_to_print_id, v_to_foil, v_move)
    ON CONFLICT (collection_id, oracle_id, print_id, is_foil) DO UPDATE
        SET quantity = public.collection_items.quantity + EXCLUDED.quantity
    RETURNING quantity INTO v_result;

    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Lecture : une ligne par (carte, édition, finition)
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.my_collection(
    p_query  text    DEFAULT NULL,
    p_sort   text    DEFAULT 'name',
    p_limit  integer DEFAULT 50,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    oracle_id        uuid,
    print_id         uuid,
    is_foil          boolean,
    name             text,
    printed_name     text,
    type_line        text,
    set_code         text,
    set_name         text,
    collector_number text,
    quantity         integer,
    unit_price_eur   numeric,
    line_price_eur   numeric,
    legal_pauper     boolean,
    legal_modern     boolean,
    legal_commander  boolean,
    added_at         timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH needle AS (
        SELECT public.normalize_card_name(COALESCE(p_query, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    priced AS (
        SELECT m.*,
               -- Édition précisée : son prix dans la finition possédée. Sinon le
               -- moins cher connu — l'exemplaire n'étant pas identifié, mieux
               -- vaut sous-estimer que d'inventer.
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur
               ) AS unit_price,
               pr.set_code,
               pr.set_name,
               pr.collector_number,
               COALESCE(pr.printed_name, fr.name) AS shown_name
        FROM mine m
        LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
        LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id
        LEFT JOIN LATERAL (
            SELECT s.name
            FROM public.card_search_names s
            WHERE s.oracle_id = m.oracle_id AND s.lang = 'fr'
            LIMIT 1
        ) fr ON true
    )
    SELECT p.oracle_id,
           p.print_id,
           p.is_foil,
           c.name,
           p.shown_name,
           c.type_line,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.quantity,
           p.unit_price,
           p.unit_price * p.quantity,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           p.added_at
    FROM priced p
    JOIN public.cards c ON c.oracle_id = p.oracle_id
    WHERE (SELECT n FROM needle) = ''
       OR EXISTS (
            SELECT 1 FROM public.card_search_names s
            WHERE s.oracle_id = p.oracle_id
              AND s.normalized LIKE '%' || (SELECT n FROM needle) || '%'
       )
    ORDER BY
        CASE WHEN p_sort = 'price'    THEN p.unit_price * p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' THEN p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   THEN p.added_at END DESC NULLS LAST,
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST,
        p.is_foil
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

CREATE FUNCTION public.my_collection_summary()
RETURNS TABLE (
    total_cards        integer,
    distinct_cards     integer,
    total_value_eur    numeric,
    unspecified_prints integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH mine AS (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    )
    SELECT COALESCE(SUM(m.quantity), 0)::integer,
           COUNT(DISTINCT m.oracle_id)::integer,
           COALESCE(SUM(m.quantity * COALESCE(
               public.print_price(m.print_id, m.is_foil),
               cheap.price_eur,
               0
           )), 0),
           COALESCE(SUM(m.quantity) FILTER (WHERE m.print_id IS NULL), 0)::integer
    FROM mine m
    LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id;
$$;

GRANT EXECUTE ON FUNCTION public.card_printings(uuid, text, integer, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.add_to_collection(uuid, integer, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_from_collection(uuid, integer, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_collection_print(uuid, uuid, uuid, integer, boolean, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection_summary() TO authenticated;

COMMIT;
