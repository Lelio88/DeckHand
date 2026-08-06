-- 006 — Corrige le retrait d'une quantité supérieure à celle possédée.
--
-- Défaut de la version précédente : elle décrémentait d'abord
-- (`SET quantity = quantity - p_quantity`) puis supprimait la ligne si le
-- résultat tombait à zéro. Mais `collection_items` porte une contrainte
-- `CHECK (quantity > 0)` : la décrémentation était rejetée *avant* que la
-- suppression puisse avoir lieu.
--
-- Retirer 5 exemplaires d'une carte possédée en 1 seul remontait donc une
-- violation de contrainte au lieu de vider la ligne — un geste pourtant banal
-- quand on corrige une saisie.
--
-- La version corrigée lit la quantité et décide avant d'écrire. Le `FOR UPDATE`
-- verrouille la ligne : sans lui, deux retraits simultanés pourraient tous deux
-- lire la même quantité et décrémenter deux fois.

BEGIN;

CREATE OR REPLACE FUNCTION public.remove_from_collection(
    p_oracle_id uuid,
    p_quantity integer DEFAULT 1
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

    SELECT quantity INTO v_current
    FROM public.collection_items
    WHERE collection_id = v_collection
      AND oracle_id = p_oracle_id
      AND print_id IS NULL
    FOR UPDATE;

    -- Carte absente de la collection : rien à faire, et ce n'est pas une erreur.
    IF v_current IS NULL THEN
        RETURN 0;
    END IF;

    -- Retrait total (ou excédentaire) : la ligne disparaît.
    IF v_current <= p_quantity THEN
        DELETE FROM public.collection_items
        WHERE collection_id = v_collection
          AND oracle_id = p_oracle_id
          AND print_id IS NULL;
        RETURN 0;
    END IF;

    UPDATE public.collection_items
    SET quantity = quantity - p_quantity
    WHERE collection_id = v_collection
      AND oracle_id = p_oracle_id
      AND print_id IS NULL
    RETURNING quantity INTO v_current;

    RETURN v_current;
END;
$$;

COMMIT;
