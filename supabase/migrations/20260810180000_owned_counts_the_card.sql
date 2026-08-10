-- 028 — Ajouter et retirer rendent le compte de la carte, pas celui de la ligne.
--
-- `add_to_collection` renvoyait la quantité de la ligne touchée — le triplet
-- (carte, édition, finition) — alors que « Déjà N » et « vous en avez N »
-- affichent, eux, le total de la carte tel que `search_cards` le calcule.
--
-- Les deux nombres coïncidaient tant qu'on ne possédait qu'une seule version
-- d'une carte, et divergeaient dès qu'on en précisait une seconde. Posséder un
-- Marais sans édition, en choisir une, puis ajouter : la base créait une
-- deuxième ligne à un exemplaire et renvoyait 1. L'écran affichait « Déjà 1 »
-- avant l'ajout, et « Déjà 1 » après — pour deux Marais en collection. L'ajout
-- avait bien eu lieu ; c'est le compteur qui changeait de sens en cours de
-- route.
--
-- Le total de la carte est le seul des deux qui réponde à la question que pose
-- l'écran de saisie : « en ai-je déjà ? ». Il ne dépend ni de l'édition
-- choisie ni de la finition, donc il ne peut plus se contredire lui-même.
--
-- Le décompte par édition n'est pas perdu pour autant : le sélecteur le porte
-- ligne par ligne (« déjà 2 »), et c'est là qu'il a du sens.
--
-- Les signatures ne changent pas ; `CREATE OR REPLACE` suffit.

BEGIN;

CREATE OR REPLACE FUNCTION public.add_to_collection(
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
    v_total      integer;
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
        SET quantity = public.collection_items.quantity + EXCLUDED.quantity;

    SELECT COALESCE(SUM(quantity), 0)::integer INTO v_total
    FROM public.collection_items
    WHERE collection_id = v_collection AND oracle_id = p_oracle_id;

    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION public.add_to_collection(uuid, integer, uuid, boolean) IS
    'Ajoute des exemplaires et rend le total possédé de la carte, toutes '
    'éditions et finitions confondues — le nombre qu''affiche la saisie.';

CREATE OR REPLACE FUNCTION public.remove_from_collection(
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
    v_total      integer;
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

    IF v_current IS NOT NULL THEN
        IF v_current <= p_quantity THEN
            DELETE FROM public.collection_items
            WHERE collection_id = v_collection
              AND oracle_id = p_oracle_id
              AND print_id IS NOT DISTINCT FROM p_print_id
              AND is_foil = v_foil;
        ELSE
            UPDATE public.collection_items
            SET quantity = quantity - p_quantity
            WHERE collection_id = v_collection
              AND oracle_id = p_oracle_id
              AND print_id IS NOT DISTINCT FROM p_print_id
              AND is_foil = v_foil;
        END IF;
    END IF;

    -- Le total de la carte, y compris quand la ligne visée n'existait pas :
    -- retirer ce qu'on ne possède pas ne doit pas faire croire à zéro
    -- exemplaire alors qu'une autre édition est en collection.
    SELECT COALESCE(SUM(quantity), 0)::integer INTO v_total
    FROM public.collection_items
    WHERE collection_id = v_collection AND oracle_id = p_oracle_id;

    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION public.remove_from_collection(uuid, integer, uuid, boolean) IS
    'Retire des exemplaires et rend le total possédé de la carte, toutes '
    'éditions et finitions confondues.';

COMMIT;
