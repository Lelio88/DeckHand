-- Une collection par personne, garanti par la base.
--
-- **Chercher puis créer ne suffisait pas.** `ensure_my_collection` cherchait la
-- collection de l'appelant et la créait à défaut. Deux premiers ajouts
-- simultanés — deux appareils, deux requêtes parties ensemble — passaient tous
-- deux la recherche avant qu'aucun n'ait créé la sienne, et le compte se
-- retrouvait avec deux collections : les écritures en visaient une, et tout ce
-- qui additionnait ou choisissait autrement divergeait. La migration 005
-- annonçait déjà vouloir fermer cette fenêtre ; une fonction seule ne le peut
-- pas, une contrainte si.
--
-- **Vérifié avant d'ajouter la contrainte** : 3 collections pour 3
-- propriétaires. Si ce n'était plus vrai, ce fichier échouerait en entier plutôt
-- que de choisir à la place de quelqu'un laquelle garder.
--
-- L'insertion se fait désormais `ON CONFLICT (owner_id) DO NOTHING`, puis relit :
-- deux premiers ajouts simultanés aboutissent à la même collection, le second
-- attendant la validation du premier.

BEGIN;

ALTER TABLE public.collections
    ADD CONSTRAINT collections_owner_unique UNIQUE (owner_id);

COMMENT ON CONSTRAINT collections_owner_unique ON public.collections IS
    'Une collection par personne : sans elle, deux premiers ajouts simultanés en créaient deux.';

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
    WHERE owner_id = auth.uid();

    IF v_collection IS NULL THEN
        INSERT INTO public.collections (owner_id)
        VALUES (auth.uid())
        ON CONFLICT (owner_id) DO NOTHING;

        -- Relue plutôt que rendue par RETURNING : si un ajout concurrent l'a
        -- créée entre-temps, l'insertion n'a rien rendu, mais la ligne existe.
        SELECT id INTO v_collection
        FROM public.collections
        WHERE owner_id = auth.uid();
    END IF;

    RETURN v_collection;
END;
$$;

COMMIT;
