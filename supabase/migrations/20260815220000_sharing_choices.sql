-- Choisir ce qu'on partage, et sous quel nom.
--
-- **Un interrupteur unique publiait toute la collection**, les deux jeux et les
-- cinq classeurs compris. Rien dans la base ne permettait de faire autrement :
-- `is_public` est un booléen sur la collection entière. Et l'adresse était un
-- UUID, impossible à dicter.
--
-- Deux colonnes y répondent.
--
-- **`shared_sets`** — `NULL` veut dire « tout », un tableau veut dire « ces
-- extensions-là ». Le défaut reste donc le comportement existant, et une
-- collection déjà publiée ne change pas de portée en jouant cette migration.
--
-- **`slug`** — un nom lisible à la place de l'UUID. Unique, en minuscules, et
-- **jamais obligatoire** : sans lui l'identifiant continue de fonctionner. La
-- contrainte de forme interdit ce qui casserait une URL ou se confondrait avec
-- un UUID.
--
-- **Le filtrage vit dans la politique, pas dans l'écran.** Restreindre
-- l'affichage laisserait un visiteur curieux interroger `collection_items`
-- directement et tout voir : la portée doit être une règle de la base. La
-- politique interroge donc l'extension de chaque ligne — le coût est réel mais
-- borné, une collection se comptant en centaines de lignes.
--
-- Conséquence sur la pile à trier : une carte sans édition n'appartient à
-- aucune extension, elle disparaît donc dès qu'un partage est restreint. C'est
-- la bonne réponse — elle n'est dans aucun des classeurs qu'on a choisi de
-- montrer.

BEGIN;

ALTER TABLE public.collections
    ADD COLUMN IF NOT EXISTS slug text,
    ADD COLUMN IF NOT EXISTS shared_sets text[];

COMMENT ON COLUMN public.collections.slug IS
    'Nom lisible qui remplace l''identifiant dans une adresse de partage. '
    'Facultatif : l''UUID fonctionne toujours.';
COMMENT ON COLUMN public.collections.shared_sets IS
    'Extensions données à lire. NULL = toutes — c''est le défaut, et le '
    'comportement d''avant cette colonne.';

-- Minuscules, chiffres et tirets ; 3 à 32 caractères. Assez pour être dicté,
-- trop court pour ressembler à un UUID, et sans rien qui demande un échappement
-- dans une URL.
ALTER TABLE public.collections
    DROP CONSTRAINT IF EXISTS collections_slug_shape;
ALTER TABLE public.collections
    ADD CONSTRAINT collections_slug_shape
    CHECK (slug IS NULL OR slug ~ '^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$');

CREATE UNIQUE INDEX IF NOT EXISTS collections_slug_unique
    ON public.collections (slug) WHERE slug IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Résoudre une adresse : un nom ou un identifiant, indifféremment
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.collection_by_handle(p_handle text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.id
    FROM public.collections c
    WHERE c.is_public
      AND (
          c.slug = lower(trim(p_handle))
          -- L'UUID reste accepté : les liens déjà donnés continuent de vivre.
          OR (p_handle ~ '^[0-9a-fA-F-]{36}$' AND c.id = p_handle::uuid)
      )
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.collection_by_handle IS
    'Collection publiée derrière ce nom ou cet identifiant, ou NULL. Ne rend '
    'rien pour une collection non publiée : une adresse essayée au hasard ne '
    'doit pas révéler qu''elle existe.';

GRANT EXECUTE ON FUNCTION public.collection_by_handle(text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Ce qu'un visiteur peut lire, ligne par ligne
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.collection_item_is_readable(
    p_collection uuid,
    p_print uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.collections c
        WHERE c.id = p_collection
          AND (
              c.owner_id = auth.uid()
              OR (
                  c.is_public
                  AND (
                      c.shared_sets IS NULL
                      OR EXISTS (
                          SELECT 1 FROM public.card_prints p
                          WHERE p.scryfall_id = p_print
                            AND p.set_code = ANY (c.shared_sets)
                      )
                  )
              )
          )
    );
$$;

COMMENT ON FUNCTION public.collection_item_is_readable IS
    'Cette ligne de collection est-elle lisible par l''appelant ? Tient compte '
    'de la portée choisie : une extension non partagée reste invisible, y '
    'compris à qui interroge la table directement.';

GRANT EXECUTE ON FUNCTION public.collection_item_is_readable(uuid, uuid) TO anon, authenticated;

DROP POLICY IF EXISTS collection_items_public_read ON public.collection_items;
CREATE POLICY collection_items_public_read
    ON public.collection_items FOR SELECT
    TO anon, authenticated
    USING (public.collection_item_is_readable(collection_id, print_id));

COMMIT;
