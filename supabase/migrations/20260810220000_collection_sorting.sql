-- 030 — Ranger sa collection : sens du tri, rareté, finition, pleine illustration.
--
-- Quatre manques d'un même geste — celui de chercher une carte dans sa boîte.
--
-- **Le sens du tri.** Chaque critère n'existait que dans une direction : les
-- noms de A à Z, les valeurs du plus cher au moins cher. Or on cherche aussi
-- bien les cartes les moins chères d'une collection que les plus chères, et
-- l'autre bout d'un alphabet est aussi loin que le premier quand on fait
-- défiler. `p_descending` pilote la direction ; le sens d'origine de chaque
-- critère reste son défaut, décidé par l'application.
--
-- **La rareté.** Une boîte se range aussi par rareté, et le catalogue la
-- connaît déjà. Le classement passe par un rang explicite : trié comme du
-- texte, « common » précéderait « rare » qui précéderait « uncommon », ce qui
-- ne veut rien dire. Les deux jeux nomment leurs raretés différemment et avec
-- des casses différentes — `lower()` les réunit, et un rang inconnu ferme la
-- marche plutôt que de s'intercaler au hasard.
--
-- **La finition.** Le brillant et le normal cohabitent dans une collection,
-- avec des prix qui vont du simple au triple ; les isoler est le moyen de
-- vérifier ce qu'on possède vraiment de chaque.
--
-- **La pleine illustration** est une propriété de l'impression, pas de la
-- carte : la même carte existe en version ordinaire et en pleine illustration,
-- et un collectionneur les range à part. La colonne est ajoutée ici et
-- remplie par la réingestion du catalogue ; nulle en attendant, elle ne filtre
-- rien plutôt que de prétendre qu'aucune carte n'est concernée.

BEGIN;

-- ---------------------------------------------------------------------------
-- La pleine illustration entre au catalogue
-- ---------------------------------------------------------------------------

ALTER TABLE public.card_prints
    ADD COLUMN IF NOT EXISTS full_art boolean;

COMMENT ON COLUMN public.card_prints.full_art IS
    'Illustration débordant du cadre habituel, telle que Scryfall la signale. '
    'Propriété de l''impression : la même carte existe dans les deux formes.';

CREATE INDEX IF NOT EXISTS idx_card_prints_full_art
    ON public.card_prints (oracle_id) WHERE full_art;

-- ---------------------------------------------------------------------------
-- Rang de rareté, commun aux deux jeux
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rarity_rank(p_rarity text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT CASE lower(COALESCE(p_rarity, ''))
        WHEN 'common'    THEN 1
        WHEN 'uncommon'  THEN 2
        WHEN 'rare'      THEN 3
        WHEN 'epic'      THEN 4   -- Riftbound
        WHEN 'mythic'    THEN 5
        WHEN 'special'   THEN 6
        WHEN 'showcase'  THEN 7   -- Riftbound
        WHEN 'promo'     THEN 8   -- Riftbound
        WHEN 'bonus'     THEN 9
        ELSE 99                   -- inconnue : ferme la marche, ne s'intercale pas
    END;
$$;

COMMENT ON FUNCTION public.rarity_rank(text) IS
    'Ordonne les raretés des deux jeux sur une même échelle, de la plus commune '
    'à la plus rare. Insensible à la casse.';

GRANT EXECUTE ON FUNCTION public.rarity_rank(text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- La page de collection
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.my_collection(text, text, integer, integer, text, boolean);

CREATE FUNCTION public.my_collection(
    p_query            text    DEFAULT NULL,
    p_sort             text    DEFAULT 'name',
    p_limit            integer DEFAULT 50,
    p_offset           integer DEFAULT 0,
    p_game             text    DEFAULT 'magic',
    p_unspecified_only boolean DEFAULT false,
    p_descending       boolean DEFAULT false,
    -- 'foil' | 'nonfoil' | NULL
    p_finish           text    DEFAULT NULL,
    p_full_art         boolean DEFAULT NULL
)
RETURNS TABLE (
    oracle_id        uuid,
    print_id         uuid,
    is_foil          boolean,
    name             text,
    printed_name     text,
    type_line        text,
    set_code         text,
    set_name         text,
    collector_number text,
    rarity           text,
    full_art         boolean,
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
SET search_path TO 'public'
AS $$
    WITH needle AS (
        SELECT public.normalize_card_name(COALESCE(p_query, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id,
               i.print_id,
               i.is_foil,
               SUM(i.quantity)::integer AS quantity,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
          AND (NOT p_unspecified_only OR i.print_id IS NULL)
          AND (p_finish IS NULL
               OR (p_finish = 'foil' AND i.is_foil)
               OR (p_finish = 'nonfoil' AND NOT i.is_foil))
        GROUP BY i.oracle_id, i.print_id, i.is_foil
    ),
    priced AS (
        SELECT m.*,
               -- Édition précisée : son prix dans la finition possédée. Sinon le
               -- moins cher connu — l'exemplaire n'étant pas identifié, mieux
               -- vaut sous-estimer que d'inventer.
               COALESCE(
                   public.print_price(m.print_id, m.is_foil),
                   cheap.price_eur
               ) AS unit_price,
               pr.set_code,
               pr.set_name,
               pr.collector_number,
               pr.rarity,
               pr.full_art,
               public.rarity_rank(pr.rarity) AS rarity_rank,
               -- Partie chiffrée du numéro, seule comparable d'une carte à
               -- l'autre. Vide (`★`, `T`) ou absente : la ligne passe en fin de
               -- liste plutôt qu'en tête, où un zéro implicite l'aurait mise.
               NULLIF(regexp_replace(COALESCE(pr.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank,
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
        -- Le filtre de pleine illustration vit ici, la propriété appartenant à
        -- l'impression : une carte sans édition précisée n'est ni l'un ni
        -- l'autre, et sort donc de la liste dès qu'on demande à trancher.
        WHERE p_full_art IS NULL
           OR COALESCE(pr.full_art, false) = p_full_art
    )
    SELECT p.oracle_id,
           p.print_id,
           p.is_foil,
           c.name,
           p.shown_name,
           c.type_line,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.rarity,
           p.full_art,
           p.quantity,
           p.unit_price,
           p.unit_price * p.quantity,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           p.added_at
    FROM priced p
    JOIN public.cards c ON c.oracle_id = p.oracle_id AND c.game = p_game
    WHERE (SELECT n FROM needle) = ''
       OR EXISTS (
            SELECT 1 FROM public.card_search_names s
            WHERE s.oracle_id = p.oracle_id
              AND s.normalized LIKE '%' || (SELECT n FROM needle) || '%'
       )
    -- Chaque critère apparaît deux fois, une par direction. Une seule des deux
    -- lignes est active à la fois, les autres valant NULL pour toutes les
    -- lignes et n'ordonnant donc rien.
    ORDER BY
        CASE WHEN p_sort = 'price'    AND     p_descending THEN p.unit_price * p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'price'    AND NOT p_descending THEN p.unit_price * p.quantity END ASC  NULLS LAST,
        CASE WHEN p_sort = 'quantity' AND     p_descending THEN p.quantity END DESC NULLS LAST,
        CASE WHEN p_sort = 'quantity' AND NOT p_descending THEN p.quantity END ASC  NULLS LAST,
        CASE WHEN p_sort = 'recent'   AND     p_descending THEN p.added_at END DESC NULLS LAST,
        CASE WHEN p_sort = 'recent'   AND NOT p_descending THEN p.added_at END ASC  NULLS LAST,
        CASE WHEN p_sort = 'number'   AND     p_descending THEN p.number_rank END DESC NULLS LAST,
        CASE WHEN p_sort = 'number'   AND NOT p_descending THEN p.number_rank END ASC  NULLS LAST,
        CASE WHEN p_sort = 'rarity'   AND     p_descending THEN p.rarity_rank END DESC NULLS LAST,
        CASE WHEN p_sort = 'rarity'   AND NOT p_descending THEN p.rarity_rank END ASC  NULLS LAST,
        CASE WHEN p_sort = 'name'     AND     p_descending THEN COALESCE(p.shown_name, c.name) END DESC,
        -- Ascendant par défaut, et départage de tous les autres critères : sans
        -- lui, deux cartes de même prix pourraient changer de place d'une page à
        -- l'autre et réapparaître ou disparaître au défilement.
        COALESCE(p.shown_name, c.name),
        p.set_code NULLS FIRST,
        p.is_foil
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection(text, text, integer, integer, text, boolean, boolean, text, boolean) IS
    'Page de collection : cherchable, triable dans les deux sens par nom, '
    'numéro, rareté, valeur, quantité ou date d''entrée, et restreignable à une '
    'finition, aux pleines illustrations ou à ce qui reste à préciser.';

GRANT EXECUTE ON FUNCTION public.my_collection(text, text, integer, integer, text, boolean, boolean, text, boolean)
    TO authenticated;

COMMIT;
