-- 045 — Les extensions comme objets, et la couverture d'un classeur.
--
-- **Le bundle officiel n'existe dans aucune source exploitable.** La fiche
-- complète d'une extension chez Scryfall ne porte qu'un seul visuel :
-- `icon_svg_uri`, le symbole imprimé sur chaque carte. Ni boîte, ni display, ni
-- illustration promotionnelle. Ces photos-là appartiennent aux marchands ou à
-- Wizards, n'ont pas d'API, et leur reprise automatisée contredirait les
-- garde-fous du projet. Le symbole officiel est donc ce qui s'en approche le
-- plus — et il a l'avantage d'être *le* marqueur que tout joueur reconnaît.
--
-- **Pourquoi une table, alors que le projet préfère déduire.** L'URL du symbole
-- ressemble à `svgs.scryfall.io/sets/<code>.svg`, ce qui invitait à la déduire
-- du code d'extension comme `fullCardImage` déduit la carte de son
-- illustration. Mesuré sur les 1 047 extensions du catalogue Scryfall :
--
--   * 342 seulement (32,7 %) ont une icône nommée d'après leur propre code ;
--   * 182 de plus suivent la règle « `t` + code parent » (les extensions de
--     jetons empruntent le symbole de leur extension mère : `tmsh` → `msh`) ;
--   * **523 restent arbitraires** — `pl26` → `star`, `amsh` → `msh`,
--     `ysos` → `y26`.
--
-- La déduction échouait donc deux fois sur trois, et sur la collection réelle
-- elle échouait sur deux classeurs sur cinq, les extensions de jetons y pesant
-- lourd. La table est la bonne réponse : 1 047 lignes, une requête d'ingestion,
-- et l'affaire est close.
--
-- **La couverture change de nature.** Elle montrait la plus chère carte qu'on
-- possède — un choix personnel. Elle montre désormais la **carte-vedette de
-- l'extension** : la plus chère du set entier, celle qui figure sur les visuels
-- du produit. Un classeur s'identifie ainsi comme un produit, pas comme un
-- inventaire, et deux personnes qui possèdent la même extension la
-- reconnaissent à la même image. Mesuré : `msh` → The Mind Stone (32,67 €),
-- `msc` → Loki, Lord of Misrule (39,69 €), `mar` → Roaming Throne (32,36 €) —
-- les mythiques emblématiques de chaque sortie.
--
-- `my_binder_shelf` gagne une colonne et doit donc être supprimée d'abord.

BEGIN;

-- ---------------------------------------------------------------------------
-- Les extensions
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.card_sets (
    code            text PRIMARY KEY,
    -- Le catalogue est cloisonné par jeu partout ailleurs ; les extensions ne
    -- font pas exception, même si Riftbound n'en publie pas encore.
    game            text NOT NULL DEFAULT 'magic',
    name            text NOT NULL,
    set_type        text,
    -- Une extension de jetons pointe son extension mère. Conservé parce que
    -- c'est la seule chose qui explique pourquoi deux codes partagent un
    -- symbole, et parce qu'aucune règle de nommage ne le rattrape.
    parent_set_code text,
    released_at     date,
    card_count      integer,
    icon_svg_uri    text,
    updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.card_sets IS
    'Les extensions telles que Scryfall les publie. Existe pour `icon_svg_uri` '
    '— le symbole officiel, dont l''URL ne se déduit pas du code : mesuré, '
    '32,7 % seulement des 1 047 extensions ont une icône homonyme.';
COMMENT ON COLUMN public.card_sets.icon_svg_uri IS
    'Symbole officiel, SVG monochrome d''environ 1 Ko servi avec '
    '`access-control-allow-origin: *` — donc utilisable depuis le web.';

CREATE INDEX IF NOT EXISTS idx_card_sets_game ON public.card_sets (game);

ALTER TABLE public.card_sets ENABLE ROW LEVEL SECURITY;

-- Même régime que le reste du catalogue : lisible par tous, écrit par la seule
-- ingestion, qui passe par la clé de service et court-circuite la RLS.
DROP POLICY IF EXISTS card_sets_public_read ON public.card_sets;
CREATE POLICY card_sets_public_read
    ON public.card_sets FOR SELECT TO anon, authenticated USING (true);

-- ---------------------------------------------------------------------------
-- L'étagère : symbole officiel et carte-vedette
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.my_binder_shelf(text);

CREATE FUNCTION public.my_binder_shelf(
    p_game text DEFAULT 'magic'
)
RETURNS TABLE (
    set_code     text,
    set_name     text,
    released_at  date,
    total_cells  integer,
    owned_cells  integer,
    owned_copies integer,
    art_crop_url text,
    icon_svg_uri text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
    WITH mine AS (
        SELECT p.set_code,
               p.collector_number,
               SUM(i.quantity)::integer AS copies
        FROM public.collection_items i
        JOIN public.collections c ON c.id = i.collection_id
        JOIN public.card_prints p ON p.scryfall_id = i.print_id
        JOIN public.cards ca ON ca.oracle_id = i.oracle_id AND ca.game = p_game
        WHERE c.owner_id = auth.uid()
        GROUP BY p.set_code, p.collector_number
    ),
    owned AS (
        SELECT m.set_code,
               COUNT(*)::integer      AS cells,
               SUM(m.copies)::integer AS copies
        FROM mine m
        GROUP BY m.set_code
    ),
    -- La taille d'un classeur est celle de l'édition entière, pas de ce qu'on
    -- en possède : c'est ce qui rend le taux de complétion lisible.
    sizes AS (
        SELECT p.set_code,
               MIN(p.set_name)                            AS set_name,
               MIN(p.released_at)                         AS released_at,
               COUNT(DISTINCT p.collector_number)::integer AS total
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT o.set_code FROM owned o)
        GROUP BY p.set_code
    ),
    -- **La carte-vedette de l'extension**, et non la plus chère qu'on possède :
    -- un classeur s'identifie comme un produit, pas comme un inventaire. Le
    -- prix se lit sur `card_prints` sans repli linguistique, à dessein — la
    -- version anglaise porte la cote, la française porte la même illustration,
    -- et c'est l'illustration qu'on cherche ici.
    --
    -- Une extension de jetons n'a aucune cote : la première case fait alors une
    -- couverture stable, là où l'ordre du moteur en changerait à chaque appel.
    star AS (
        SELECT DISTINCT ON (p.set_code)
               p.set_code,
               p.art_crop_url
        FROM public.card_prints p
        WHERE p.set_code IN (SELECT o.set_code FROM owned o)
          AND p.art_crop_url IS NOT NULL
        ORDER BY p.set_code,
                 p.price_eur DESC NULLS LAST,
                 p.collector_number
    )
    SELECT s.set_code,
           s.set_name,
           s.released_at,
           s.total,
           o.cells,
           o.copies,
           st.art_crop_url,
           cs.icon_svg_uri
    FROM sizes s
    JOIN owned o ON o.set_code = s.set_code
    LEFT JOIN star st ON st.set_code = s.set_code
    LEFT JOIN public.card_sets cs ON cs.code = s.set_code
    -- Le classeur le plus rempli d'abord : c'est celui qu'on vient regarder.
    ORDER BY o.cells DESC, s.set_code;
$$;

COMMENT ON FUNCTION public.my_binder_shelf(text) IS
    'Éditions dont au moins une carte est possédée, avec la taille du classeur, '
    'ce qui y est rangé, l''illustration de la carte-vedette de l''extension et '
    'son symbole officiel — une étagère de noms ne se distingue pas.';

GRANT EXECUTE ON FUNCTION public.my_binder_shelf(text) TO anon, authenticated;

COMMIT;
