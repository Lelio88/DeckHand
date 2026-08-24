-- La désignation : un spectateur fait monter une carte du classeur sur l'overlay.
--
-- **C'est la seule écriture de tout le chantier du bot (#21), et c'est ce qui la
-- retenait.** Les cinq autres commandes lisent ; écrire demandait soit d'ouvrir
-- une table aux écritures anonymes, soit la clé de service. La clé de service
-- est écartée par doctrine — elle contournerait la portée choisie dans l'écran
-- de partage, ce qui est l'unique erreur qui rendrait ce bot dangereux. Reste
-- l'écriture anonyme, et tout l'objet de ce fichier est de la borner assez pour
-- qu'elle soit sans conséquence.
--
-- **Ce qu'un inconnu peut faire au pire.** Il connaît l'adresse de partage — le
-- diffuseur l'a mise à l'antenne — et appelle `public_request_spotlight`
-- directement, sans passer par le chat ni par le débit du bot. Il peut alors
-- faire monter, une fois toutes les trente secondes, **une carte que le
-- propriétaire possède déjà et donne déjà à lire**. Il ne peut rien écrire
-- d'autre : la fonction ne touche qu'une table qui n'existe que pour ça, elle
-- n'accepte aucun texte libre hors un pseudonyme borné, et la table ne grossit
-- pas — une ligne par collection, écrasée.
--
-- **Trois verrous, et ils sont mécaniques.**
--
-- 1. `collection_by_handle` refuse toute collection non publiée. Rien à
--    désigner sur un classeur privé, comme pour les cinq lectures.
-- 2. La case doit être **possédée**. Sans ce contrôle, un inconnu ferait défiler
--    les 165 000 impressions du catalogue ; avec, il est borné aux quelques
--    centaines de cartes que le diffuseur montre de toute façon.
-- 3. Un délai de garde de trente secondes, tenu **dans la ligne elle-même**
--    plutôt que dans une table de compteurs — l'ancienne demande porte son
--    heure, il suffit de la lire.
--
-- **Trente secondes, et d'où vient ce nombre.** C'est le délai par recherche du
-- bot (`DEFAULT_QUERY_COOLDOWN_SECONDS`), choisi pour exactement cette
-- raison-là : « éviter de réécrire une réponse encore à l'écran ». La seule
-- contrainte dure est qu'il dépasse la durée d'affichage du calque
-- (`overlayLinger`, douze secondes) — en deçà, une demande remplacerait une
-- carte que le demandeur précédent n'a pas fini de voir. Trente couvre douze
-- avec de la marge. Si `overlayLinger` devait un jour dépasser trente, c'est ici
-- qu'il faudrait revenir.
--
-- **La lecture est l'autorité sur la portée, pas l'écriture.** `shared_sets`
-- s'applique dans `public_spotlight`, une seule fois, au moment de rendre la
-- carte. Écrire le filtre des deux côtés en ferait deux à tenir à jour ; et
-- surtout, la portée peut changer **après** la demande — un diffuseur qui retire
-- une extension du partage doit voir la carte désignée disparaître du calque,
-- pas rester à l'antenne parce qu'elle était partagée quand on l'a demandée.
--
-- **La désignation vise une case, pas une impression.** C'est ce que le classeur
-- montre, ce que `!card` répond, et ce que `binder_locate` rend déjà — donc
-- aucune signature à changer. L'impression représentative est choisie ici comme
-- dans `public_binder_page` : français, puis anglais, puis identifiant. Si les
-- deux divergeaient, le calque montrerait une autre illustration que la page.

BEGIN;

CREATE TABLE IF NOT EXISTS public.collection_spotlight (
    -- Une ligne par collection, écrasée. **Pas une file** : une demande servie
    -- quarante secondes plus tard arriverait alors que le direct parle d'autre
    -- chose, et la file serait la seule chose de ce fichier qui grossisse.
    collection_id    uuid PRIMARY KEY
        REFERENCES public.collections(id) ON DELETE CASCADE,

    -- **Ce qui dit qu'une demande est neuve**, et non le nom de la carte : deux
    -- spectateurs qui désignent la même carte sont deux événements, et le calque
    -- doit rejouer. C'est le jumeau exact de `movement_id` côté journal, ce qui
    -- laisse à l'overlay la logique de comparaison qu'il a déjà.
    request_id       bigint      NOT NULL,

    set_code         text        NOT NULL,
    collector_number text        NOT NULL,

    -- Le pseudonyme du demandeur, pour l'afficher. Borné : c'est la seule chaîne
    -- venue d'un inconnu qui atteigne cette table, et un champ non borné est une
    -- invitation. Twitch plafonne à 25 caractères ; on tronque à 40 plutôt que
    -- de refuser, un pseudonyme trop long n'étant pas une tentative d'abus.
    requested_by     text,

    requested_at     timestamptz NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.collection_spotlight IS
    'Carte qu''un spectateur a fait monter sur l''overlay, une par collection. '
    'Écrite par public_request_spotlight (anonyme, bornée), lue par '
    'public_spotlight (qui applique shared_sets).';

-- La séquence donne un identifiant neuf **à chaque écrasement** : une identité
-- de colonne ne bougerait pas sur un UPDATE, et le calque ne verrait jamais la
-- seconde demande.
CREATE SEQUENCE IF NOT EXISTS public.collection_spotlight_request_seq;

-- Aucun GRANT sur la table : les deux fonctions sont `SECURITY DEFINER`, et
-- personne n'atteint la table autrement. La RLS est activée en ceinture et
-- bretelles — sans politique, elle ne laisse rien passer à qui obtiendrait un
-- droit par accident.
ALTER TABLE public.collection_spotlight ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- L'écriture — la seule du chantier
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.public_request_spotlight(
    p_handle           text,
    p_set_code         text,
    p_collector_number text,
    p_requested_by     text DEFAULT NULL,
    p_game             text DEFAULT 'magic'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_collection uuid;
    v_last       timestamptz;
BEGIN
    -- Verrou 1 — collection publiée. Rend NULL sinon, comme pour les lectures.
    v_collection := public.collection_by_handle(p_handle);
    IF v_collection IS NULL THEN
        RETURN false;
    END IF;

    -- Verrou 2 — la case est possédée. Cette lecture contourne la RLS (on est en
    -- DEFINER) et c'est **voulu** : elle ne rend aucune donnée, elle répond oui
    -- ou non. La portée, elle, est appliquée à la lecture.
    IF NOT EXISTS (
        SELECT 1
        FROM public.collection_items i
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards c ON c.oracle_id = i.oracle_id AND c.game = p_game
        WHERE i.collection_id    = v_collection
          AND p.set_code         = p_set_code
          AND p.collector_number = p_collector_number
    ) THEN
        RETURN false;
    END IF;

    -- Verrou 3 — le délai de garde, lu dans la ligne précédente.
    SELECT s.requested_at INTO v_last
    FROM public.collection_spotlight s
    WHERE s.collection_id = v_collection;

    IF v_last IS NOT NULL AND v_last > NOW() - INTERVAL '30 seconds' THEN
        RETURN false;
    END IF;

    INSERT INTO public.collection_spotlight (
        collection_id, request_id, set_code, collector_number, requested_by, requested_at
    )
    VALUES (
        v_collection,
        nextval('public.collection_spotlight_request_seq'),
        p_set_code,
        p_collector_number,
        NULLIF(left(COALESCE(p_requested_by, ''), 40), ''),
        NOW()
    )
    ON CONFLICT (collection_id) DO UPDATE SET
        request_id       = EXCLUDED.request_id,
        set_code         = EXCLUDED.set_code,
        collector_number = EXCLUDED.collector_number,
        requested_by     = EXCLUDED.requested_by,
        requested_at     = EXCLUDED.requested_at;

    RETURN true;
END;
$$;

COMMENT ON FUNCTION public.public_request_spotlight IS
    'Fait monter une case du classeur sur l''overlay. Refuse (false) une '
    'collection non publiée, une case non possédée, ou une demande arrivée '
    'moins de 30 s après la précédente. Seule écriture accessible à anon.';

GRANT EXECUTE ON FUNCTION
    public.public_request_spotlight(text, text, text, text, text)
    TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- La lecture — et c'est elle qui applique la portée
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.public_spotlight(
    p_handle text,
    p_game   text DEFAULT 'magic'
)
RETURNS TABLE (
    request_id       bigint,
    requested_at     timestamptz,
    requested_by     text,
    name             text,
    printed_name     text,
    set_code         text,
    collector_number text,
    art_crop_url     text,
    price_eur        numeric,
    copies           integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
    WITH scope AS (
        SELECT c.id, c.shared_sets
        FROM public.collections c
        WHERE c.id = public.collection_by_handle(p_handle)
    ),
    asked AS (
        SELECT s.*
        FROM public.collection_spotlight s
        JOIN scope sc ON sc.id = s.collection_id
        -- **Une demande périmée ne remonte pas.** Sans cette borne, un overlay
        -- rouvert le lendemain afficherait la carte de la veille comme une
        -- nouveauté. Le calque a sa propre logique de première réponse, mais
        -- elle protège le lancement, pas une reprise en cours de direct.
        WHERE s.requested_at > NOW() - INTERVAL '10 minutes'
    ),
    -- Même impression représentative que `public_binder_page` : français, puis
    -- anglais, puis identifiant. Divergentes, le calque et la page montreraient
    -- deux illustrations pour la même case.
    chosen AS (
        SELECT DISTINCT ON (p.set_code, p.collector_number)
               p.set_code, p.collector_number, p.scryfall_id, p.oracle_id,
               p.printed_name, p.art_crop_url
        FROM public.card_prints p
        JOIN asked a
          ON a.set_code = p.set_code AND a.collector_number = p.collector_number
        ORDER BY p.set_code, p.collector_number,
                 (p.lang = 'fr') DESC, (p.lang = 'en') DESC, p.scryfall_id
    ),
    held AS (
        SELECT SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil
        FROM public.collection_items i
        JOIN scope sc ON sc.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN chosen ch ON ch.set_code = p.set_code
                      AND ch.collector_number = p.collector_number
    )
    SELECT a.request_id,
           a.requested_at,
           a.requested_by,
           c.name,
           COALESCE(NULLIF(ch.printed_name, ''), c.name),
           ch.set_code,
           ch.collector_number,
           ch.art_crop_url,
           public.print_price(ch.scryfall_id, COALESCE(h.foil, false)),
           COALESCE(h.copies, 0)
    FROM asked a
    JOIN chosen ch ON ch.set_code = a.set_code
                  AND ch.collector_number = a.collector_number
    JOIN public.cards c ON c.oracle_id = ch.oracle_id AND c.game = p_game
    CROSS JOIN scope sc
    LEFT JOIN held h ON TRUE
    -- **Le filtre de portée, et il n'existe qu'ici.** Une extension retirée du
    -- partage après la demande fait disparaître la carte du calque, ce qui est
    -- exactement ce qu'on veut : le partage est révocable, y compris a
    -- posteriori.
    WHERE sc.shared_sets IS NULL
       OR ch.set_code = ANY(sc.shared_sets);
$$;

COMMENT ON FUNCTION public.public_spotlight IS
    'La carte désignée sur l''overlay d''une collection publiée. Applique '
    'shared_sets : une extension retirée du partage disparaît du calque même '
    'si la demande est antérieure au retrait.';

GRANT EXECUTE ON FUNCTION public.public_spotlight(text, text) TO anon, authenticated;

COMMIT;
