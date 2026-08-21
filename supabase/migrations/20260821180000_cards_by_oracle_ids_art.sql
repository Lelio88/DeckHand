-- Les cartes reconnues au fil de la caméra ont besoin de leur illustration.
--
-- **Ce qui n'allait pas.** `cards_by_oracle_ids` rend le nom, le type, le prix
-- et les légalités — tout sauf l'image. C'était sans conséquence tant que la
-- reconnaissance affichait des lignes de texte ; le mode vidéo montre désormais
-- les cartes en entier, et une carte sans illustration y devient un rectangle
-- gris qu'on ne peut ni reconnaître ni écarter en connaissance de cause. Or
-- c'est précisément ce que le §IV.8 attend de cette liste.
--
-- **Le manque ne se voyait qu'à moitié**, ce qui l'a rendu tardif à trouver :
-- l'écran retombait sur l'édition unique quand la carte n'en a qu'une, si bien
-- que les cartes récentes s'affichaient et les autres pas. « Conduit de
-- crevasse », qui existe en plusieurs éditions, est resté gris.
--
-- **La sous-requête est celle de `search_by_type`**, à l'identique : anglais
-- d'abord, puis la plus ancienne impression, puis l'identifiant pour départager.
-- Deux façons différentes de choisir une illustration donneraient deux images
-- pour la même carte selon l'écran qui la montre.
--
-- Le type de retour change, donc `CREATE OR REPLACE` ne suffit pas : Postgres
-- refuse d'ajouter une colonne à un `RETURNS TABLE` existant.

BEGIN;

DROP FUNCTION IF EXISTS public.cards_by_oracle_ids(uuid[]);

CREATE FUNCTION public.cards_by_oracle_ids(p_ids uuid[])
RETURNS TABLE (
    oracle_id       uuid,
    name            text,
    printed_name    text,
    type_line       text,
    price_eur       numeric,
    legal_pauper    boolean,
    legal_modern    boolean,
    legal_commander boolean,
    art_url         text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    SELECT c.oracle_id,
           c.name,
           fr.name,
           c.type_line,
           p.price_eur,
           c.legal_pauper,
           c.legal_modern,
           c.legal_commander,
           (SELECT pr.art_crop_url
            FROM public.card_prints pr
            WHERE pr.oracle_id = c.oracle_id AND pr.art_crop_url IS NOT NULL
            ORDER BY (pr.lang = 'en') DESC, pr.released_at NULLS LAST, pr.scryfall_id
            LIMIT 1)
    FROM unnest(p_ids) WITH ORDINALITY AS requested(id, position)
    JOIN public.cards c ON c.oracle_id = requested.id
    LEFT JOIN public.card_cheapest_price p ON p.oracle_id = c.oracle_id
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    ORDER BY requested.position;
$$;

COMMENT ON FUNCTION public.cards_by_oracle_ids IS
    'Détails des cartes désignées, dans l''ordre demandé — celui de la '
    'pertinence rendue par la reconnaissance. L''illustration est celle de '
    'l''impression anglaise la plus ancienne, comme dans search_by_type.';

GRANT EXECUTE ON FUNCTION public.cards_by_oracle_ids(uuid[]) TO anon, authenticated;

COMMIT;
