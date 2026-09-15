-- Choisir la langue à retirer plutôt que la deviner.
--
-- **Une case peut ranger deux impressions distinctes du même numéro.** Le
-- français et l'anglais d'une même édition partagent la case (`binder.dart` :
-- « Une case n'est pas une impression »), mais restent deux lignes de
-- collection séparées, chacune sous son propre `print_id`. Le classeur ne
-- retenait qu'une seule impression « représentative » par case — le français
-- en priorité, l'anglais sinon, choix figé dans `my_binder_page` — et
-- « Retirer » ne visait que celle-là.
--
-- **Incident réel.** Une carte ajoutée en normal, puis une seconde fois en
-- brillant, toutes deux sous la même impression anglaise (résolue par le
-- sélecteur d'édition, qui préfère l'anglais faute de langue précisée),
-- tombait dans une case dont la représentative choisie par le classeur était
-- l'impression française du même numéro — restée à zéro exemplaire des deux
-- côtés. « Retirer un exemplaire normal » et « ...brillant » répondaient tous
-- deux « aucun exemplaire ici », alors que la case affichait bien ×2 : le
-- compte agrège les deux langues (migration 048), le retrait ne visait que
-- l'une d'elles.
--
-- **Le correctif ne devine pas, il demande — mais seulement s'il y a matière
-- à choisir.** Quand une case ne range qu'une langue, rien ne change : la
-- déduire reste le bon geste (§IV.8, « déduite sans geste quand rien ne reste
-- à choisir »). Quand elle en range deux et qu'on possède la finition
-- demandée dans plus d'une, l'application propose de choisir laquelle retirer
-- plutôt que de retenir une préférence arbitraire. Cette fonction rend les
-- impressions **effectivement possédées** de la case, par finition : c'est ce
-- qui permet au client de ne poser la question que quand elle a une réponse
-- à plusieurs branches.

BEGIN;

CREATE FUNCTION public.my_binder_case_editions(p_print_id uuid)
RETURNS TABLE (
    print_id     uuid,
    lang         text,
    printed_name text,
    qty_normal   integer,
    qty_foil     integer
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
    -- La case se déduit de l'impression de départ : même extension, même
    -- numéro. Partir du print_id plutôt que d'exiger le code d'extension du
    -- client évite de faire porter cette information à un widget qui ne la
    -- connaît pas déjà.
    WITH la_case AS (
        SELECT set_code, collector_number
        FROM public.card_prints
        WHERE scryfall_id = p_print_id
    ),
    mine AS (
        SELECT i.print_id,
               SUM(i.quantity) FILTER (WHERE NOT i.is_foil)::integer AS qty_normal,
               SUM(i.quantity) FILTER (WHERE i.is_foil)::integer     AS qty_foil
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        WHERE c.owner_id = auth.uid()
        GROUP BY i.print_id
    )
    SELECT p.scryfall_id,
           p.lang,
           p.printed_name,
           COALESCE(m.qty_normal, 0),
           COALESCE(m.qty_foil, 0)
    FROM public.card_prints p
    JOIN la_case lc ON lc.set_code = p.set_code
                   AND lc.collector_number IS NOT DISTINCT FROM p.collector_number
    LEFT JOIN mine m ON m.print_id = p.scryfall_id
    ORDER BY p.lang;
$$;

COMMENT ON FUNCTION public.my_binder_case_editions(uuid) IS
    'Les impressions d''une case (même extension, même numéro que p_print_id), '
    'avec ce qu''on possède de chacune par finition. Sert à proposer un choix '
    'de langue avant un retrait, seulement quand plus d''une impression en '
    'porte réellement pour la finition demandée.';

GRANT EXECUTE ON FUNCTION public.my_binder_case_editions(uuid) TO authenticated;

COMMIT;
