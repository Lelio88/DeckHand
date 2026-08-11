-- 048 — L'édition servie suit la langue lue, non celle qu'on possède déjà.
--
-- **Scanner une carte anglaise l'enregistrait en français.** Vécu deux fois sur
-- la collection réelle : un « Robot d'assaut d'HYDRA » et une « Kree Sentinel »
-- anglais, ajoutés le jour même, se sont rangés sur l'impression française —
-- celle qu'on possédait déjà depuis la veille. La collection affirmait donc
-- posséder deux exemplaires français d'une carte dont l'un est anglais.
--
-- La cause tient à l'ordre de préférence de `card_editions`, où « l'impression
-- déjà possédée » passait **avant** la langue du nom trouvé. L'intention était
-- juste : ne pas faire disparaître le « déjà 2 » sous les yeux de l'utilisateur
-- en lui servant une autre impression de la même case. Mais le remède visait la
-- conséquence, pas la cause : ce compteur ne devait pas dépendre de
-- l'impression choisie.
--
-- **Le compteur porte donc sur la case, non sur l'impression.** C'est déjà la
-- doctrine du reste du produit — une case est le couple (extension, numéro), la
-- langue est une propriété de ce qu'on y range. Compté ainsi, « déjà 2 »
-- s'affiche quelle que soit l'impression servie, et le critère qui faussait la
-- langue devient inutile : il disparaît.
--
-- Conséquence voulue : la version anglaise et la version française d'une même
-- case font deux lignes de collection distinctes, chacune dans sa langue, et le
-- classeur continue de les compter ensemble puisqu'il compte des cases.
--
-- Les signatures ne changent pas ; `CREATE OR REPLACE` suffit.

BEGIN;

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
    -- **Possédé se compte par case**, toutes langues et finitions confondues :
    -- c'est ce qui permet de servir l'impression de la langue lue sans effacer
    -- le compte sous les yeux de l'utilisateur.
    WITH mine AS (
        SELECT p.set_code,
               p.collector_number,
               SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        WHERE c.owner_id = auth.uid()
          AND p.oracle_id = ANY(p_oracle_ids)
        GROUP BY p.set_code, p.collector_number
    )
    -- Une seule impression retenue par (carte, extension, numéro), servie dans
    -- la langue du nom par lequel la carte a été trouvée ; à défaut l'anglais,
    -- langue de référence du catalogue. La dernière clé n'existe que pour
    -- rendre le résultat déterministe : sans elle, deux ouvertures du sélecteur
    -- pourraient rendre deux lignes différentes pour la même édition.
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
    LEFT JOIN mine m
           ON m.set_code = p.set_code
          AND m.collector_number IS NOT DISTINCT FROM p.collector_number
    WHERE p.oracle_id = ANY(p_oracle_ids)
    ORDER BY p.oracle_id, p.set_code, p.collector_number,
             -- `p_lang` nul rend NULL pour toutes les lignes : la clé est alors
             -- neutre et c'est l'anglais qui départage.
             (p.lang = p_lang) DESC,
             (p.lang = 'en') DESC,
             p.lang;
$$;

COMMENT ON FUNCTION public.card_editions(uuid[], text) IS
    'Éditions d''un lot de cartes : une ligne par (extension, numéro), servie '
    'dans la langue demandée quand elle existe, en anglais sinon. `owned` '
    'compte la case entière — toutes langues et finitions —, ce qui permet de '
    'servir la langue lue sans effacer le compte.';

COMMIT;
