-- L'index du chemin chaud devient couvrant
--
-- Suite immédiate de `20260916140000_deck_profile.sql`, et correction d'une
-- mesure qui m'avait trompé.
--
-- **Le banc de la migration précédente était faussement rassurant.** Il
-- mesurait `deck_suggestions` sous le compte propriétaire, dont la collection
-- ne contient **que du Magic** : pour Pokémon, SWU ou Yu-Gi-Oh, la jointure
-- entre la collection et `deck_needs` ne rendait aucune ligne, et le chemin
-- chaud n'était jamais exercé. Les 0,33 s annoncés pour Pokémon mesuraient un
-- travail qui n'avait pas lieu.
--
-- C'est `app.measure.deck_math`, qui *construit* une collection dans le jeu
-- mesuré avant d'interroger, qui l'a révélé : `HTTP 500` sur Pokémon, là où le
-- banc de durée passait.
--
-- **Ce que coûte réellement le chemin chaud**, avec une collection contenant
-- les N cartes les plus jouées du format — le pire cas réaliste, un joueur
-- possédant d'abord les cartes courantes :
--
--     jeu/format          cartes possédées    blocs touchés
--     pokemon/standard              200         2 575 188
--     pokemon/standard              600         2 872 452
--     swu/premier                   600           904 580
--     yugioh/edison                 600           927 051
--
-- Trois millions de blocs pour un million de lignes : l'index sur `oracle_id`
-- donnait bien les lignes, mais chacune obligeait à retourner au tas chercher
-- `needed` et `unit_price_eur`, dispersés. Un accès aléatoire par ligne, sur un
-- serveur qui n'a que 224 Mio de cache pour 554 Mo de base — donc une éviction
-- de tout le reste au passage.
--
-- **Avec l'index couvrant**, les mêmes cas :
--
--     pokemon/standard              200           160 194     (×16)
--     pokemon/standard              600           169 476     (×17)
--     swu/premier                   600           240 164      (×3,8)
--     yugioh/edison                 600           165 363      (×5,6)
--
-- `INCLUDE` plutôt que des colonnes de clé : `needed` et `unit_price_eur` ne
-- servent jamais à chercher, seulement à lire. Les mettre dans la clé
-- gonflerait les nœuds internes de l'arbre sans rien accélérer.
--
-- **Le prix est 62 Mo d'index** contre 9,9 Mo pour le simple, qui est donc
-- retiré — il ne sert plus rien que le couvrant ne serve mieux. Net : +52 Mo
-- sur une base de 554 Mo. C'est cher, et c'est le bon échange : ces 52 Mo
-- évitent de traverser deux gigaoctets de tas à chaque ouverture de l'onglet.
--
-- Vérifié après coup par `app.measure.deck_math`, qui recompte de son côté
-- depuis `deck_cards` et `collection_items` : « aucun écart » sur 100 decks
-- pour pokemon/standard, swu/premier, yugioh/edison et riftbound/constructed.
--
-- Pas de CONCURRENTLY : `deck_needs` n'est écrite que par l'ingestion, lancée à
-- la main, et l'index se bâtit en trois secondes. Même arbitrage que
-- `20260824130000_card_prints_set_index.sql`.

BEGIN;

CREATE INDEX IF NOT EXISTS idx_deck_needs_oracle_couvrant
    ON public.deck_needs (oracle_id, deck_id)
    INCLUDE (needed, unit_price_eur)
    WHERE NOT is_basic;

COMMENT ON INDEX public.idx_deck_needs_oracle_couvrant IS
    'Chemin chaud de deck_suggestions : collection -> decks, en parcours '
    'd''index seul. Les colonnes INCLUDE evitent le retour au tas, qui coutait '
    'trois millions de blocs sur le corpus Pokemon.';

-- Superseded : le couvrant repond a tout ce que celui-ci repondait.
DROP INDEX IF EXISTS public.idx_deck_needs_oracle;

COMMIT;
