-- Ce qui vient d'entrer dans une collection publiée, pour l'overlay OBS (#14).
--
-- **Le journal existe déjà, mais il n'est lisible que par son propriétaire.**
-- `collection_movements` porte une politique `authenticated` sur la seule
-- collection de `auth.uid()`. Un overlay est lu par un navigateur anonyme dans
-- OBS : il lui faut une porte, et une porte qui ne s'ouvre que sur ce que le
-- propriétaire a effectivement donné à lire.
--
-- **Le piège que cette fonction existe pour éviter.** `shared_sets` permet de ne
-- publier que certaines extensions ; un journal lu sans ce filtre montrerait en
-- direct des cartes que le classeur public, lui, cache. Le partage par
-- extension serait contourné par la porte de derrière, et personne ne le verrait
-- puisque les deux écrans sont distincts. Le filtre est donc **ici**, dans la
-- fonction, et non dans la page.
--
-- Une carte sans édition n'appartient à aucune extension : elle disparaît dès
-- qu'un partage est restreint, exactement comme dans la politique de
-- `collection_items`. C'est la bonne réponse — elle n'est dans aucun des
-- classeurs qu'on a choisi de montrer.
--
-- **Pourquoi une fonction plutôt que Realtime.** L'issue supposait
-- `postgres_changes`. Deux raisons de ne pas le prendre. La première est la
-- portée : diffuser les lignes brutes du journal demanderait une politique
-- ouvrant `collection_movements` à `anon`, donc une seconde écriture de la règle
-- `shared_sets`, dans un endroit où elle serait plus facile à oublier. La
-- seconde est la robustesse, que l'issue réclame elle-même : « résister à la
-- coupure réseau sans afficher d'erreur en plein direct ». Une interrogation qui
-- échoue est sans effet — la page garde ce qu'elle affichait ; une connexion
-- persistante coupée demande une reconnexion, donc du code qui peut échouer
-- pendant un direct.
--
-- **`copies_before` dit ce qui a de la valeur pour un spectateur** : la carte
-- comble-t-elle une case vide, ou est-ce un doublon ? C'est la somme des
-- mouvements antérieurs sur la même impression — le journal la porte déjà, il
-- suffit de la lire.

BEGIN;

CREATE OR REPLACE FUNCTION public.public_recent_additions(
    p_handle text,
    p_limit int DEFAULT 1
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
    -- déjà là. C'est le choix de l'issue, et il est gratuit.
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
    JOIN public.cards c ON c.oracle_id = a.oracle_id
    LEFT JOIN public.card_prints p ON p.scryfall_id = a.print_id
    WHERE s.shared_sets IS NULL
       OR (p.set_code IS NOT NULL AND p.set_code = ANY(s.shared_sets))
    ORDER BY a.id DESC
    LIMIT GREATEST(1, LEAST(p_limit, 50));
$$;

COMMENT ON FUNCTION public.public_recent_additions(text, int) IS
    'Dernières cartes entrées dans une collection publiée, pour un overlay. '
    'Respecte is_public ET shared_sets : le journal ne doit pas montrer ce que '
    'le classeur public cache.';

-- La porte est ouverte à l'anonyme : c'est un overlay dans OBS, il n'a pas de
-- compte, et l'adresse de la source finira dans une capture d'écran.
GRANT EXECUTE ON FUNCTION public.public_recent_additions(text, int) TO anon;
GRANT EXECUTE ON FUNCTION public.public_recent_additions(text, int) TO authenticated;

COMMIT;
