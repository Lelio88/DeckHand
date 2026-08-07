-- 018 — Les sigles pointés deviennent cherchables sous leur forme parlée.
--
-- « Agents du S.H.I.E.L.D. » se normalise en « agents du s h i e l d » : les
-- points font office de séparateurs, et le sigle éclate en huit lettres isolées.
-- Or personne ne dicte ni ne tape « s point h point i point e point l point d ».
-- On dit « shield », qui ne ressemble alors plus à rien — la recherche floue
-- répondait « Wingshield Agent », seule carte du catalogue à contenir ce mot.
--
-- Le défaut touche toute la vague Marvel (S.H.I.E.L.D., A.I.M., E.G.O.) et les
-- cartes anciennes du même genre. Il est d'autant plus vicieux que la recherche
-- rend un résultat plausible au lieu d'échouer franchement.
--
-- La correction ajoute une **seconde entrée d'index** par nom concerné, points
-- supprimés au lieu d'être remplacés. Les deux formes coexistent : « s.h.i.e.l.d. »
-- tapé au clavier continue de fonctionner, « shield » aussi désormais.
--
-- Pas de réingestion nécessaire : l'index de saisie se dérive de lui-même.

BEGIN;

INSERT INTO public.card_search_names (oracle_id, name, normalized, lang)
SELECT s.oracle_id,
       s.name,
       public.normalize_card_name(replace(s.name, '.', '')),
       s.lang
FROM public.card_search_names s
-- Un point suivi d'une lettre : c'est la signature d'un sigle, pas d'une fin de
-- phrase. Restreindre ainsi évite de dupliquer tout le catalogue.
WHERE s.name ~ '\.[[:alpha:]]'
  AND public.normalize_card_name(replace(s.name, '.', ''))
      <> public.normalize_card_name(s.name)
ON CONFLICT (oracle_id, normalized, lang) DO NOTHING;

COMMIT;
