-- Les suggestions de decks cessent de relire tout le corpus à chaque ouverture
--
-- Motivation : `deck_suggestions` rendait `57014 canceling statement due to
-- statement timeout` sur trois jeux — l'onglet Decks était en panne, pas lent.
-- Mesuré sous le rôle `authenticated`, qui coupe à huit secondes :
--
--     magic     pauper          2,0 s    30 decks
--     magic     commander       2,4 s    30 decks
--     riftbound constructed     4,4 s    30 decks
--     onepiece  op_standard     3,5 s    30 decks
--     yugioh    edison          8,1 s    HTTP 500 57014
--     pokemon   standard        8,4 s    HTTP 500 57014
--     swu       premier         8,2 s    HTTP 500 57014
--
-- **Le matériel n'y était pour rien.** `EXPLAIN (ANALYZE, BUFFERS)` donnait
-- 248 036 blocs touchés — près de deux gigaoctets traversés — pour rendre
-- trente lignes, et **zéro lecture disque** : c'était du processeur, pas de
-- l'attente d'entrées-sorties. La fonction calculait totaux, couleurs et prix
-- des cartes manquantes pour *tout le corpus du format*, puis n'en gardait que
-- trente. Le coût suivait donc le volume du format, pas celui du résultat :
--
--     pokemon   standard    23 431 decks    595 239 lignes `main`
--     swu       premier      5 038 decks    116 835
--     yugioh    edison       3 050 decks    119 447
--     magic     pauper       1 017 decks     18 294
--
-- Magic passait parce que Pauper est le plus petit corpus du lot.
--
-- **Ce que cette migration change.** Trois des quatre gros postes ne dépendent
-- pas de la collection : le total d'un deck, ses terrains de base, son identité
-- couleur, et le prix de ses cartes. Ils sont désormais précalculés.
--
-- La clé de voûte est une réécriture du coût :
--
--     coût_manquant = coût_total_du_deck − coût_de_ce_qu_on_possède_dedans
--
-- exacte et non approchée, `Σ(besoin−possédé)×prix` valant
-- `Σ besoin×prix − Σ possédé×prix`. Elle renverse le sens de la jointure : au
-- lieu de parcourir 595 000 lignes de decklist pour y chercher la collection,
-- on part des quelques centaines de cartes possédées et on remonte vers les
-- decks par `idx_deck_needs_oracle`. Le nombre de cartes manquantes se déduit
-- de la même façon.
--
-- Mesuré, médiane de trois passes :
--
--     jeu/format              avant       après     gain
--     magic/pauper            660 ms       14 ms      46x
--     magic/commander         374 ms        6 ms      61x
--     riftbound/constructed  2950 ms       43 ms      69x
--     yugioh/edison          4829 ms       36 ms     136x
--     pokemon/standard       expire       262 ms        —
--     swu/premier            expire        92 ms        —
--     onepiece/op_standard   expire        43 ms        —
--
-- **Les résultats sont identiques**, vérifié sur les cent premiers decks de
-- pauper, modern et commander, tous champs confondus. Le seul écart relevé
-- portait sur l'`id` d'un deck Commander de rang 23 : deux decks nommés
-- « Devour for Power », même commandant, même total, même coût — un ex aequo
-- parfait sur toutes les clés de tri, que Postgres départageait arbitrairement.
-- Douze decks Commander sont dans ce cas, et la fonction actuelle pouvait donc
-- rendre deux listes différentes pour deux appels identiques. `d.id` est ajouté
-- en dernier départage : ce n'est pas un ordre plus juste, c'est un ordre
-- stable.
--
-- **L'invariant que cette migration introduit** : un deck n'entre dans les
-- suggestions qu'après reconstruction de `deck_needs` et `deck_profile`. Comme
-- les decks n'arrivent que par `app.ingestion.refresh`, qui reconstruit dans la
-- même passe, l'écart est nul en pratique — mais il existe, et une insertion
-- faite à la main resterait invisible jusqu'au prochain rafraîchissement.
--
-- Refs: `api/app/measure/deck_suggestions.py` — le banc qui sort en code 1
-- tant qu'un jeu dépasse le plafond du rôle.

BEGIN;

-- ---------------------------------------------------------------------------
-- Ce qu'un deck demande, carte par carte.
-- ---------------------------------------------------------------------------
--
-- C'est le CTE `entries` de l'ancienne fonction, figé. `unit_price_eur` y vit
-- aussi : le laisser dehors obligeait le chemin chaud à retourner chercher le
-- prix le moins cher pour chaque ligne retenue, et c'est précisément la
-- latérale que les migrations 20260903150000 et 20260903170000 ont mise en
-- place partout ailleurs. Ici elle n'a plus lieu d'être — le prix ne bouge
-- qu'une fois par jour (`CLAUDE.md` §IV.5) et la reconstruction est
-- quotidienne.
--
-- Pas de clé étrangère vers `decks` : la table est reconstruite en entier à
-- chaque passe, et la vérification référentielle sur un million de lignes
-- coûterait plus que ce qu'elle protège. `ON DELETE CASCADE` n'aurait rien à
-- faire non plus, un deck supprimé disparaissant à la reconstruction suivante.
CREATE TABLE IF NOT EXISTS public.deck_needs (
    deck_id        uuid    NOT NULL,
    oracle_id      uuid    NOT NULL,
    needed         integer NOT NULL,
    is_basic       boolean NOT NULL,
    unit_price_eur numeric NOT NULL DEFAULT 0,
    PRIMARY KEY (deck_id, oracle_id)
);

COMMENT ON TABLE public.deck_needs IS
    'Dérivée de deck_cards : une ligne par (deck, carte) du board principal, '
    'avec la quantité, si c''est un terrain de base, et le prix le moins cher. '
    'Reconstruite par app.ingestion.deck_profile — ne jamais écrire à la main.';
COMMENT ON COLUMN public.deck_needs.unit_price_eur IS
    'min(card_prints.price_eur) de la carte, ou 0 si aucune impression n''est '
    'cotée. Figé ici pour que le chemin chaud n''ait aucun prix à chercher.';

-- **L''index qui renverse la jointure.** C''est lui qui permet de partir de la
-- collection — quelques centaines de cartes — pour trouver les decks qui les
-- emploient, au lieu de parcourir le corpus entier du format.
CREATE INDEX IF NOT EXISTS idx_deck_needs_oracle
    ON public.deck_needs (oracle_id) WHERE NOT is_basic;

COMMENT ON INDEX public.idx_deck_needs_oracle IS
    'Chemin chaud de deck_suggestions : collection -> decks. Partiel, les '
    'terrains de base n''entrant jamais dans le calcul des manquantes.';

-- ---------------------------------------------------------------------------
-- Ce qu'un deck vaut, indépendamment de qui le regarde.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.deck_profile (
    deck_id        uuid PRIMARY KEY,
    game           text    NOT NULL,
    format         text    NOT NULL,
    total_cards    integer NOT NULL,
    basic_lands    integer NOT NULL,
    total_cost_eur numeric NOT NULL,
    colors         text[]  NOT NULL
);

COMMENT ON TABLE public.deck_profile IS
    'Une ligne par deck : ce qui ne dépend pas d''une collection. Reconstruite '
    'par app.ingestion.deck_profile — ne jamais écrire à la main.';
COMMENT ON COLUMN public.deck_profile.total_cards IS
    'Cartes du board principal HORS terrains de base — c''est le dénominateur '
    'de la complétion, et les terrains ne s''achètent pas.';
COMMENT ON COLUMN public.deck_profile.total_cost_eur IS
    'Ce que coûterait le deck entier au prix le moins cher, terrains de base '
    'exclus. Le coût de complétion s''en déduit en retranchant ce qu''on possède.';
COMMENT ON COLUMN public.deck_profile.colors IS
    'Identité couleur lue sur le deck ENTIER, terrains compris : un deck qui '
    'ne contient de rouge que dans ses Montagnes reste un deck rouge.';

CREATE INDEX IF NOT EXISTS idx_deck_profile_game_format
    ON public.deck_profile (game, format);

-- L'ancienne fonction parcourait `decks` séquentiellement pour y trouver les
-- decks du format — 39 092 lignes à chaque appel. L'index manquait depuis
-- toujours ; il sert aussi la reconstruction.
CREATE INDEX IF NOT EXISTS idx_decks_game_format
    ON public.decks (game, format);

-- ---------------------------------------------------------------------------
-- Droits : catalogue dérivé, donc lecture publique comme ses sources.
-- ---------------------------------------------------------------------------
--
-- `deck_suggestions` est `SECURITY INVOKER` : elle lit ces tables avec les
-- droits de l'appelant. Sans ces `GRANT`, elle rendrait « permission denied »
-- à tout le monde — et la connexion d'ingestion, propriétaire, ne l'aurait pas
-- vu (`CLAUDE.md` §V.4).
GRANT SELECT ON public.deck_needs, public.deck_profile TO anon, authenticated;

ALTER TABLE public.deck_needs   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deck_profile ENABLE ROW LEVEL SECURITY;

CREATE POLICY deck_needs_public_read
    ON public.deck_needs FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY deck_profile_public_read
    ON public.deck_profile FOR SELECT TO anon, authenticated USING (true);

-- ---------------------------------------------------------------------------
-- La fonction, réécrite. Signature et colonnes rendues inchangées.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.deck_suggestions(p_format text, p_max_missing integer DEFAULT 100, p_max_results integer DEFAULT 30, p_max_cost numeric DEFAULT NULL::numeric, p_tier text DEFAULT NULL::text, p_game text DEFAULT 'magic'::text, p_colors text[] DEFAULT NULL::text[], p_banned_colors text[] DEFAULT NULL::text[], p_commander text DEFAULT NULL::text, p_owned_commander boolean DEFAULT false)
 RETURNS TABLE(deck_id uuid, deck_name text, tier text, source_id text, source_name text, attribution text, total_cards integer, owned_cards integer, missing_cards integer, completion real, missing_cost_eur numeric, colors text[], commander_oracle_id uuid, commander_name text, commander_owned boolean, basic_lands integer)
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
    --
    -- **Part de la collection, pas du corpus.** Seuls les decks contenant au
    -- moins une carte possédée sont touchés ; les autres sortiront du LEFT JOIN
    -- ci-dessous avec zéro, ce qui est la vérité sans avoir rien coûté.
    --
    -- `LEAST(needed, owned)` et non `owned` : posséder huit Foudre n'avance pas
    -- un deck qui n'en demande que quatre.
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
               COALESCE(o.owned_cards, 0)                                 AS owned_cards,
               p.total_cards - COALESCE(o.owned_cards, 0)                 AS missing_cards,
               p.total_cost_eur - COALESCE(o.owned_cost_eur, 0)           AS missing_cost_eur
        FROM public.deck_profile p
        LEFT JOIN owned o ON o.deck_id = p.deck_id
        WHERE p.game = p_game
          AND p.format = p_format
          -- Un deck sans une seule carte hors terrains n'a rien à proposer, et
          -- l'ancienne fonction le laissait déjà de côté : sans ce garde-fou il
          -- remonterait en tête, avec zéro carte manquante.
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
           t.basic_lands
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
      -- Recherche par commandant : c'est ainsi qu'on choisit un deck Commander,
      -- en partant du général qu'on veut jouer. Le nom français comme l'anglais.
      AND ((SELECT n FROM wanted) = ''
           OR EXISTS (
                SELECT 1 FROM public.card_search_names s2
                WHERE s2.oracle_id = d.commander_oracle_id
                  AND s2.normalized LIKE '%' || (SELECT n FROM wanted) || '%'
           ))
      AND (NOT p_owned_commander
           OR EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id))
      -- **Voulues** : le deck doit porter toutes ces couleurs. C'est l'inverse
      -- du filtre d'origine, qui demandait qu'il n'en porte aucune autre —
      -- « je veux du rouge » excluait alors tous les bicolores rouges.
      AND (p_colors IS NULL OR cardinality(p_colors) = 0
           OR p_colors <@ t.colors)
      -- **Bannies** : le deck ne doit porter aucune de ces couleurs. Deux
      -- listes valent mieux qu'une : « du rouge, mais pas de bleu » ne
      -- s'exprime pas avec un seul ensemble.
      AND (p_banned_colors IS NULL OR cardinality(p_banned_colors) = 0
           OR NOT (t.colors && p_banned_colors))
    ORDER BY (d.commander_oracle_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM mine m WHERE m.oracle_id = d.commander_oracle_id)) DESC,
             t.missing_cards,
             t.missing_cost_eur,
             d.name,
             -- **Dernier départage, et il ne se retire pas.** Douze decks
             -- Commander partagent nom, commandant, total et coût : sans `id`,
             -- deux appels identiques rendaient deux listes différentes.
             d.id
    LIMIT GREATEST(1, LEAST(p_max_results, 100));
$function$;

COMMENT ON FUNCTION public.deck_suggestions(text, integer, integer, numeric, text, text, text[], text[], text, boolean) IS
    'Decks du corpus confrontés à la collection de l''appelant. Lit deck_needs '
    'et deck_profile, précalculés par l''ingestion : un deck ajouté hors de '
    'app.ingestion.refresh reste invisible jusqu''à la reconstruction suivante.';

COMMIT;
