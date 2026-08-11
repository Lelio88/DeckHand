-- 050 — Un déplacement, c'est deux mouvements qui s'annulent, pas une
-- transaction qui contient des deux signes.
--
-- La détection posée à la migration précédente demandait à une transaction de
-- porter un mouvement négatif et un positif. C'est trop lâche : trois gestes
-- joués dans une même transaction — un ajout, un retrait, un rangement — y
-- répondent tous, et le journal les étiquette alors tous « changement
-- d'édition ». Constaté au premier essai, sur quatre mouvements dont deux
-- seulement en étaient un.
--
-- Un changement d'édition a une signature plus étroite : **exactement deux
-- mouvements, de somme nulle, sur la même carte**. C'est ce que produit
-- `set_collection_print`, quoi qu'il déplace — tout ou partie d'une ligne — et
-- ce qu'aucune combinaison d'ajouts et de retraits ne produit par accident.
--
-- Passer par l'application ne pose pas la question : chaque appel RPC est sa
-- propre transaction. La règle protège des scripts, des corrections à la main et
-- de tout ce qui, un jour, groupera plusieurs gestes.

BEGIN;

CREATE OR REPLACE FUNCTION public.my_collection_history(
    p_game      text    DEFAULT 'magic',
    p_oracle_id uuid    DEFAULT NULL,
    p_limit     integer DEFAULT 60,
    p_offset    integer DEFAULT 0
)
RETURNS TABLE (
    happened_at      timestamptz,
    delta            integer,
    oracle_id        uuid,
    name             text,
    printed_name     text,
    set_code         text,
    collector_number text,
    lang             text,
    is_foil          boolean,
    art_crop_url     text,
    is_opening       boolean,
    is_move          boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH mine AS (
        SELECT m.*
        FROM public.collection_movements m
        JOIN public.collections c ON c.id = m.collection_id
        JOIN public.cards ca ON ca.oracle_id = m.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
    ),
    -- **Exactement deux mouvements de somme nulle sur une même carte.** Ni perte
    -- ni acquisition : les exemplaires ont changé d'impression, c'est un
    -- rangement. La paire se cherche sur tout le journal de la collection, et
    -- non sur la fenêtre demandée : filtrer d'abord sur une carte ou sur une
    -- page casserait des paires et ferait passer un rangement pour une perte.
    pairs AS (
        SELECT m.tx_id, m.oracle_id
        FROM mine m
        WHERE m.tx_id <> 0
        GROUP BY m.tx_id, m.oracle_id
        HAVING COUNT(*) = 2 AND SUM(m.delta) = 0
    ),
    shown AS (
        SELECT m.* FROM mine m
        WHERE p_oracle_id IS NULL OR m.oracle_id = p_oracle_id
    )
    SELECT s.happened_at,
           s.delta,
           s.oracle_id,
           ca.name,
           p.printed_name,
           p.set_code,
           p.collector_number,
           p.lang,
           s.is_foil,
           p.art_crop_url,
           s.tx_id = 0 AS is_opening,
           EXISTS (
               SELECT 1 FROM pairs pr
               WHERE pr.tx_id = s.tx_id AND pr.oracle_id = s.oracle_id
           ) AS is_move
    FROM shown s
    JOIN public.cards ca ON ca.oracle_id = s.oracle_id
    LEFT JOIN public.card_prints p ON p.scryfall_id = s.print_id
    ORDER BY s.happened_at DESC, s.id DESC
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection_history(text, uuid, integer, integer) IS
    'Le journal d''une collection, du plus récent au plus ancien. `is_opening` '
    'marque le report initial ; `is_move` un changement d''édition, reconnu à '
    'sa signature — deux mouvements de somme nulle sur une même carte, dans une '
    'même transaction — plutôt que déclaré par l''appelant.';

COMMIT;
