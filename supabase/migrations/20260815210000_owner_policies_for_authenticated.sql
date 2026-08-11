-- Les politiques de propriété ne concernent que ceux qui ont un compte.
--
-- **Mesuré : `anon` se voyait refuser jusqu'à la lecture d'une collection
-- publiée**, et l'erreur ne parlait pas de la table qu'on interrogeait mais de
-- `collections`. La cause est une propriété peu intuitive de Postgres : quand
-- plusieurs politiques s'appliquent, **toutes** sont évaluées et leurs verdicts
-- réunis par un OU. Les politiques de propriété visaient le rôle `public`,
-- c'est-à-dire tout le monde, `anon` compris ; les évaluer demandait de lire
-- `collections.owner_id`, précisément ce qu'un inconnu ne doit pas pouvoir
-- faire. Le refus tombait avant que la politique publique n'ait son mot à dire.
--
-- Les restreindre à `authenticated` n'enlève aucun droit : un visiteur sans
-- compte n'a pas de propriété à faire valoir, `auth.uid()` y est nul et la
-- condition n'aurait jamais été vraie. Elle cesse simplement d'être posée.
--
-- Le corps des politiques ne change pas d'un caractère ; seul le rôle change.

BEGIN;

DROP POLICY IF EXISTS collections_owner ON public.collections;
CREATE POLICY collections_owner
    ON public.collections FOR ALL
    TO authenticated
    USING (owner_id = auth.uid())
    WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS collection_items_owner ON public.collection_items;
CREATE POLICY collection_items_owner
    ON public.collection_items FOR ALL
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.collections c
            WHERE c.id = collection_items.collection_id AND c.owner_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.collections c
            WHERE c.id = collection_items.collection_id AND c.owner_id = auth.uid()
        )
    );

COMMIT;
