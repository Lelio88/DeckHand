-- La résolution vérifie la propriété sans jamais l'exposer.
--
-- **Mesuré sous le rôle `anon` : refus, même sur une collection publiée.**
-- `readable_collection` doit lire `collections.owner_id` pour répondre « est-ce
-- la mienne ? », et c'est précisément la colonne qu'on refuse à `anon` — un
-- inconnu ne doit pas pouvoir rattacher une collection à un compte.
--
-- La contradiction n'est qu'apparente : la fonction a besoin de **consulter**
-- la colonne, pas de la **rendre**. `SECURITY DEFINER` dit exactement cela — le
-- corps s'exécute avec les droits du propriétaire, et ne renvoie qu'un
-- identifiant de collection, jamais celui d'un compte.
--
-- Ce que cela déplace : la fonction cesse d'être protégée par les droits de
-- l'appelant, son `WHERE` devient le seul garde-fou. Il tient en cinq lignes,
-- il ne rend rien d'autre qu'un `id`, et il est éprouvé dans les deux sens —
-- collection publiée et collection qui ne l'est pas.

BEGIN;

CREATE OR REPLACE FUNCTION public.readable_collection(p_collection uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.id
    FROM public.collections c
    WHERE CASE
              -- Rien de demandé : la mienne, comme avant.
              WHEN p_collection IS NULL THEN c.owner_id = auth.uid()
              -- Une collection désignée : la sienne, ou une publiée.
              ELSE c.id = p_collection
                   AND (c.is_public OR c.owner_id = auth.uid())
          END
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.readable_collection IS
    'Collection que l''appelant a le droit de lire : la sienne sans argument, '
    'celle qu''il désigne si elle est publique ou lui appartient, rien sinon. '
    'SECURITY DEFINER pour consulter owner_id sans jamais le rendre.';

COMMIT;
