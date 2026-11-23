-- Deux index pour que l'étagère ne relise plus la table des impressions.
--
-- Suite de 20261123100000_etagere_lecture_par_extension (issue n°52). Le
-- `LATERAL` y lit chaque extension possédée par l'index, mais encore **ligne
-- par ligne dans la table** : la taille de l'extension demande `set_name` et
-- `released_at`, la carte-vedette trie toutes les impressions par prix. Sur la
-- collection de mesure (87 extensions), cela fait 38 304 lignes, réparties sur
-- 6 100 des 6 174 pages de `card_prints` — l'ingestion ne range pas une
-- extension d'un seul tenant. À froid, sous `anon` (3 s), le premier appel
-- tombait encore : 3,4 s.
--
-- **1. Index couvrant (set_code, collector_number) INCLUDE (set_name,
-- released_at)**, qui remplace `idx_card_prints_set` (mêmes clés, donc mêmes
-- usages : `my_collection_summary` s'en sert pareil). La taille d'une
-- extension se lit alors en `Index Only Scan` : 487 pages au lieu de 38 658,
-- **zéro retour à la table** — à la condition que la carte de visibilité soit
-- à jour (voir plus bas).
--
-- **2. Index de la carte-vedette (set_code, price_eur DESC NULLS LAST,
-- collector_number) WHERE art_crop_url IS NOT NULL** : l'ordre exact du
-- `ORDER BY … LIMIT 1` de la fonction, si bien que chaque extension s'arrête à
-- sa première entrée. 348 pages au lieu de 35 115.
--
-- **La carte de visibilité est une condition, pas un détail.** Mesuré le
-- 2026-11-23 : 0 page « toute visible » sur 6 174, sans doute depuis le
-- `VACUUM FULL` de `app.ingestion.jeux_actifs`, qui réécrit la table sans la
-- reconstruire. Sans elle, un `Index Only Scan` retourne quand même à la table
-- pour chaque ligne (38 304 « Heap Fetches »). Un `VACUUM (ANALYZE)` ordinaire
-- l'a rétablie (6 174 / 6 174) ; `jeux_actifs` en lance désormais un après son
-- `VACUUM FULL`, et l'autovacuum l'entretient après chaque ingestion.
--
-- Pas de CONCURRENTLY, comme pour l'index d'origine : la table n'est écrite
-- que par l'ingestion, lancée à la main, et la construction dure quelques
-- secondes sur 176 k lignes.
--
-- Refs : issue n°52 ; 20260824130000_card_prints_set_index (index remplacé).

BEGIN;

CREATE INDEX IF NOT EXISTS idx_card_prints_set_shelf
    ON public.card_prints (set_code, collector_number)
    INCLUDE (set_name, released_at);

COMMENT ON INDEX public.idx_card_prints_set_shelf IS
    'Taille, nom et date d''une extension en Index Only Scan : sert '
    'my_binder_shelf comme my_collection_summary. Remplace idx_card_prints_set '
    '(mêmes clés). Suppose la carte de visibilité à jour.';

CREATE INDEX IF NOT EXISTS idx_card_prints_set_star
    ON public.card_prints (set_code, price_eur DESC NULLS LAST, collector_number)
    WHERE art_crop_url IS NOT NULL;

COMMENT ON INDEX public.idx_card_prints_set_star IS
    'Carte-vedette d''un classeur (my_binder_shelf) : la plus chère illustrée '
    'de l''extension, lue en première entrée de l''index.';

DROP INDEX IF EXISTS public.idx_card_prints_set;

COMMIT;
