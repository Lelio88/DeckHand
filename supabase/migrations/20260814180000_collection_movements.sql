-- 049 — Le journal des mouvements : ce qui est entré, ce qui est sorti, et quand.
--
-- **Une quantité et une date ne racontent pas une histoire.** `collection_items`
-- porte « ×3 » et une seule estampille : un ajout écrase la précédente, si bien
-- qu'une ligne alimentée trois jours de suite n'en garde qu'un seul jour. La
-- question « quand ai-je acquis cette carte » n'a donc aucune réponse — vécu sur
-- une Cavalerie atlante possédée en trois exemplaires français, dont il était
-- impossible de dire combien dataient de la veille.
--
-- **Un trigger plutôt que trois fonctions réécrites.** `add_to_collection`,
-- `remove_from_collection` et `set_collection_print` sont éprouvées ; les rouvrir
-- pour y glisser une écriture, c'est risquer une régression sur les gestes les
-- plus employés du produit. Le trigger consigne à leur place, et surtout **rien
-- ne peut lui échapper** : une écriture directe, un script d'ingestion, une
-- correction à la main laissent tous leur trace.
--
-- **Ce qu'on ne stocke pas : l'intention.** Le trigger ne voit que des deltas.
-- Préciser l'édition d'une carte déplace des exemplaires d'une impression à une
-- autre — un retrait et un ajout, qui ne sont pourtant ni une perte ni une
-- acquisition. Plutôt qu'une colonne « genre » que l'appelant devrait renseigner
-- honnêtement, on retient l'**identifiant de transaction** : deux mouvements de
-- signes opposés nés de la même transaction sont un déplacement, et la lecture
-- le déduit sans que personne ait eu à le déclarer.
--
-- **Le journal ne réécrit pas le passé.** Il s'amorce sur un report d'ouverture,
-- une ligne par entrée existante, datée de son `added_at`. C'est faux au détail
-- près — ces ×3 sont peut-être trois gestes — et honnête à l'échelle : le solde
-- du journal égale la collection dès le premier jour, et l'on sait que tout ce
-- qui précède l'ouverture est un report.
--
-- Le journal est **inaltérable depuis le client** : aucun droit d'écriture n'est
-- accordé, seul le trigger écrit (`SECURITY DEFINER`).

BEGIN;

CREATE TABLE IF NOT EXISTS public.collection_movements (
    id            bigserial PRIMARY KEY,
    collection_id uuid NOT NULL REFERENCES public.collections(id) ON DELETE CASCADE,
    oracle_id     uuid NOT NULL,
    -- L'impression concernée, `NULL` quand l'édition n'est pas précisée. On ne
    -- référence pas `card_prints` : une impression retirée du catalogue ne doit
    -- pas effacer l'histoire de ce qu'on a possédé.
    print_id      uuid,
    is_foil       boolean NOT NULL DEFAULT false,
    -- Positif à l'entrée, négatif à la sortie. Jamais nul : un mouvement qui ne
    -- déplace rien n'est pas un mouvement.
    delta         integer NOT NULL CHECK (delta <> 0),
    happened_at   timestamptz NOT NULL DEFAULT now(),
    -- Deux mouvements de signes opposés partageant cette valeur sont les deux
    -- faces d'un même geste : un changement d'édition, non une perte suivie
    -- d'une acquisition.
    tx_id         bigint NOT NULL DEFAULT txid_current()
);

COMMENT ON TABLE public.collection_movements IS
    'Journal des entrées et sorties de collection. Écrit par trigger, jamais '
    'par le client : c''est la seule source qui garde le quand, là où '
    '`collection_items` n''a qu''une quantité et une date écrasable.';
COMMENT ON COLUMN public.collection_movements.tx_id IS
    'Transaction d''origine. Deux mouvements opposés de même `tx_id` forment un '
    'changement d''édition, ce qui évite une colonne d''intention que '
    'l''appelant devrait renseigner honnêtement.';

-- L'ordre de lecture du journal : le plus récent d'abord, par collection.
CREATE INDEX IF NOT EXISTS idx_collection_movements_recent
    ON public.collection_movements (collection_id, happened_at DESC, id DESC);

-- « Quand ai-je acquis cette carte » interroge une carte, pas une date.
CREATE INDEX IF NOT EXISTS idx_collection_movements_card
    ON public.collection_movements (collection_id, oracle_id, happened_at DESC);

ALTER TABLE public.collection_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS collection_movements_owner ON public.collection_movements;
CREATE POLICY collection_movements_owner
    ON public.collection_movements FOR SELECT TO authenticated
    USING (EXISTS (
        SELECT 1 FROM public.collections c
        WHERE c.id = collection_id AND c.owner_id = auth.uid()
    ));

-- Lecture seule, et seulement la sienne. Le trigger écrit sous les droits du
-- propriétaire de la base : le journal ne peut donc pas être maquillé depuis
-- l'application.
GRANT SELECT ON public.collection_movements TO authenticated;

-- ---------------------------------------------------------------------------
-- Le trigger : tout passage par `collection_items` laisse une trace
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.log_collection_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_delta integer;
BEGIN
    v_delta := CASE TG_OP
        WHEN 'INSERT' THEN NEW.quantity
        WHEN 'DELETE' THEN -OLD.quantity
        ELSE NEW.quantity - OLD.quantity
    END;

    -- Une mise à jour qui ne change pas la quantité — une date retouchée, une
    -- édition corrigée en place — n'est pas un mouvement.
    IF v_delta = 0 THEN
        RETURN NULL;
    END IF;

    INSERT INTO public.collection_movements
        (collection_id, oracle_id, print_id, is_foil, delta)
    VALUES (
        COALESCE(NEW.collection_id, OLD.collection_id),
        COALESCE(NEW.oracle_id, OLD.oracle_id),
        COALESCE(NEW.print_id, OLD.print_id),
        COALESCE(NEW.is_foil, OLD.is_foil),
        v_delta
    );

    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.log_collection_movement() IS
    'Consigne tout changement de quantité dans `collection_movements`. '
    '`SECURITY DEFINER` : le journal s''écrit même si le client n''a aucun '
    'droit d''écriture dessus, ce qui le rend inaltérable depuis l''application.';

DROP TRIGGER IF EXISTS trg_collection_movements ON public.collection_items;
CREATE TRIGGER trg_collection_movements
    AFTER INSERT OR UPDATE OR DELETE ON public.collection_items
    FOR EACH ROW EXECUTE FUNCTION public.log_collection_movement();

-- ---------------------------------------------------------------------------
-- Report d'ouverture : la collection telle qu'elle est au premier jour
-- ---------------------------------------------------------------------------

-- Sans lui, le journal démarrerait vide sur une collection de 280 lignes, et
-- son solde contredirait la collection pendant des mois. Daté de `added_at` :
-- c'est tout ce que le passé a laissé.
INSERT INTO public.collection_movements
    (collection_id, oracle_id, print_id, is_foil, delta, happened_at, tx_id)
SELECT i.collection_id, i.oracle_id, i.print_id, i.is_foil, i.quantity, i.added_at, 0
FROM public.collection_items i
WHERE NOT EXISTS (
    SELECT 1 FROM public.collection_movements m
    WHERE m.collection_id = i.collection_id
);

-- ---------------------------------------------------------------------------
-- Lire le journal
-- ---------------------------------------------------------------------------

-- `tx_id = 0` marque le report d'ouverture : aucune transaction réelle ne porte
-- ce numéro, et la lecture peut donc le distinguer d'un vrai geste.
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
          AND (p_oracle_id IS NULL OR m.oracle_id = p_oracle_id)
    ),
    -- Un déplacement d'édition naît d'une transaction portant les deux signes :
    -- ni perte ni acquisition, un simple rangement.
    moves AS (
        SELECT m.tx_id
        FROM mine m
        WHERE m.tx_id <> 0
        GROUP BY m.tx_id
        HAVING MIN(m.delta) < 0 AND MAX(m.delta) > 0
    )
    SELECT m.happened_at,
           m.delta,
           m.oracle_id,
           ca.name,
           p.printed_name,
           p.set_code,
           p.collector_number,
           p.lang,
           m.is_foil,
           p.art_crop_url,
           m.tx_id = 0                                  AS is_opening,
           EXISTS (SELECT 1 FROM moves mv WHERE mv.tx_id = m.tx_id) AS is_move
    FROM mine m
    JOIN public.cards ca ON ca.oracle_id = m.oracle_id
    LEFT JOIN public.card_prints p ON p.scryfall_id = m.print_id
    ORDER BY m.happened_at DESC, m.id DESC
    LIMIT GREATEST(1, LEAST(p_limit, 200))
    OFFSET GREATEST(p_offset, 0);
$$;

COMMENT ON FUNCTION public.my_collection_history(text, uuid, integer, integer) IS
    'Le journal d''une collection, du plus récent au plus ancien. `is_opening` '
    'marque le report initial, `is_move` un changement d''édition — ni perte ni '
    'acquisition, déduit de la transaction plutôt que déclaré.';

GRANT EXECUTE ON FUNCTION public.my_collection_history(text, uuid, integer, integer)
    TO anon, authenticated;

COMMIT;
