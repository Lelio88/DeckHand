-- Le prix incomplet se dit, au lieu de se faire passer pour un prix
--
-- Suite immédiate de `20260916180000_deck_suggestions_par_cout.sql`, qui a mis
-- le coût de complétion en tête du classement. Conséquence non voulue : l'écran
-- met désormais ce coût en avant, et sur trois jeux entiers il est faux.
--
-- Un deck Pokémon dont trente-quatre cartes n'ont aucune cote s'affiche
-- « 4,25 € ». Ce n'est pas une approximation, c'est un prix qui ignore la
-- majorité du deck. Et il passe déjà à tort les filtres de budget : demander
-- « moins de 10 € » retenait ces decks-là.
--
-- Le tri les rétrogradait déjà — `unpriced_cards = 0` est sa condition — mais
-- l'information restait dans la base. Elle remonte maintenant jusqu'au client,
-- qui peut annoncer un prix partiel plutôt qu'un prix faux.
--
-- `DROP` puis `CREATE` : la table de retour change, et `CREATE OR REPLACE`
-- refuse de modifier le type d'une fonction existante.

BEGIN;

DROP FUNCTION IF EXISTS public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text[], text, boolean);

CREATE FUNCTION public.deck_suggestions(p_format text, p_max_missing integer DEFAULT 100, p_max_results integer DEFAULT 30, p_max_cost numeric DEFAULT NULL::numeric, p_tier text DEFAULT NULL::text, p_game text DEFAULT 'magic'::text, p_colors text[] DEFAULT NULL::text[], p_banned_colors text[] DEFAULT NULL::text[], p_commander text DEFAULT NULL::text, p_owned_commander boolean DEFAULT false)
 RETURNS TABLE(deck_id uuid, deck_name text, tier text, source_id text, source_name text, attribution text, total_cards integer, owned_cards integer, missing_cards integer, completion real, missing_cost_eur numeric, colors text[], commander_oracle_id uuid, commander_name text, commander_owned boolean, basic_lands integer, unpriced_cards integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    WITH wanted AS (
        SELECT public.normalize_card_name(COALESCE(p_commander, '')) AS n
    ),
    mine AS (
        SELECT i.oracle_id, SUM(i.quantity)::integer AS owned
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.oracle_id
    ),
    -- Ce qu'on possède déjà dans chaque deck : en nombre, et en valeur.
    -- Part de la collection, pas du corpus — seuls les decks contenant au moins
    -- une carte possédée sont touchés.
    owned AS (
        SELECT n.deck_id,
               SUM(LEAST(n.needed, m.owned))::integer                     AS owned_cards,
               SUM(LEAST(n.needed, m.owned) * n.unit_price_eur)           AS owned_cost_eur
        FROM mine m
        JOIN public.deck_needs n
          ON n.oracle_id = m.oracle_id AND NOT n.is_basic
        GROUP BY n.deck_id
    ),
    candidates AS (
        SELECT p.deck_id,
               p.total_cards,
               p.basic_lands,
               p.colors,
               p.unpriced_cards,
               COALESCE(o.owned_cards, 0)                                 AS owned_cards,
               p.total_cards - COALESCE(o.owned_cards, 0)                 AS missing_cards,
               p.total_cost_eur - COALESCE(o.owned_cost_eur, 0)           AS missing_cost_eur
        FROM public.deck_profile p
        LEFT JOIN owned o ON o.deck_id = p.deck_id
        WHERE p.game = p_game
          AND p.format = p_format
          AND p.total_cards > 0
    )
    SELECT d.id,
           d.name,
           d.tier,
           d.source_id,
           s.display_name,
           s.attribution_text,
           t.total_cards,
           t.owned_cards,
           t.missing_cards,
           (t.owned_cards::real / NULLIF(t.total_cards, 0))::real,
           t.missing_cost_eur,
           t.colors,
           d.commander_oracle_id,
           COALESCE(fr.name, cmd.name),
           d.commander_oracle_id IS NOT NULL
               AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id),
           t.basic_lands,
           t.unpriced_cards
    FROM candidates t
    JOIN public.decks d ON d.id = t.deck_id
    JOIN public.deck_sources s ON s.id = d.source_id
    LEFT JOIN public.cards cmd ON cmd.oracle_id = d.commander_oracle_id
    LEFT JOIN LATERAL (
        SELECT sn.name
        FROM public.card_search_names sn
        WHERE sn.oracle_id = d.commander_oracle_id AND sn.lang = 'fr'
        LIMIT 1
    ) fr ON true
    WHERE t.missing_cards <= p_max_missing
      AND (p_max_cost IS NULL OR t.missing_cost_eur <= p_max_cost)
      AND (p_tier IS NULL OR d.tier = p_tier)
      AND ((SELECT n FROM wanted) = ''
           OR EXISTS (
                SELECT 1 FROM public.card_search_names s2
                WHERE s2.oracle_id = d.commander_oracle_id
                  AND s2.normalized LIKE '%' || (SELECT n FROM wanted) || '%'
           ))
      AND (NOT p_owned_commander
           OR EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id))
      AND (p_colors IS NULL OR cardinality(p_colors) = 0
           OR p_colors <@ t.colors)
      AND (p_banned_colors IS NULL OR cardinality(p_banned_colors) = 0
           OR NOT (t.colors && p_banned_colors))
    ORDER BY (d.commander_oracle_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id)) DESC,
             -- Constructibles d'abord : rien à acheter bat tout le reste.
             (t.missing_cards = 0) DESC,
             -- **Puis le coût, mais seulement s'il est entier.** Le `CASE` rend
             -- `NULL` pour un deck dont une carte n'est pas cotée, et un `NULL`
             -- se range en dernier sur un tri croissant : les decks au prix
             -- connu passent devant, par coût, les autres suivent. C'est ce qui
             -- évite qu'un deck non coté paraisse gratuit et remonte en tête.
             CASE WHEN t.unpriced_cards = 0 THEN t.missing_cost_eur END,
             -- Pour ceux dont le prix est incomplet — trois jeux entiers —
             -- c'est la complétion qui ordonne, la valeur que l'écran affiche.
             (t.owned_cards::real / NULLIF(t.total_cards, 0)) DESC,
             t.missing_cards,
             d.name,
             -- Dernier départage, sans quoi deux decks jumeaux s'échangent
             -- d'un appel à l'autre.
             d.id
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$function$;

COMMENT ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text[], text, boolean) IS
    'Decks du corpus confrontés à la collection de l''appelant. Classés : '
    'constructibles d''abord, puis par coût de complétion quand il est entier, '
    'puis par complétion quand il ne l''est pas. `unpriced_cards` dit combien de '
    'cartes hors terrains n''ont aucune cote : au-dessus de zéro, '
    'missing_cost_eur est un plancher, pas un prix.';

GRANT EXECUTE ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text[], text, boolean)
    TO anon, authenticated;

COMMIT;
