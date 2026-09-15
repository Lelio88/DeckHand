-- Retirer de l'index d'empreintes les cartes de la série illustrée.
--
-- **Elles sont au catalogue, et c'est voulu** : une carte art series se tient
-- en main et se range dans un classeur (§I). Mais elles reprennent
-- l'illustration de la vraie carte, donc son empreinte — recopiée par
-- `propagate_shared_art`. Mesuré avant ce fichier : 2 487 empreintes pour
-- 2 243 cartes art series, dont 2 140 identiques à celle d'une carte ordinaire.
--
-- **Ce que cela coûtait.** Le scan ne propose une carte sans réserve que si la
-- candidate suivante est au moins 4 bits plus loin (`minConfidenceMargin`). À
-- empreinte identique, l'écart tombe à zéro : l'illustration seule ne suffisait
-- plus à reconnaître la vraie carte, et l'ordre de l'index décidait laquelle
-- des deux venait en tête.
--
-- `index_builder` ne les hache ni ne les propage plus ; ce fichier efface ce qui
-- était déjà là. Ce sont des données dérivées, recalculables. `art_hash_count`
-- baisse d'autant, ce qui signale aux applications que leur index local est
-- périmé.

BEGIN;

DELETE FROM public.art_hashes h
USING public.cards c
WHERE c.oracle_id = h.oracle_id
  AND c.layout = 'art_series';

COMMIT;
