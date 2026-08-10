-- 039 — La pile à trier : les cartes qui n'ont encore aucune case.
--
-- **Une carte sans édition précisée n'est rangeable nulle part.** Le classeur
-- se dérive de `(set_code, collector_number)` ; sans impression désignée, il n'y
-- a ni extension ni numéro, donc pas de case. Ces cartes étaient invisibles dès
-- qu'on regardait sa collection en classeur — et le classeur étant devenu la vue
-- par défaut, elles disparaissaient purement et simplement.
--
-- **C'est une pile, pas un classeur**, et la fonction le dit : aucun numéro,
-- aucune case vide, aucun taux de complétion. Rien que ce qui reste à ranger.
--
-- **Ordonnée par entrée, la plus récente d'abord** : une pile se prend par le
-- dessus, et ce qu'on vient de saisir est ce qu'on a encore en main. Trier par
-- nom aurait enfoui la dernière carte scannée au milieu de l'alphabet.
--
-- **Une image malgré tout.** Sans impression désignée, aucune illustration n'est
-- attachée à la ligne ; on en élit une représentative — le français d'abord,
-- puis la plus récente. C'est faux au sens strict (ce n'est pas forcément
-- l'exemplaire qu'on tient), et c'est sans conséquence : cette vue sert à
-- reconnaître une carte pour lui donner son édition, pas à constater laquelle on
-- possède.

BEGIN;

CREATE OR REPLACE FUNCTION public.my_unsorted_pile(
    p_game     text    DEFAULT 'magic',
    p_page     integer DEFAULT 1,
    p_per_page integer DEFAULT 9
)
RETURNS TABLE (
    oracle_id    uuid,
    name         text,
    printed_name text,
    art_crop_url text,
    price_eur    numeric,
    owned        integer,
    has_foil     boolean,
    added_at     timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH mine AS (
        SELECT i.oracle_id,
               SUM(i.quantity)::integer AS copies,
               bool_or(i.is_foil)       AS foil,
               MIN(i.added_at)          AS added_at
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
          AND i.print_id IS NULL
        GROUP BY i.oracle_id
    ),
    -- Une impression représentative, seulement pour l'image et le nom imprimé.
    shown AS (
        SELECT DISTINCT ON (p.oracle_id)
               p.oracle_id, p.printed_name, p.art_crop_url
        FROM public.card_prints p
        JOIN mine m ON m.oracle_id = p.oracle_id
        ORDER BY p.oracle_id, (p.lang = 'fr') DESC, p.released_at DESC NULLS LAST
    )
    SELECT m.oracle_id,
           c.name,
           s.printed_name,
           s.art_crop_url,
           cheap.price_eur,
           m.copies,
           m.foil,
           m.added_at
    FROM mine m
    JOIN public.cards c ON c.oracle_id = m.oracle_id
    LEFT JOIN shown s ON s.oracle_id = m.oracle_id
    LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = m.oracle_id
    ORDER BY m.added_at DESC NULLS LAST, c.name
    LIMIT GREATEST(1, LEAST(p_per_page, 60))
    OFFSET (GREATEST(p_page, 1) - 1) * GREATEST(1, LEAST(p_per_page, 60));
$$;

COMMENT ON FUNCTION public.my_unsorted_pile(text, integer, integer) IS
    'Les cartes dont l''édition n''est pas précisée : elles n''ont aucune case '
    'de classeur, et seraient invisibles sans cette vue. Ordonnées par entrée, '
    'la plus récente d''abord — une pile se prend par le dessus.';

GRANT EXECUTE ON FUNCTION public.my_unsorted_pile(text, integer, integer)
    TO anon, authenticated;

COMMIT;
