-- 036 — La collection telle que le constructeur de decks a besoin de la voir.
--
-- **Ce n'est pas une page de collection.** `my_collection` décrit ce qu'on
-- possède — édition, finition, prix, quantité — et le rend cinquante lignes à la
-- fois, ce qui est juste pour une liste qu'on fait défiler. Le constructeur, lui,
-- a besoin de la collection **entière et d'un coup** : il ne peut pas décider
-- quelles cartes retenir en n'en voyant qu'un vingtième.
--
-- Il a aussi besoin d'autre chose : le **texte oracle**, le coût de mana et
-- l'identité couleur. Aucun de ces champs n'a sa place sur une ligne de
-- collection, et c'est le texte qui permet de reconnaître qu'une carte sert de
-- retrait ou de pioche — le catalogue ne le dit nulle part ailleurs.
--
-- **Une ligne par carte, éditions confondues.** Deux exemplaires d'éditions
-- différentes sont la même carte pour un deck, et en Commander on ne peut de
-- toute façon en jouer qu'un. La quantité est rendue pour les formats qui
-- autorisent quatre exemplaires.
--
-- Le volume est borné par la nature de la chose : une collection de deux mille
-- cartes fait deux mille lignes, soit quelques centaines de kilo-octets. C'est
-- le prix d'un aller-retour, à comparer aux quarante que coûterait la
-- pagination.

BEGIN;

CREATE OR REPLACE FUNCTION public.my_buildable_cards(
    p_format text DEFAULT 'commander',
    p_game   text DEFAULT 'magic'
)
RETURNS TABLE (
    oracle_id      uuid,
    name           text,
    printed_name   text,
    type_line      text,
    mana_cost      text,
    cmc            numeric,
    color_identity text[],
    oracle_text    text,
    quantity       integer,
    price_eur      numeric
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    WITH mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS quantity
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    )
    SELECT c.oracle_id,
           c.name,
           fr.name,
           c.type_line,
           c.mana_cost,
           c.cmc,
           c.color_identity,
           COALESCE(c.oracle_text, ''),
           m.quantity,
           cheap.price_eur
    FROM mine m
    JOIN public.cards c ON c.oracle_id = m.oracle_id AND c.game = p_game
    LEFT JOIN public.card_cheapest_price cheap ON cheap.oracle_id = c.oracle_id
    -- Le nom français quand il existe : c'est celui qu'on lit sur la carte qu'on
    -- ira chercher dans sa boîte.
    LEFT JOIN LATERAL (
        SELECT s.name
        FROM public.card_search_names s
        WHERE s.oracle_id = c.oracle_id AND s.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE (p_format = 'commander' AND c.legal_commander)
       OR (p_format = 'pauper'    AND c.legal_pauper)
       OR (p_format = 'modern'    AND c.legal_modern)
    ORDER BY COALESCE(fr.name, c.name);
$$;

COMMENT ON FUNCTION public.my_buildable_cards(text, text) IS
    'Collection entière, jouable dans un format, avec le texte oracle dont le '
    'constructeur de decks a besoin pour reconnaître les rôles.';

GRANT EXECUTE ON FUNCTION public.my_buildable_cards(text, text) TO authenticated;

COMMIT;
