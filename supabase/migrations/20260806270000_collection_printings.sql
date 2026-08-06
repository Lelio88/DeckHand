-- 015 — Choisir l'édition d'une carte, et la préciser après coup.
--
-- `collection_items.print_id` existait depuis le schéma initial, avec la contrainte
-- `UNIQUE NULLS NOT DISTINCT (collection_id, oracle_id, print_id)` : la place était
-- réservée, mais rien ne la remplissait — toutes les opérations forçaient `NULL`.
--
-- Deux raisons de s'en servir maintenant. La valorisation d'abord : une carte vaut le
-- prix de **son** édition, pas celui de la réimpression la moins chère du marché ; un
-- Lightning Bolt de 1993 et sa réédition à 0,30 € ne sont pas le même objet. Le
-- classement ensuite : une collection physique se range par édition.
--
-- **Ce que change ce fichier dans la lecture de la collection.** `my_collection`
-- groupait par carte ; elle groupe désormais par (carte, édition). Posséder la même
-- carte en deux éditions produit donc deux lignes — c'est l'objectif, pas un effet de
-- bord. Le décompte de références distinctes, lui, continue de compter les cartes :
-- deux éditions de Foudre restent une seule carte connue.
--
-- **L'édition non précisée reste un état de plein droit.** On saisit vite, on précise
-- plus tard : forcer le choix à l'ajout rendrait la saisie de deux mille cartes
-- pénible. `print_id IS NULL` signifie « je possède cette carte, je n'ai pas dit
-- laquelle », et se valorise alors au prix le moins cher connu.
--
-- Toutes les fonctions touchées changent de signature : elles sont supprimées avant
-- d'être recréées. Un CREATE OR REPLACE créerait une surcharge et PostgREST
-- répondrait HTTP 300 sur tous les appels — défaut rencontré à la migration 012.

BEGIN;

DROP FUNCTION IF EXISTS public.add_to_collection(uuid, integer);
DROP FUNCTION IF EXISTS public.remove_from_collection(uuid, integer);
DROP FUNCTION IF EXISTS public.my_collection(text, text, integer, integer);
DROP FUNCTION IF EXISTS public.my_collection_summary();

-- ---------------------------------------------------------------------------
-- Éditions disponibles pour une carte
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.card_printings(
    p_oracle_id uuid,
    p_query     text    DEFAULT NULL,
    p_limit     integer DEFAULT 60
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
    released_at      date,
    owned            integer
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
           p.price_eur,
           p.released_at,
           COALESCE(m.owned, 0)
    FROM public.card_prints p
    LEFT JOIN mine m ON m.print_id = p.scryfall_id
    WHERE p.oracle_id = p_oracle_id
      -- La recherche porte sur le nom d'édition et son code : c'est ce qui est
      -- imprimé sur la carte, et donc ce que l'utilisateur a sous les yeux.
      AND ((SELECT n FROM needle) = ''
           OR lower(COALESCE(p.set_name, '')) LIKE '%' || (SELECT n FROM needle) || '%'
           OR lower(p.set_code) LIKE (SELECT n FROM needle) || '%')
    -- Les éditions déjà possédées remontent en tête : sur une carte à mille
    -- impressions, retrouver celle qu'on a déjà choisie ne doit pas demander de
    -- fouiller. Les plus récentes ensuite — ce sont les plus probables.
    ORDER BY COALESCE(m.owned, 0) DESC,
             p.released_at DESC NULLS LAST,
             p.set_code,
             p.collector_number
    LIMIT GREATEST(1, LEAST(p_limit, 200));
$$;

COMMENT ON FUNCTION public.card_printings IS
    'Éditions d''une carte, cherchables par nom ou code d''extension. Les éditions '
    'déjà possédées passent devant : certaines cartes ont plus de mille impressions.';

-- ---------------------------------------------------------------------------
-- Ajout et retrait, édition comprise
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.add_to_collection(
    p_oracle_id uuid,
    p_quantity  integer DEFAULT 1,
    p_print_id  uuid    DEFAULT NULL
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

    -- Une édition doit appartenir à la carte annoncée. Sans ce contrôle, une
    -- requête malformée rattacherait un exemplaire de Foudre à l'édition d'une
    -- autre carte, et la collection vaudrait n'importe quoi.
    IF p_print_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.card_prints
        WHERE scryfall_id = p_print_id AND oracle_id = p_oracle_id
    ) THEN
        RAISE EXCEPTION 'édition % étrangère à la carte %', p_print_id, p_oracle_id;
    END IF;

    v_collection := public.ensure_my_collection();

    INSERT INTO public.collection_items (collection_id, oracle_id, print_id, quantity)
    VALUES (v_collection, p_oracle_id, p_print_id, p_quantity)
    ON CONFLICT (collection_id, oracle_id, print_id) DO UPDATE
        SET quantity = public.collection_items.quantity + EXCLUDED.quantity
    RETURNING quantity INTO v_quantity;

    RETURN v_quantity;
END;
$$;

CREATE FUNCTION public.remove_from_collection(
    p_oracle_id uuid,
    p_quantity  integer DEFAULT 1,
    p_print_id  uuid    DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_collection uuid;
    v_current    integer;
BEGIN
    IF p_quantity < 1 THEN
        RAISE EXCEPTION 'quantité invalide : %', p_quantity;
    END IF;

    v_collection := public.ensure_my_collection();

    -- Lire puis décider : `CHECK (quantity > 0)` rejetterait une décrémentation
    -- sous zéro avant que la suppression puisse avoir lieu (migration 006).
    -- `FOR UPDATE` empêche deux retraits simultanés de lire la même quantité.
    SELECT quantity INTO v_current
    FROM public.collection_items
    WHERE collection_id = v_collection
      AND oracle_id = p_oracle_id
      AND print_id IS NOT DISTINCT FROM p_print_id
    FOR UPDATE;

    IF v_current IS NULL THEN
        RETURN 0;
    END IF;

    IF v_current <= p_quantity THEN
        DELETE FROM public.collection_items
        WHERE collection_id = v_collection
          AND oracle_id = p_oracle_id
          AND print_id IS NOT DISTINCT FROM p_print_id;
        RETURN 0;
    END IF;

    UPDATE public.collection_items
    SET quantity = quantity - p_quantity
    WHERE collection_id = v_collection
      AND oracle_id = p_oracle_id
      AND print_id IS NOT DISTINCT FROM p_print_id
    RETURNING quantity INTO v_current;

    RETURN v_current;
END;
$$;

-- ---------------------------------------------------------------------------
-- Préciser l'édition d'exemplaires déjà saisis
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_collection_print(
    p_oracle_id     uuid,
    p_from_print_id uuid,
    p_to_print_id   uuid,
    p_quantity      integer DEFAULT NULL
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
    FOR UPDATE;

    IF v_available IS NULL THEN
        RETURN 0;
    END IF;

    -- Quantité omise : on déplace tout. C'est le geste courant — « ces quatre-là
    -- sont de cette édition ».
    v_move := LEAST(COALESCE(p_quantity, v_available), v_available);
    IF v_move < 1 THEN
        RETURN 0;
    END IF;

    -- Rien à faire si la source et la cible sont la même ligne : le retrait
    -- suivi de l'ajout se solderait au même endroit, mais autant l'éviter.
    IF p_from_print_id IS NOT DISTINCT FROM p_to_print_id THEN
        RETURN v_available;
    END IF;

    IF v_move = v_available THEN
        DELETE FROM public.collection_items
        WHERE collection_id = v_collection
          AND oracle_id = p_oracle_id
          AND print_id IS NOT DISTINCT FROM p_from_print_id;
    ELSE
        UPDATE public.collection_items
        SET quantity = quantity - v_move
        WHERE collection_id = v_collection
          AND oracle_id = p_oracle_id
          AND print_id IS NOT DISTINCT FROM p_from_print_id;
    END IF;

    -- La cible peut déjà exister : les exemplaires fusionnent.
    INSERT INTO public.collection_items (collection_id, oracle_id, print_id, quantity)
    VALUES (v_collection, p_oracle_id, p_to_print_id, v_move)
    ON CONFLICT (collection_id, oracle_id, print_id) DO UPDATE
        SET quantity = public.collection_items.quantity + EXCLUDED.quantity
    RETURNING quantity INTO v_result;

    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.set_collection_print IS
    'Déplace des exemplaires d''une édition vers une autre (NULL = édition non '
    'précisée). Quantité omise : tout est déplacé. Fusionne si la cible existe déjà.';

-- ---------------------------------------------------------------------------
-- Lecture : une ligne par (carte, édition)
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
               SUM(i.quantity)::integer AS quantity,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id
    ),
    priced AS (
        SELECT m.*,
               -- Édition précisée : son prix fait foi. Sinon, le moins cher connu —
               -- l'exemplaire n'étant pas identifié, mieux vaut sous-estimer.
               COALESCE(pr.price_eur, cheap.price_eur) AS unit_price,
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
    -- Le filtre porte sur tous les noms connus de la carte, français compris :
    -- chercher « foudre » dans sa collection doit trouver Lightning Bolt.
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
        p.set_code NULLS FIRST
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection IS
    'Page de collection, une ligne par (carte, édition). Filtrable par nom (français '
    'compris). Les totaux sont dans my_collection_summary : une page ne les porte pas.';

CREATE FUNCTION public.my_collection_summary()
RETURNS TABLE (
    total_cards      integer,
    distinct_cards   integer,
    total_value_eur  numeric,
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
               SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id, i.print_id
    )
    SELECT COALESCE(SUM(m.quantity), 0)::integer,
           -- Les références comptent les *cartes*, pas les lignes : posséder Foudre
           -- en deux éditions ne fait pas deux cartes connues.
           COUNT(DISTINCT m.oracle_id)::integer,
           COALESCE(SUM(m.quantity * COALESCE(pr.price_eur, cheap.price_eur, 0)), 0),
           -- Combien d'exemplaires attendent encore d'être rattachés à une édition :
           -- c'est ce qui permet à l'écran de proposer de les préciser.
           COALESCE(SUM(m.quantity) FILTER (WHERE m.print_id IS NULL), 0)::integer
    FROM mine m
    LEFT JOIN public.card_prints pr ON pr.scryfall_id = m.print_id
    LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id;
$$;

GRANT EXECUTE ON FUNCTION public.card_printings(uuid, text, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.add_to_collection(uuid, integer, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_from_collection(uuid, integer, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_collection_print(uuid, uuid, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection_summary() TO authenticated;

COMMIT;
