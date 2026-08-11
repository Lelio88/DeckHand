-- 049 — Une écriture rend ce qu'elle a fait, non l'état qui en résulte.
--
-- **C'est ce qui rend un geste annulable.** Deux fonctions rendaient un total :
-- l'inverse exact ne s'en déduit pas, parce qu'un total mêle ce qu'on vient de
-- faire à ce qui était déjà là. Elles rendent désormais le nombre
-- d'exemplaires **effectivement déplacés** ou **effectivement retirés**.
--
-- **Corriger une édition était la seule écriture qu'on ne pouvait pas défaire.**
-- Ajouter a son inverse — retirer —, retirer a le sien, mais déplacer des
-- exemplaires d'une édition vers une autre ne s'annulait pas : la fonction
-- **fusionne** avec la ligne de destination si elle existe déjà
-- (`ON CONFLICT … quantity = quantity + EXCLUDED.quantity`) et rend le total
-- résultant, pas le nombre déplacé. Rejouer le mouvement en sens inverse sans
-- quantité déplacerait donc **tout** ce que porte la destination, exemplaires
-- qui s'y trouvaient déjà compris.
--
-- L'exemple qui tranche : on possède 2 « Foudre » MH2 et on corrige 1 « Foudre »
-- non précisée vers MH2. La ligne MH2 porte 3, et c'est ce que la fonction
-- rendait. Annuler ramènerait 3 exemplaires vers « non précisée » alors qu'un
-- seul en venait — la collection resterait juste en nombre total, mais deux
-- cartes bien rangées auraient quitté leur classeur sans que rien ne le dise.
--
-- **La valeur de retour change donc de sens** : elle compte désormais les
-- exemplaires **déplacés**. C'est le seul chiffre dont l'appelant ait besoin
-- pour écrire l'inverse exact — `set_collection_print(cible → source, quantité)`
-- —, et aucun appelant ne lisait l'ancien : les trois sites d'appel de
-- l'application ignorent le retour (`binder_view.dart`, `card_search_screen.dart`).
--
-- Le corps n'est pas retouché autrement : mêmes verrous, même fusion, mêmes
-- gardes. Seul le `RETURNING` disparaît au profit de `v_move`, déjà calculé.
-- Le cas « rien à faire » — même édition, même finition — rend 0 plutôt que la
-- quantité en place : zéro exemplaire a bougé, et l'appelant n'a rien à
-- proposer d'annuler.

BEGIN;

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

    -- Source et destination confondues : rien ne bouge, donc rien à annuler.
    IF p_from_print_id IS NOT DISTINCT FROM p_to_print_id AND v_from_foil = v_to_foil THEN
        RETURN 0;
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
        SET quantity = public.collection_items.quantity + EXCLUDED.quantity;

    RETURN v_move;
END;
$$;

COMMENT ON FUNCTION public.set_collection_print(uuid, uuid, uuid, integer, boolean, boolean) IS
    'Déplace des exemplaires d''une édition vers une autre et rend le nombre '
    'd''exemplaires DÉPLACÉS — non le total de la ligne de destination, qui '
    'peut en porter d''autres. C''est ce nombre qui rend le geste réversible : '
    'l''inverse s''écrit set_collection_print(cible, source, ce nombre).';

GRANT EXECUTE ON FUNCTION public.set_collection_print(uuid, uuid, uuid, integer, boolean, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- Retirer : dire combien d'exemplaires sont partis, non ce qui reste
-- ---------------------------------------------------------------------------
--
-- **Le classeur affirmait des retraits qui n'avaient pas eu lieu.** Une case
-- range ensemble le normal et le brillant ; la feuille d'action propose donc
-- « Retirer un exemplaire brillant » même sur une case qui n'en contient
-- aucun, et la fonction ne faisait alors rien — silencieusement. Le total
-- rendu ne permettait pas de s'en apercevoir : il compte la carte entière, y
-- compris quand la ligne visée n'existait pas, précisément pour ne pas laisser
-- croire à zéro exemplaire quand une autre édition est en collection.
--
-- Rendre le nombre retiré tranche les deux problèmes d'un coup : l'appelant
-- sait s'il doit annoncer un retrait, et il sait qu'il peut proposer de
-- l'annuler — un « Annuler » qui rajouterait un exemplaire jamais retiré
-- inventerait une carte.
--
-- L'appelant qui affichait le total le tient toujours : il en soustrait ce qui
-- vient de partir, ce qu'il sait faire puisqu'il l'affichait déjà.

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
    v_removed    integer;
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

    -- On ne retire jamais plus qu'on ne possède : demander d'en retirer trois
    -- quand il en reste un en retire un, et c'est ce chiffre qu'on rend.
    v_removed := LEAST(p_quantity, v_current);

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

    RETURN v_removed;
END;
$$;

COMMENT ON FUNCTION public.remove_from_collection(uuid, integer, uuid, boolean) IS
    'Retire des exemplaires d''une ligne précise et rend le nombre '
    'd''exemplaires RETIRÉS — non le total restant. Zéro signifie que la ligne '
    'visée n''existait pas : il n''y a alors ni retrait à annoncer, ni rien à '
    'annuler.';

GRANT EXECUTE ON FUNCTION public.remove_from_collection(uuid, integer, uuid, boolean) TO authenticated;

COMMIT;
