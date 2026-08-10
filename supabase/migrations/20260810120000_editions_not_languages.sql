-- 025 — Une édition, pas une langue.
--
-- La migration 020 avait filtré le sélecteur sur la langue du nom trouvé : la
-- carte reconnue par son nom français, on ne montrait que les impressions
-- françaises. L'intention était juste — chaque édition apparaissait deux fois,
-- en français et en anglais, sans rien apprendre — mais le moyen était brutal.
--
-- Scryfall ne publie pas toutes les impressions dans toutes les langues. Sur
-- « Marvel Universe », 40 cartes sur 140 seulement existent en français ;
-- « Don't Move » (MAR #43) n'en fait pas partie. Un joueur tenant cette carte
-- en français voyait donc le sélecteur lui cacher son édition et ne lui
-- proposer que REX #1 — même carte, autre extension, illustration de dinosaure,
-- six fois le prix. Le filtre supprimait le doublon, mais quand il n'y avait pas
-- de doublon il supprimait la seule bonne réponse.
--
-- Le filtre devient donc **préférentiel plutôt qu'exclusif** : une ligne par
-- édition — c'est-à-dire par couple (extension, numéro de collection), ce qui
-- désigne l'objet physique —, servie dans la langue demandée quand elle existe,
-- à défaut en anglais. Le doublon disparaît toujours, mais plus aucune édition
-- avec lui.
--
-- C'est la granularité qu'emploie déjà `print_price` (migration 019) pour
-- emprunter une cote à l'impression jumelle d'une autre langue : même carte,
-- même boîte, seul le texte diffère. La cohérence entre les deux est voulue.
--
-- Effet de bord recherché : le nombre d'éditions d'une carte ne dépend plus de
-- la langue interrogée. « Cette carte n'a qu'une seule édition » devient une
-- affirmation stable, sur laquelle l'écran d'étalement peut s'appuyer pour
-- préciser tout seul ce qui n'admet qu'une réponse.

BEGIN;

-- ---------------------------------------------------------------------------
-- Les éditions d'un lot de cartes, une ligne par édition
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.card_editions(
    p_oracle_ids uuid[],
    p_lang       text DEFAULT NULL
)
RETURNS TABLE (
    oracle_id        uuid,
    print_id         uuid,
    set_code         text,
    set_name         text,
    collector_number text,
    rarity           text,
    lang             text,
    printed_name     text,
    price_eur        numeric,
    price_eur_foil   numeric,
    has_nonfoil      boolean,
    has_foil         boolean,
    released_at      date,
    owned            integer,
    art_crop_url     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH mine AS (
        SELECT i.print_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid() AND i.print_id IS NOT NULL
        GROUP BY i.print_id
    )
    -- Une seule impression retenue par (carte, extension, numéro). L'ordre de
    -- préférence répond à trois exigences, dans cet ordre :
    --   1. ne jamais faire disparaître un « déjà 2 » que l'utilisateur voyait —
    --      l'impression qu'il possède reste celle qu'on lui montre ;
    --   2. servir la langue du nom par lequel il a trouvé la carte ;
    --   3. à défaut, l'anglais, langue de référence du catalogue.
    -- La dernière clé n'existe que pour rendre le résultat déterministe : sans
    -- elle, deux ouvertures du sélecteur pourraient rendre deux lignes
    -- différentes pour la même édition.
    SELECT DISTINCT ON (p.oracle_id, p.set_code, p.collector_number)
           p.oracle_id,
           p.scryfall_id,
           p.set_code,
           p.set_name,
           p.collector_number,
           p.rarity,
           p.lang,
           p.printed_name,
           public.print_price(p.scryfall_id, false),
           public.print_price(p.scryfall_id, true),
           -- Une impression de bundle n'existe qu'en brillant : proposer
           -- « normal » n'aurait alors aucun sens.
           COALESCE('nonfoil' = ANY(p.finishes), true),
           COALESCE('foil' = ANY(p.finishes) OR 'etched' = ANY(p.finishes), false),
           p.released_at,
           COALESCE(m.owned, 0),
           p.art_crop_url
    FROM public.card_prints p
    LEFT JOIN mine m ON m.print_id = p.scryfall_id
    WHERE p.oracle_id = ANY(p_oracle_ids)
    ORDER BY p.oracle_id, p.set_code, p.collector_number,
             (COALESCE(m.owned, 0) > 0) DESC,
             -- `p_lang` nul rend NULL pour toutes les lignes : la clé est alors
             -- neutre et c'est l'anglais qui départage.
             (p.lang = p_lang) DESC,
             (p.lang = 'en') DESC,
             p.lang;
$$;

COMMENT ON FUNCTION public.card_editions(uuid[], text) IS
    'Éditions d''un lot de cartes : une ligne par (extension, numéro), servie dans '
    'la langue demandée quand elle existe, en anglais sinon.';

GRANT EXECUTE ON FUNCTION public.card_editions(uuid[], text) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Le sélecteur s'appuie dessus
-- ---------------------------------------------------------------------------

-- Signature inchangée : `CREATE OR REPLACE` suffit, sans risque de surcharge
-- PostgREST (migration 012).
CREATE OR REPLACE FUNCTION public.card_printings(
    p_oracle_id uuid,
    p_query     text    DEFAULT NULL,
    p_limit     integer DEFAULT 60,
    p_lang      text    DEFAULT NULL
)
RETURNS TABLE (
    print_id         uuid,
    set_code         text,
    set_name         text,
    collector_number text,
    rarity           text,
    lang             text,
    printed_name     text,
    price_eur        numeric,
    price_eur_foil   numeric,
    has_nonfoil      boolean,
    has_foil         boolean,
    released_at      date,
    owned            integer,
    art_crop_url     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH needle AS (
        SELECT lower(trim(COALESCE(p_query, ''))) AS n
    )
    SELECT e.print_id,
           e.set_code,
           e.set_name,
           e.collector_number,
           e.rarity,
           e.lang,
           e.printed_name,
           e.price_eur,
           e.price_eur_foil,
           e.has_nonfoil,
           e.has_foil,
           e.released_at,
           e.owned,
           e.art_crop_url
    FROM public.card_editions(ARRAY[p_oracle_id], p_lang) e
    WHERE ((SELECT n FROM needle) = ''
           OR lower(COALESCE(e.set_name, '')) LIKE '%' || (SELECT n FROM needle) || '%'
           OR lower(e.set_code) LIKE (SELECT n FROM needle) || '%')
    ORDER BY e.owned DESC,
             e.released_at DESC NULLS LAST,
             e.set_code,
             e.collector_number
    LIMIT GREATEST(1, LEAST(p_limit, 200));
$$;

COMMENT ON FUNCTION public.card_printings(uuid, text, integer, text) IS
    'Éditions d''une carte, cherchables par extension. Une ligne par édition, dans '
    'la langue demandée quand elle existe. Porte les deux cotes et les finitions.';

-- ---------------------------------------------------------------------------
-- Les cartes qui n'admettent qu'une seule édition
-- ---------------------------------------------------------------------------

-- En un aller-retour pour tout un étalement, et non une requête par carte : la
-- leçon de `search_cards_bulk` (migration 024) vaut ici aussi, où l'on
-- interroge le catalogue pour vingt cartes d'affilée.
CREATE OR REPLACE FUNCTION public.sole_editions(
    p_oracle_ids uuid[],
    p_lang       text DEFAULT NULL
)
RETURNS TABLE (
    oracle_id        uuid,
    print_id         uuid,
    set_code         text,
    set_name         text,
    collector_number text,
    rarity           text,
    lang             text,
    printed_name     text,
    price_eur        numeric,
    price_eur_foil   numeric,
    has_nonfoil      boolean,
    has_foil         boolean,
    released_at      date,
    owned            integer,
    art_crop_url     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT x.oracle_id,
           x.print_id,
           x.set_code,
           x.set_name,
           x.collector_number,
           x.rarity,
           x.lang,
           x.printed_name,
           x.price_eur,
           x.price_eur_foil,
           x.has_nonfoil,
           x.has_foil,
           x.released_at,
           x.owned,
           x.art_crop_url
    FROM (
        SELECT e.*, COUNT(*) OVER (PARTITION BY e.oracle_id) AS editions
        FROM public.card_editions(p_oracle_ids, p_lang) e
    ) x
    WHERE x.editions = 1;
$$;

COMMENT ON FUNCTION public.sole_editions(uuid[], text) IS
    'Pour chaque carte du lot n''ayant qu''une seule édition, cette édition. Les '
    'cartes qui en ont plusieurs sont absentes du résultat : il n''y a rien à '
    'choisir à leur place.';

GRANT EXECUTE ON FUNCTION public.sole_editions(uuid[], text) TO anon, authenticated;

COMMIT;
