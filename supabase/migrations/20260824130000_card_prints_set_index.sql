-- Un index sur l'extension, parce que compter les cases d'un classeur balayait
-- les 245 468 impressions.
--
-- Motivation : mesure sous le role `authenticated`, page de profil, collection
-- reelle — 7,85 s a froid, quand le role coupe a 8 s. Une fois les pages en
-- cache, 0,55 s. Autrement dit : la fonction PASSAIT en repetant la mesure, et
-- serait tombee au premier appel apres un redemarrage du serveur.
--
-- Cause : `card_prints` ne portait aucun index sur `set_code`. Toute requete de
-- la forme
--
--     SELECT set_code, COUNT(DISTINCT collector_number)
--     FROM public.card_prints
--     WHERE set_code IN (...)
--     GROUP BY set_code
--
-- faisait un parcours sequentiel complet — pour n'en garder que cinq
-- extensions.
--
-- **Le defaut n'est pas neuf, et il ne concernait pas que le profil.**
-- `my_binder_shelf` fait exactement ce calcul depuis toujours pour rendre le
-- taux de completion de chaque classeur : l'etagere payait le meme parcours
-- sans que personne l'ait mesuree. Cet index la sert aussi.
--
-- L'index est COMPOSITE (set_code, collector_number) et non sur `set_code`
-- seul : le COUNT(DISTINCT collector_number) se sert alors directement du
-- second membre, sans retourner a la table.
--
-- Pas de CONCURRENTLY : la table n'est ecrite que par l'ingestion, lancee a la
-- main, et le verrou dure le temps d'une construction sur 245 k lignes. Le
-- garder dans la transaction vaut mieux qu'un index a moitie construit.
--
-- Refs: page de profil, indicateurs defilants

BEGIN;

CREATE INDEX IF NOT EXISTS idx_card_prints_set
    ON public.card_prints (set_code, collector_number);

COMMENT ON INDEX public.idx_card_prints_set IS
    'Taille et cases d''une extension : sert my_binder_shelf comme '
    'my_collection_summary. Sans lui, les deux balaient la table entiere.';

COMMIT;
