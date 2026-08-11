-- 047 — Ranger un classeur par ce qu'on vient d'y mettre.
--
-- **Le tri par date d'entrée existait dans la liste et s'est perdu avec elle.**
-- C'est pourtant le geste qui répond à « qu'est-ce que je viens de saisir » —
-- vérifier une saisie, retrouver le lot d'hier, reprendre là où l'on s'était
-- arrêté. Il inventorie, comme la valeur, les exemplaires et le nom : une case
-- vide n'a pas de date d'entrée, et disparaît donc du rangement.
--
-- **`added_at` mesurait la première acquisition, pas le dernier ajout**, et
-- c'est ce qui rendait le tri trompeur avant même d'exister. `add_to_collection`
-- incrémente la quantité d'une ligne déjà présente sans toucher sa date : une
-- carte possédée depuis une semaine dont on ajoute un second exemplaire restait
-- datée de la semaine passée. Vécu sur la collection réelle — une « Sentinelle
-- kree » ajoutée le 10 puis complétée le 11 n'apparaissait nulle part parmi les
-- dernières entrées, et l'on cherchait en vain une carte pourtant bien enregistrée.
--
-- La date devient donc celle du **dernier ajout**. C'est la lecture que l'usage
-- demande : une carte dont on vient d'ajouter un exemplaire vient d'être
-- ajoutée. Retirer un exemplaire, en revanche, ne la remonte pas — on ne range
-- pas ce qu'on sort.
--
-- `my_binder_page` garde sa signature ; seule l'ordonnance change.

BEGIN;

-- ---------------------------------------------------------------------------
-- Un ajout est un ajout, même sur une ligne qui existait déjà
-- ---------------------------------------------------------------------------

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
        SET quantity = public.collection_items.quantity + EXCLUDED.quantity,
            -- Sans cette ligne, « les dernières ajoutées » omet toute carte
            -- qu'on possédait déjà : c'est précisément celle qu'on vient de
            -- poser sur la pile.
            added_at = NOW();

    SELECT COALESCE(SUM(quantity), 0)::integer INTO v_total
    FROM public.collection_items
    WHERE collection_id = v_collection AND oracle_id = p_oracle_id;

    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION public.add_to_collection(uuid, integer, uuid, boolean) IS
    'Ajoute des exemplaires et rend le total possédé de la carte, toutes '
    'éditions et finitions confondues — le nombre qu''affiche la saisie. '
    '`added_at` porte le dernier ajout, non la première acquisition.';

-- ---------------------------------------------------------------------------
-- Le classeur rangé par date d'entrée
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.my_binder_page(
    p_set_code   text,
    p_page       integer DEFAULT 1,
    p_per_page   integer DEFAULT 9,
    p_sort       text    DEFAULT 'number',
    p_finish     text    DEFAULT NULL,
    p_descending boolean DEFAULT false
)
RETURNS TABLE (
    collector_number text,
    oracle_id        uuid,
    print_id         uuid,
    name             text,
    printed_name     text,
    rarity           text,
    art_crop_url     text,
    price_eur        numeric,
    price_eur_foil   numeric,
    owned            integer,
    has_foil         boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH cells AS (
        SELECT DISTINCT ON (p.collector_number)
               p.collector_number,
               p.scryfall_id,
               p.oracle_id,
               p.printed_name,
               p.rarity,
               p.art_crop_url,
               NULLIF(regexp_replace(COALESCE(p.collector_number, ''), '\D', '', 'g'), '')::bigint
                   AS number_rank
        FROM public.card_prints p
        WHERE p.set_code = p_set_code
        ORDER BY p.collector_number,
                 (p.lang = 'fr') DESC,
                 (p.lang = 'en') DESC,
                 p.scryfall_id
    ),
    -- `print_price` porte le repli linguistique — Scryfall ne cote
    -- pratiquement que l'anglais — et distingue les deux finitions.
    prices AS (
        SELECT p.collector_number,
               MAX(public.print_price(p.scryfall_id, false)) AS price_eur,
               MAX(public.print_price(p.scryfall_id, true))  AS price_eur_foil
        FROM public.card_prints p
        WHERE p.set_code = p_set_code
        GROUP BY p.collector_number
    ),
    mine AS (
        SELECT p.collector_number,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil,
               -- Le plus récent des ajouts de la case : une case peut réunir
               -- plusieurs lignes — deux langues, deux finitions — et c'est le
               -- dernier geste qui la fait remonter.
               MAX(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        WHERE c.owner_id = auth.uid()
          AND p.set_code = p_set_code
          AND (p_finish IS NULL
               OR (p_finish = 'foil' AND i.is_foil)
               OR (p_finish = 'nonfoil' AND NOT i.is_foil))
        GROUP BY p.collector_number
    ),
    joined AS (
        SELECT cl.*,
               pr.price_eur,
               pr.price_eur_foil,
               COALESCE(m.copies, 0)   AS owned,
               COALESCE(m.foil, false) AS has_foil,
               m.added_at,
               -- Le tri par valeur porte sur la finition regardée : filtrer les
               -- brillants en classant sur des prix de cartes mates n'aurait
               -- aucun sens.
               COALESCE(
                   CASE WHEN p_finish = 'foil' THEN pr.price_eur_foil ELSE pr.price_eur END,
                   0
               ) AS sort_price
        FROM cells cl
        LEFT JOIN prices pr ON pr.collector_number = cl.collector_number
        LEFT JOIN mine m ON m.collector_number = cl.collector_number
        -- Hors du rangement, une case vide n'a rien à dire : ni valeur, ni nom,
        -- ni exemplaires, ni date d'entrée, ni place dans un ordre qui ne
        -- connaît pas les numéros.
        WHERE p_sort = 'number' OR COALESCE(m.copies, 0) > 0
    )
    SELECT j.collector_number,
           j.oracle_id,
           j.scryfall_id,
           c.name,
           j.printed_name,
           j.rarity,
           j.art_crop_url,
           j.price_eur,
           j.price_eur_foil,
           j.owned,
           j.has_foil
    FROM joined j
    LEFT JOIN public.cards c ON c.oracle_id = j.oracle_id
    ORDER BY
        CASE WHEN p_sort = 'price' AND NOT p_descending THEN j.sort_price END DESC,
        CASE WHEN p_sort = 'price' AND     p_descending THEN j.sort_price END ASC,
        -- Les plus nombreuses d'abord : « ai-je un playset ? » se lit en tête
        -- de classeur, pas en le parcourant.
        CASE WHEN p_sort = 'copies' AND NOT p_descending THEN j.owned END DESC,
        CASE WHEN p_sort = 'copies' AND     p_descending THEN j.owned END ASC,
        -- La dernière entrée d'abord : on trie par date pour vérifier ce qu'on
        -- vient de saisir, jamais pour remonter à ses débuts.
        CASE WHEN p_sort = 'recent' AND NOT p_descending THEN j.added_at END DESC,
        CASE WHEN p_sort = 'recent' AND     p_descending THEN j.added_at END ASC,
        CASE WHEN p_sort = 'name'  AND NOT p_descending THEN COALESCE(j.printed_name, c.name) END ASC,
        CASE WHEN p_sort = 'name'  AND     p_descending THEN COALESCE(j.printed_name, c.name) END DESC,
        CASE WHEN p_sort = 'number' AND p_descending THEN j.number_rank END DESC NULLS LAST,
        -- À égalité — deux cartes entrées dans le même lot, deux cases au même
        -- nombre d'exemplaires — l'ordre du rangement reprend la main.
        j.number_rank NULLS LAST,
        j.collector_number
    LIMIT GREATEST(1, LEAST(p_per_page, 60))
    OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60));
$$;

COMMENT ON FUNCTION public.my_binder_page(text, integer, integer, text, text, boolean) IS
    'Une page de classeur, avec les deux prix de chaque case. Trié par numéro, '
    'les cases vides figurent — c''est une complétion. Trié par valeur, par '
    'exemplaires, par date d''entrée ou par nom, elles disparaissent. '
    '`p_descending` renverse le sens de lecture.';

GRANT EXECUTE ON FUNCTION public.my_binder_page(text, integer, integer, text, text, boolean)
    TO anon, authenticated;

COMMIT;
