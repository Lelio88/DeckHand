-- 005 — Opérations de collection.
--
-- Ces fonctions existent pour deux raisons :
--
-- 1. **Atomicité.** Ajouter une carte suppose de trouver la collection de
--    l'utilisateur, de la créer si elle n'existe pas, puis d'incrémenter la
--    quantité. Fait depuis le client, cela ferait trois allers-retours et
--    laisserait une fenêtre où deux ajouts simultanés créeraient deux
--    collections.
--
-- 2. **Jointures impossibles côté client.** Le prix de référence vit dans la vue
--    `card_cheapest_price`, et le nom français dans `card_search_names`. Une vue
--    n'ayant pas de clé étrangère, l'API REST ne sait pas la joindre
--    automatiquement.
--
-- Toutes sont en SECURITY INVOKER : elles restent soumises aux policies, et un
-- utilisateur ne peut donc toucher qu'à sa propre collection.

BEGIN;

-- Renvoie la collection de l'appelant, en la créant au besoin.
CREATE OR REPLACE FUNCTION public.ensure_my_collection()
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_collection uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'authentification requise';
    END IF;

    SELECT id INTO v_collection
    FROM public.collections
    WHERE owner_id = auth.uid()
    ORDER BY created_at
    LIMIT 1;

    IF v_collection IS NULL THEN
        INSERT INTO public.collections (owner_id)
        VALUES (auth.uid())
        RETURNING id INTO v_collection;
    END IF;

    RETURN v_collection;
END;
$$;

-- Ajoute des exemplaires d'une carte et renvoie la quantité totale possédée.
--
-- `print_id` reste NULL : l'édition n'est pas demandée à la saisie manuelle, et
-- la valorisation retombe alors sur le prix plancher de la carte.
CREATE OR REPLACE FUNCTION public.add_to_collection(
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
    v_quantity   integer;
BEGIN
    IF p_quantity < 1 THEN
        RAISE EXCEPTION 'quantité invalide : %', p_quantity;
    END IF;

    v_collection := public.ensure_my_collection();

    INSERT INTO public.collection_items (collection_id, oracle_id, print_id, quantity)
    VALUES (v_collection, p_oracle_id, NULL, p_quantity)
    ON CONFLICT (collection_id, oracle_id, print_id) DO UPDATE
        SET quantity = public.collection_items.quantity + EXCLUDED.quantity
    RETURNING quantity INTO v_quantity;

    RETURN v_quantity;
END;
$$;

-- Retire des exemplaires. La ligne disparaît quand il n'en reste aucun, plutôt
-- que de laisser traîner une quantité nulle — une carte non possédée ne doit pas
-- encombrer la collection.
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
    v_quantity   integer;
BEGIN
    v_collection := public.ensure_my_collection();

    UPDATE public.collection_items
    SET quantity = quantity - p_quantity
    WHERE collection_id = v_collection
      AND oracle_id = p_oracle_id
      AND print_id IS NULL
    RETURNING quantity INTO v_quantity;

    IF v_quantity IS NULL THEN
        RETURN 0;
    END IF;

    IF v_quantity <= 0 THEN
        DELETE FROM public.collection_items
        WHERE collection_id = v_collection
          AND oracle_id = p_oracle_id
          AND print_id IS NULL;
        RETURN 0;
    END IF;

    RETURN v_quantity;
END;
$$;

-- Contenu de la collection, enrichi de tout ce qu'il faut pour l'afficher.
CREATE OR REPLACE FUNCTION public.my_collection()
RETURNS TABLE (
    oracle_id       uuid,
    name            text,
    printed_name    text,
    type_line       text,
    quantity        integer,
    unit_price_eur  numeric,
    line_price_eur  numeric,
    legal_pauper    boolean,
    legal_modern    boolean,
    legal_commander boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT c.oracle_id,
           c.name,
           fr.name AS printed_name,
           c.type_line,
           i.quantity,
           p.price_eur,
           p.price_eur * i.quantity,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander
    FROM public.collection_items i
    JOIN public.collections col ON col.id = i.collection_id
    JOIN public.cards c ON c.oracle_id = i.oracle_id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = i.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = i.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE col.owner_id = auth.uid()
    ORDER BY COALESCE(fr.name, c.name);
$$;

GRANT EXECUTE ON FUNCTION public.ensure_my_collection() TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_to_collection(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_from_collection(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_collection() TO authenticated;

COMMIT;
