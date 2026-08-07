-- 019 — Le brillant est une carte distincte, pas une variante cosmétique.
--
-- Une impression foil se vend couramment le double ou le triple de sa jumelle
-- normale, et les deux cohabitent dans une collection. Les confondre fausse la
-- valorisation dans les deux sens : compter un foil au prix normal sous-estime,
-- l'inverse surestime.
--
-- Trois conséquences sur le schéma :
--
-- 1. `card_prints` sépare les deux cotes. Jusqu'ici `price_eur` recevait le prix
--    foil en repli quand le non-foil manquait (migration 017 côté ingestion) —
--    utile pour ne pas compter zéro, mais cela mélangeait deux objets.
-- 2. `collection_items` gagne `is_foil`, qui entre dans la clé d'unicité : la
--    même carte, même édition, en normal et en brillant, fait deux lignes.
-- 3. `finishes` note ce qui existe réellement : une impression qui n'a jamais
--    été imprimée en brillant ne doit pas proposer l'option.

BEGIN;

-- ---------------------------------------------------------------------------
-- Les deux cotes, séparées
-- ---------------------------------------------------------------------------

ALTER TABLE public.card_prints
    ADD COLUMN IF NOT EXISTS price_eur_foil numeric,
    ADD COLUMN IF NOT EXISTS price_usd_foil numeric,
    -- Finitions réellement produites, telles que Scryfall les publie :
    -- « nonfoil », « foil », « etched ». Une impression de bundle n'existe
    -- souvent qu'en foil, et proposer « normal » n'aurait alors aucun sens.
    ADD COLUMN IF NOT EXISTS finishes text[];

COMMENT ON COLUMN public.card_prints.price_eur_foil IS
    'Cote de la version brillante. Distincte de price_eur : c''est un autre objet.';
COMMENT ON COLUMN public.card_prints.finishes IS
    'Finitions réellement imprimées (nonfoil, foil, etched). Détermine ce que le '
    'sélecteur peut proposer.';

-- ---------------------------------------------------------------------------
-- Le brillant entre dans l'identité d'une ligne de collection
-- ---------------------------------------------------------------------------

ALTER TABLE public.collection_items
    ADD COLUMN IF NOT EXISTS is_foil boolean NOT NULL DEFAULT false;

-- L'ancienne clé ignorait la finition : deux lignes ne pouvaient pas coexister.
ALTER TABLE public.collection_items
    DROP CONSTRAINT IF EXISTS collection_items_collection_id_oracle_id_print_id_key;

CREATE UNIQUE INDEX IF NOT EXISTS collection_items_identity
    ON public.collection_items (collection_id, oracle_id, print_id, is_foil)
    NULLS NOT DISTINCT;

COMMENT ON COLUMN public.collection_items.is_foil IS
    'Exemplaire brillant. Entre dans la clé d''unicité : la même carte en normal '
    'et en brillant occupe deux lignes, comme deux éditions différentes.';

-- ---------------------------------------------------------------------------
-- Prix effectif : selon la finition, avec repli sur la langue de référence
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.card_print_price;

CREATE FUNCTION public.print_price(p_print_id uuid, p_foil boolean)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT COALESCE(
        -- La cote de l'impression elle-même, dans la finition demandée.
        CASE WHEN p_foil THEN p.price_eur_foil ELSE p.price_eur END,
        -- À défaut, celle de son équivalent dans une autre langue : Scryfall ne
        -- cote pas les impressions localisées, alors que c'est le même objet.
        (SELECT CASE WHEN p_foil THEN o.price_eur_foil ELSE o.price_eur END
         FROM public.card_prints o
         WHERE o.oracle_id = p.oracle_id
           AND o.set_code = p.set_code
           AND o.collector_number IS NOT DISTINCT FROM p.collector_number
           AND (CASE WHEN p_foil THEN o.price_eur_foil ELSE o.price_eur END) IS NOT NULL
         ORDER BY (o.lang = 'en') DESC
         LIMIT 1),
        -- En dernier recours, l'autre finition : mieux vaut un ordre de grandeur
        -- que zéro, qui se propagerait en silence dans la valorisation.
        CASE WHEN p_foil THEN p.price_eur ELSE p.price_eur_foil END
    )
    FROM public.card_prints p
    WHERE p.scryfall_id = p_print_id;
$$;

COMMENT ON FUNCTION public.print_price IS
    'Prix d''une impression dans la finition demandée, avec repli sur la version '
    'anglaise puis sur l''autre finition. Jamais zéro par défaut.';

GRANT EXECUTE ON FUNCTION public.print_price(uuid, boolean) TO anon, authenticated;

COMMIT;
