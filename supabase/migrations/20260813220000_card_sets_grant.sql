-- 046 — Le droit de lire `card_sets`, oublié à sa création.
--
-- **Une policy n'est pas un droit.** La migration 045 a activé la RLS sur
-- `card_sets` et écrit la politique de lecture publique, mais pas le `GRANT
-- SELECT`. Ce sont deux couches distinctes de Postgres : le GRANT dit qui peut
-- toucher la table, la policy dit quelles lignes il verra. Sans le premier, la
-- seconde ne s'applique jamais — le rôle est refusé avant qu'on parle de
-- lignes.
--
-- Conséquence vécue : l'étagère de classeurs ne chargeait plus, `my_binder_shelf`
-- étant `SECURITY INVOKER` et échouant sur « permission denied for table
-- card_sets » dès sa première instruction. La collection entière était
-- inaccessible pour une colonne décorative.
--
-- **Pourquoi cela n'a pas été vu plus tôt** : les vérifications passaient par la
-- connexion d'ingestion, propriétaire de la base, qui contourne GRANT et RLS
-- l'un comme l'autre. Une mesure faite sous le rôle `authenticated` l'aurait
-- montré tout de suite — c'est le rôle sous lequel l'application parle.
--
-- Le reste du catalogue (`cards`, `card_prints`, `card_search_names`) porte ce
-- GRANT depuis le schéma initial ; `card_sets` rejoint simplement la règle.

BEGIN;

GRANT SELECT ON public.card_sets TO anon, authenticated;

COMMIT;
