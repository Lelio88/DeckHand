-- Le journal public apprend son jeu, comme la désignation le sait déjà (#36).
--
-- **Le calque était câblé sur Magic.** Le bot Twitch sait viser un jeu
-- (`python -m app.twitch --game riftbound`), le calque non : ses trois lectures
-- partaient avec la valeur par défaut. Un direct Riftbound pointait donc un bot
-- Riftbound vers un calque Magic — le bot répondait dans le chat, l'écran ne
-- montrait jamais rien, et rien ne le signalait. C'est le pire des défauts :
-- silencieux.
--
-- `public_spotlight` et `public_binder_page` prennent déjà `p_game` ; seul ce
-- journal ne l'avait pas. Le filtre se pose au même endroit qu'ailleurs, sur la
-- jointure au catalogue : `AND c.game = p_game`. Une carte d'un autre jeu
-- disparaît alors du journal, ce qui est la réponse voulue — un calque
-- Riftbound n'a rien à dire d'une carte Magic qui vient d'entrer.
--
-- **Remplacer et non surcharger.** `CREATE OR REPLACE` avec un paramètre de
-- plus crée une *seconde* fonction, et l'appel à deux arguments devient
-- ambigu : PostgREST ne saurait plus laquelle servir. D'où le DROP sur la
-- signature exacte, comme l'a fait la migration du tapis de désignation.
--
-- **Les droits se réattribuent.** Ils portent sur une signature, que le DROP
-- emporte avec la fonction ; les réécrire est obligatoire, faute de quoi
-- l'anonyme — c'est-à-dire le navigateur d'OBS — perd la porte.

BEGIN;

DROP FUNCTION IF EXISTS public.public_recent_additions(text, int);

CREATE FUNCTION public.public_recent_additions(
    p_handle text,
    p_game   text DEFAULT 'magic',
    p_limit  int DEFAULT 1
)
RETURNS TABLE (
    movement_id bigint,
    happened_at timestamptz,
    oracle_id uuid,
    name text,
    printed_name text,
    set_code text,
    collector_number text,
    -- L'illustration du catalogue, pas la carte filmée : nette, droite, et
    -- déjà là.
    art_crop_url text,
    price_eur numeric,
    is_foil boolean,
    copies_before bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH target AS (
        -- La résolution passe par la fonction existante, qui refuse déjà toute
        -- collection non publiée. La dupliquer ici en ferait deux à corriger.
        SELECT public.collection_by_handle(p_handle) AS id
    ),
    scope AS (
        SELECT c.id, c.shared_sets
        FROM public.collections c
        JOIN target t ON t.id = c.id
    ),
    additions AS (
        SELECT m.id,
               m.happened_at,
               m.oracle_id,
               m.print_id,
               m.is_foil,
               -- Ce que la collection comptait de cette impression **avant** ce
               -- mouvement : zéro pour une case comblée, plus pour un doublon.
               COALESCE(SUM(m.delta) OVER (
                   PARTITION BY m.collection_id, m.oracle_id, m.print_id, m.is_foil
                   ORDER BY m.id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
               ), 0) AS before
        FROM public.collection_movements m
        JOIN scope s ON s.id = m.collection_id
        -- Une sortie de collection n'a rien à annoncer en direct.
        WHERE m.delta > 0
    )
    SELECT a.id,
           a.happened_at,
           a.oracle_id,
           c.name,
           p.printed_name,
           p.set_code,
           p.collector_number,
           p.art_crop_url,
           public.print_price(p.scryfall_id, a.is_foil),
           a.is_foil,
           a.before
    FROM additions a
    JOIN scope s ON TRUE
    -- Le jeu se filtre ici, comme dans `public_spotlight` : c'est le catalogue
    -- qui porte l'appartenance, le journal ne la connaît pas.
    JOIN public.cards c ON c.oracle_id = a.oracle_id AND c.game = p_game
    LEFT JOIN public.card_prints p ON p.scryfall_id = a.print_id
    WHERE s.shared_sets IS NULL
       OR (p.set_code IS NOT NULL AND p.set_code = ANY(s.shared_sets))
    ORDER BY a.id DESC
    LIMIT GREATEST(1, LEAST(p_limit, 50));
$$;

COMMENT ON FUNCTION public.public_recent_additions(text, text, int) IS
    'Dernières cartes entrées dans une collection publiée, pour un overlay, '
    'filtrées par jeu. Respecte is_public ET shared_sets : le journal ne doit '
    'pas montrer ce que le classeur public cache.';

-- La porte est ouverte à l'anonyme : c'est un overlay dans OBS, il n'a pas de
-- compte, et l'adresse de la source finira dans une capture d'écran.
GRANT EXECUTE ON FUNCTION public.public_recent_additions(text, text, int) TO anon;
GRANT EXECUTE ON FUNCTION public.public_recent_additions(text, text, int) TO authenticated;

COMMIT;
