# Multi-jeu — accueil des jeux qui ne sont pas Magic

Annexe de [`architecture.md`](./architecture.md). Trois jeux partagent
aujourd'hui la base de DeckHand : **Magic**, **Riftbound** (le TCG League of
Legends de Riot) et **Yu-Gi-Oh**. Ce document dit ce que chacun a demandé, et ce
que le modèle a absorbé sans se déformer.

---

## 0. Yu-Gi-Oh — 13 866 cartes, et presque rien à inventer

**Ce jeu a coûté moins cher que Riftbound**, et l'écart tient entièrement à la
source. Tout ce qui suit est relevé sur les données, pas repris d'une
documentation.

| | Riftbound | Yu-Gi-Oh |
|---|---|---|
| Catalogue | 15 requêtes paginées | **un seul appel**, 21 Mo, 14 491 cartes |
| Identité | UUIDv5 dérivés du triplet nom + type + texte | **le passcode imprimé sur la carte**, unique sur 14 491 |
| Homonymes | 80 noms pour 161 cartes | **aucun** |
| Langues | anglais seul | **anglais et français**, liés par `name_en` |
| Gabarit d'illustration | 3 méthodes, 2 échecs | **recoupement exact**, la source publiant carte entière *et* illustration détourée |

**Le nom redevient la voie principale.** Riftbound doit passer par
l'illustration : ses 80 homonymes ont des lignes de type identiques, le nom ne
peut pas les départager, et Riot ne sert que l'anglais alors que la
reconnaissance lit un carton français. Yu-Gi-Oh n'a ni l'un ni l'autre problème
— zéro homonyme, et 11 504 noms français sur 13 866. Il rejoint donc Magic : le
nom d'abord, l'illustration en appoint.

### Deux gabarits, et le discriminant est un contrat

Mesurés par recoupement — chercher, dans la carte entière, la région qui
reproduit l'illustration détourée que la même source publie :

- **cadre ordinaire** (0,1181 · 0,1823 · 0,8807 · 0,7055), sur 20 cartes tirées
  dans dix familles : **la même fenêtre à 0,001 près**, écart résiduel de
  1 niveau de gris sur 255 ;
- **cartes Pendulum** (0,0615 · 0,1789 · 0,9360 · 0,6238), 390 cartes soit
  2,7 % : leur illustration déborde pour laisser place aux deux échelles
  latérales. Mesuré sur 18 cartes des six sous-familles, stable à 0,001 près.

**Le choix entre les deux ne se devine pas** : `frameType` porte « pendulum »
pour ces cartes et pour elles seules. C'est ce qui sépare ce jeu de Pokémon
(#28), dont le seul discriminant disponible est la rareté — quarante valeurs qui
ont changé plusieurs fois en vingt-sept ans.

**La première mesure a échoué, et son échec instruit.** Elle cherchait un carré,
parce que l'illustration détourée des cartes ordinaires en est un (624 × 624).
Pour une Pendulum, la source publie 712 × 908 : non pas l'illustration, mais
l'illustration **plus le pavé de texte**. Chercher un carré ne pouvait rien
trouver, et les écarts sont passés de 1 à 50. C'est pourquoi l'index découpe
lui-même la carte entière au lieu de faire confiance au recadrage publié — un
seul chemin, exactement celui que l'application suivra sur une photo.

### Le format du carton, enfin éprouvé

Yu-Gi-Oh est le **premier jeu couvert qui n'imprime pas en 63 × 88 mm** : son
carton fait 59 × 86, et le paramétrage introduit par #24 cesse donc d'être
théorique. La question que ce chantier laissait ouverte — un rendu de source
s'aligne-t-il sur le carton ? — est tranchée : **813 × 1185, soit 0,6861**,
contre 0,68605 pour 59 × 86. À un dix-millième près.

### Ce qui n'entre pas au catalogue

- les **124 *Skill Cards***, qui appartiennent au jeu vidéo Duel Links — la
  source rend d'ailleurs 404 sur leur illustration détourée ;
- les **501 cartes sans aucune impression**, jamais parues hors de l'anime.

Les deux ensembles se recoupent : 13 866 cartes sur 14 491 sont retenues. Les
garder ferait espérer des cartes qu'aucune boutique ne vend et qu'aucun classeur
ne rangera.

### Trois pièges relevés sur les données

**La rareté fait partie de l'identité d'une impression.** 44 287 impressions pour
38 297 codes distincts : une même carte paraît dans une même extension sous
plusieurs raretés. Sans la rareté dans la clé, la Starlight Rare et la Super Rare
de « Justice Hunters » s'écraseraient l'une l'autre, et la collection perdrait la
version réellement possédée — celle qui porte la valeur.

**« Spell » attrape 700 monstres.** Le filtre de recherche est un `ILIKE` sur la
ligne de type entière, et la famille *Spellcaster* le contient. Le type déclaré
est donc « Spell Card », qui est aussi le vocabulaire officiel du jeu. Mesuré
après correction : 2 801 résultats, soit exactement le nombre de magies.

**Les impressions listées sont anglaises** — 38 590 codes `XXXX-EN###` contre
456 `PT` et 4 `SE`. Les éditions françaises existent en carton mais ne figurent
pas au catalogue : `card_prints` porte les impressions anglaises, et le français
vit dans `card_search_names`, qui est fait pour ça.

### Les prix : le piège du catalogue

**La source cote ses cartes, et il a fallu refuser ses prix.** YGOPRODeck sert un
`cardmarket_price` sur 96,6 % des cartes, en euros — de quoi croire qu'on ferait
l'économie de TCGCSV et de la conversion BCE. Mesuré, le *Magicien Sombre* y
vaut **0,02 €**, et le *Dragon Blanc aux Yeux Bleus* autant, quand leurs
impressions se vendent de 7 à 74 $.

Ce n'est pas un prix de marché : c'est le **plancher**, la plus basse annonce
toutes impressions confondues. Sur les 12 352 impressions où les deux chiffres
existent, le prix par impression vaut **20 fois** le prix par carte en médiane —
et cet écart **ne dépend pas de la rareté** (18 pour les Common, 27 pour les
Secret Rare), ce qui exclut l'explication naturelle. La règle du projet tranche :
`marketPrice` et non `lowPrice`, faute de quoi les totaux de deux jeux ne se
comparent plus.

**Le rapprochement est un identifiant composite, pas une ressemblance.**
Riftbound se lie par `tcgplayer_id` ; YGOPRODeck n'en sert aucun. Mais TCGplayer
publie le numéro d'impression et la rareté, et le catalogue porte les mêmes :
« LOB-005 · Ultra Rare » désigne une et une seule impression. Le catalogue écrit
`LOB-EN005` là où TCGplayer écrit `LOB-005` — sans cette normalisation, **aucune**
carte ne serait cotée, et l'échec serait muet.

Mesuré sur douze extensions tirées au hasard : **79 % des produits TCGplayer**
trouvent leur impression, et **99,7 % de celles-ci portent un prix de marché**.

**Les éditions ne sont pas des finitions.** TCGplayer sépare `1st Edition`,
`Unlimited` et `Limited` là où Magic sépare ordinaire et brillante. Le modèle
n'en porte qu'une : `price_usd` reçoit l'édition courante — `Unlimited` d'abord,
`1st Edition` à défaut —, et `price_usd_foil` reste vide. Écrire la première
édition dans une colonne nommée « foil » ferait passer une édition rare pour une
brillante, ce qu'aucun écran ne saurait détromper ; la retenir par défaut aurait
gonflé la valeur d'une collection ordinaire d'un facteur quatre sur les cartes
mesurées. La distinction 1re édition / illimitée n'est donc pas modélisée — perte
réelle, du même ordre que les 493 impressions Riftbound cotées seulement en
brillante, et écrite plutôt que tue.

### Le volume a changé une manière de faire

C'est le seul endroit où ce jeu a demandé autre chose. Riftbound écrit ses 1 451
impressions une par une sans que cela se remarque ; à **44 139**, un aller-retour
par ligne vers une base distante porte l'ingestion à plusieurs dizaines de
minutes. `executemany` les regroupe : **29 secondes** pour le catalogue entier,
impressions et noms des deux langues compris.

### Vérifié sous le rôle qui subira les règles

Dans une transaction annulée, sous `authenticated` : `search_cards('dark
magician', 'yugioh')` rend les cinq Magiciens Sombres avec leurs lignes de type ;
`search_cards('magicien sombre', 'yugioh')` rend les mêmes cartes par leur nom
français ; le filtre « Spell Card » sur « dragon » ne rend que des magies ; et la
même requête en Magic ne rend aucune carte Yu-Gi-Oh — le cloisonnement tient.

### Le corpus de decks — le format qui porte le nom du jeu ne porte pas ses listes

`api/app/ingestion/topdeck_ingest.py --yugioh` — **3 935 decks** en quatre
formats, sur la fenêtre d'un an.

**Deux pièges, et le premier fait conclure à tort.** Le jeu s'écrit `Yu-Gi-Oh`,
**sans point d'exclamation** : avec le point, l'API rend `200` et une liste
**vide**, sans erreur ni message — comme le font `Yugioh`, `YuGiOh` et `YGO`. On
en conclurait que TopDeck.gg ne couvre pas le jeu, alors qu'il en sert 396
tournois.

Le second est que `Advanced`, le format de tournoi **courant**, n'a que **3
decklists sur 168 tournois**. Le corpus est ailleurs :

| Format | Tournois | Decklists |
|---|---|---|
| **Edison** | 186 | **3 069** |
| **Goat** | 24 | **485** |
| **REDU** | 11 | **320** |
| **HAT** | 3 | **81** |
| Advanced | 168 | 3 |

C'est une bonne nouvelle et non un manque : un format rétro puise dans un pool
**figé et ancien**, donc des cartes disponibles et bon marché, là où un format
courant demande les raretés récentes que personne ne possède par accident. C'est
le raisonnement même qui fait du Pauper le format prioritaire de Magic, et il
vaut ici sans transposition. `deckFormatsFor(Game.yugioh)` rendait `Advanced`,
déclaré **sur la foi du nom** ; il rend désormais Edison, Goat, REDU, HAT.

**L'identité est celle du carton.** Chaque entrée d'une decklist porte le
*passcode* à huit chiffres — celui dont le catalogue dérive déjà ses `oracle_id`.
La résolution est donc un calcul, pas une recherche : **99,94 %** des citations
se résolvent, et zéro homonyme rend l'opération sûre. Mesuré, la résolution par
nom donne exactement le même taux ; le passcode l'emporte parce qu'il ne dépend
d'aucune langue de saisie.

**Trois défauts qui ne lèvent rien, tous mesurés** — le dernier ne concernant
pas Yu-Gi-Oh mais découvert en l'accueillant :

- **Les libellés de zone sont saisis à la main.** Lire les seuls `Deck`, `Extra`
  et `Side` coûte **305 decks sur 3 946** — dont 265 qui écrivent `#main`,
  `!side` et `#extra`, et quelques-uns `Deck - 41 Cards` ou `extra deck:15`. Rien
  n'aurait échoué : leur pan principal serait resté vide, ils auraient été
  comptés « écartés » et le corpus aurait paru plus petit. La normalisation ne
  garde que les lettres, et cherche `extra` et `side` **avant** `deck` — les deux
  contiennent « deck », et l'ordre inverse verserait l'Extra dans le principal.
- **Une carte rééditée reçoit un second passcode.** Monster Reborn est `83764719`
  au catalogue et `83764718` en illustration alternative ; les decklists citent
  l'un ou l'autre. 21 cartes étaient introuvables — Monster Reborn, Cyber Dragon,
  Foolish Burial, rien d'exotique —, touchant **97 decks sur 3 950**, dont 93
  seraient passés sous le seuil de tolérance et auraient été enregistrés
  **amputés**, donc annoncés plus complets qu'ils ne sont. Un appel groupé rend
  leur nom canonique, qui se résout contre le catalogue ; 10 des 21 sont ainsi
  récupérés, les 11 autres étant inconnus de la source elle-même.
- **L'index de noms est partagé par les trois catalogues**, et **227 noms
  normalisés sont portés par plusieurs jeux** : « Blizzard », « Backfire »,
  « Change of Heart », « Apprenti sorcier ». L'import Magic chargeait l'index
  entier — un deck citant l'un de ces noms recevait l'une ou l'autre carte selon
  l'ordre des lignes rendues par la base. Aucun deck n'est touché : les listes
  Magic ont été importées avant que la table ne soit partagée. `load_name_index`
  prend désormais un jeu, et les deux appels le passent.

**Le seuil vient du trou dans la distribution, pas des règles.** Les tailles
observées sont : 1 carte (9 listes), puis **rien entre 2 et 37**, puis 38 (1),
39 (4), 40 (2 326), 41 (1 112)… Le seuil se pose dans ce vide, à **30** : il
écarte les listes enregistrées à moitié et garde les cinq decks à 38 ou 39
cartes, que la règle des quarante aurait jetés sans rien gagner.

**L'Extra Deck compte dans la complétion, le Side non.** On ne joue pas sans
l'Extra, et il porte quinze cartes en médiane — autant que la réserve. Le mode du
pan principal enregistré est donc **55 cartes** (40 + 15), sur 1 992 decks.

`decks.format` accueille `edison`, `goat`, `redu` et `hat` (migration
`20260816130000`). `DeckBlueprint.of` continue de rendre `null` : le corpus
existe désormais, mais le gabarit reste à mesurer — le déclarer d'avance referait
l'erreur que le choix du format a déjà coûtée à ce jeu.

### Vérifié sous le rôle qui subira les règles (decks)

Sous `authenticated`, `deck_suggestions(p_game => 'yugioh')` rend des decks pour
les quatre formats, avec leur coût de complétion valorisé (16,20 € pour la
première liste Edison). Aucune carte d'un autre jeu n'est entrée dans un deck
Yu-Gi-Oh — vérifié par jointure, zéro ligne.

**Le corpus et les prix se rejoignent** : 1 555 des 1 562 cartes citées par ces
decks portent un prix, soit **99,6 %**. Le coût de complétion est donc chiffrable
pour presque toute liste — c'est la promesse du produit, pas un chiffre
d'agrément.

**Ce qui reste dû** : l'index d'empreintes est plein, les prix et les decks sont
en base ; il manque **une carte de papier**. Aucune carte Yu-Gi-Oh n'a encore été
photographiée — c'est le même verrou que Riftbound a mis longtemps à lever.

---

## Riftbound

Riftbound, le jeu de cartes physique League of Legends de Riot, partage la base
de DeckHand avec Magic.

**Ce qui est en place** : le catalogue est ingéré — 1 234 cartes distinctes,
1 451 impressions, 1 234 noms indexés — et cloisonné par `cards.game`. La
recherche ne mêle jamais les deux jeux.

**Les gabarits d'illustration sont mesurés** : (0,065 · 0,047 · 0,934 · 0,517)
pour les cartes verticales, (0,041 · 0,199 · 0,962 · 0,777) pour les 64 champs
de bataille horizontaux. Deux méthodes fondées sur la variance ont échoué avant
qu'une troisième, fondée sur la luminosité de l'image moyenne, n'aboutisse : le
cadre y est sombre, l'illustration en tons moyens, les pavés de texte quasi
blancs. Les
gabarits sont cloisonnés par jeu — essayer un cadre Magic sur une carte
Riftbound doublerait le calcul et le risque de correspondance fortuite.

**Le jeu saisi décide des gabarits, du sélecteur jusqu'au découpage.** Marquer
les cadres par jeu ne suffit pas : encore faut-il que la reconnaissance demande
ce filtrage. `ScanService` porte donc le jeu et le transmet à `artHashCandidates`,
au même titre que `artHashIndexProvider` le transmet au téléchargement de
l'index. Les deux viennent de `selectedGameProvider`, et c'est ce qui garantit
qu'on ne cherche pas dans l'index d'un jeu une empreinte découpée au cadre de
l'autre — une carte reste alors introuvable pour une raison qui n'a rien à voir
avec la qualité du gabarit, ce qui est le pire des diagnostics.

**Et il décide aussi du format du carton.** Le rapport largeur sur hauteur était
écrit en dur neuf fois, toujours à 63 × 88 mm : invisible tant que les deux jeux
couverts impriment sur le même carton — Riftbound y compris, à un millième près.
Il est désormais une propriété du jeu (`card_geometry.dart`, jumelé côté Python,
parité verrouillée par un test qui relit le fichier Dart). Ce n'est pas le
contrôle d'aspect qui était en jeu, sa tolérance étant vingt fois plus large que
l'écart attendu, mais le **cadrage de repli** et le **cadre imposé à
l'utilisateur** — les deux endroits sans tolérance, détaillés dans
[`architecture.md`](./architecture.md) § « Le format d'une carte dépend du
jeu ». C'est le préalable de tout jeu qui n'imprime pas en 63 × 88, à commencer
par Yu-Gi-Oh.

**Le gabarit vertical est éprouvé sur une carte de papier.** C'est ce que #4 et
#5 attendaient, et la réponse est bonne : photographiée à main levée sur une
table éclairée de côté, une carte française (*Archer du Val gelé*, UNL 65) place
son homologue du catalogue (*Icevale Archer*) **au rang 1 sur 1 035, à 7 bits**,
avec 10 bits de marge sur le suivant. Les proportions mesurées sur des rendus
numériques survivent donc à une photo réelle — le précédent Magic laissait
craindre l'inverse.

Il a fallu corriger la détection de bords pour y arriver : la même photo la
plaçait d'abord au rang 146, à 28 bits, `findCard` rendant alors un
quadrilatère couvrant 99,5 % de l'image quand la carte n'en occupe que 50 %.
Le défaut n'était ni dans le gabarit ni dans l'empreinte, et il n'avait rien de
propre à ce jeu — c'est un seuillage global sur une scène à éclairage inégal,
détaillé dans [`architecture.md`](./architecture.md) § « Ce que ce banc ne
voyait pas ».

**Le second gabarit sert enfin.** `findCard` ne retenait un quadrilatère que si
son rapport approchait celui d'une carte verticale à 0,30 près ; un champ de
bataille s'en écarte de 0,68 et était rejeté, la reconnaissance retombant sur un
découpage vertical pris de travers. Mesuré sur le catalogue, une carte couchée
fait 1039 × 744 — rapport 1,397, exactement l'inverse de 0,716 : ce n'est pas un
autre format, c'est la même carte tournée d'un quart de tour.

La détection accepte donc les deux orientations, **pour les seuls jeux qui en
ont une** — l'ouvrir à Magic reviendrait à accepter n'importe quel rectangle.
Mesuré au banc sur un tirage de cartes couchées, huit régimes : **96 photos
reconnues sur 96**, médianes de 1 à 3 bits et aucun abandon, contre **0 sur 96**
et 96 abandons auparavant. Magic est inchangé, au bit près.

Reste à l'éprouver sur du carton : aucun champ de bataille physique n'a encore
été photographié.

**L'index d'empreintes est construit** : 1 193 empreintes pour 1 035 cartes,
aucun échec de téléchargement, et **aucune carte sans empreinte**. Les 17 cartes
qui n'en avaient pas — leur illustration étant partagée avec une autre carte,
qui l'avait hachée la première — en ont reçu une par `propagate_shared_art` :
leur donner la même empreinte est la bonne sémantique, ces cartes étant
visuellement identiques, et le scan doit les proposer toutes plutôt que
d'inventer une distinction que l'image ne porte pas.

**Les 80 homonymes sont séparables par l'illustration** — vérifié, pas espéré.
Quatre-vingts noms Riftbound sont portés par plusieurs cartes réellement
différentes (161 cartes), et leur ligne de type est identique dans **tous** les
cas : le nom et le type ne peuvent pas les départager. Leurs empreintes, elles,
sont distinctes dans les 80 cas — **zéro collision**. La voie choisie pour ce
jeu peut donc faire le travail qu'on lui demande.

**Et il est servi par jeu.** `art_hash_page` rendait les 50 209 empreintes des
deux catalogues, quel que soit le jeu choisi : en Riftbound, cinquante
allers-retours réseau pour 1 193 empreintes utiles. Ce n'était pas qu'un
gaspillage. **379 empreintes Riftbound tombent à moins de 12 bits d'une
empreinte Magic** — sous le seuil de confiance de la reconnaissance —, si bien
qu'une carte Magic photographiée pouvait se voir répondre une carte de l'autre
jeu, ou perdre la marge de 4 bits qui autorise à trancher. Le filtre se fait par
jointure sur `cards.game`, non par un artefact découpé à la génération : la base
sait déjà à quel jeu appartient chaque empreinte, et une jointure ne peut pas se
désynchroniser du catalogue. Le cache local garde **les deux** index, la mémoire
un seul : basculer d'un jeu à l'autre ne retélécharge rien.

**Chaque impression porte son `tcgplayer_id`** — 1 224 sur 1 451 (84,4 %). C'est
le seul chaînage vers un prix que la source offre, et l'ingestion le recevait
sans avoir où l'écrire. Les 227 manquantes sont **toutes** de l'extension `VEN`,
publiée le 31 juillet 2026 : trop récente pour être liée, pas un trou de
couverture réparti.

**Et la collection se valorise** — 1 196 impressions cotées, par
`app.ingestion.tcgcsv_prices`. Voir [« Les prix Riftbound »](#6-les-prix-riftbound)
plus bas pour la source, la conversion et ses limites.

**Les variantes d'impression ne sont pas des cartes.** La source suffixe les
noms — « (Alternate Art) », « (Signature) », « (Metal) »… sur 243 des 1 451
entrées. Les traiter comme des cartes distinctes créait deux lignes de
collection pour un seul exemplaire et deux résultats identiques dans la
recherche. Le suffixe est retiré de l'identité et conservé sur l'impression
(`printed_name`), ce qui ramène 1 234 identités à 1 035 et fait tomber les
empreintes ambiguës de 24 à 2.

**Le jeu choisi traverse l'application.** Un sélecteur dans l'écran de compte,
retenu d'une session à l'autre, propagé jusqu'aux appels : `search_cards`,
`my_collection`, `my_collection_summary` et `deck_suggestions` prennent tous un
paramètre de jeu, `magic` par défaut. `decks.game` a été ajoutée au passage, le
corpus étant jusque-là implicitement Magic. Un test vérifie que le choix
**atteint le dépôt** et pas seulement l'écran : c'est là que ce genre de câblage
cède en silence, et l'utilisateur verrait alors le catalogue Magic sous une
étiquette Riftbound.

**Et l'utilisateur les distingue aussi.** Puisque seule l'illustration sépare ces
quatre-vingts homonymes, la lui montrer est la seule façon de lui faire trancher :
`search_cards` rend une URL d'illustration, et une vignette précède chaque
résultat.

**Et le corpus de decks existe** — 2 500 listes de tournoi, format
`constructed`, depuis TopDeck.gg. Voir [« Le corpus de decks »](#7-le-corpus-de-decks)
plus bas.

**Ce qui manque encore**, et qu'aucune formulation optimiste ne doit masquer : la
confrontation de la reconnaissance à une vraie carte papier. C'est le dernier
verrou de la boucle de valeur — saisir, valoriser, proposer des decks — et il
demande des cartes physiques, pas du code.

---

## 1. Ce que le second jeu change au produit

**La promesse de DeckHand n'est pas la même pour les deux jeux.** Pour Magic,
l'application comble un manque réel : aucun outil ne relie une collection
physique aux decks qu'elle permet de construire. Pour Riftbound, Riot exploite
déjà **Piltover Archive**, site officiel qui propose un suivi de collection avec
valeurs de marché et progression par extension, un constructeur de decks qui
applique les règles, et les listes des tournois qu'il organise.

Ce qui resterait propre à DeckHand est donc plus étroit, et il faut l'assumer
avant d'investir :

- **la saisie physique** — photo, dictée, étalement — que Piltover Archive ne
  propose pas, et qui est précisément ce que cette application sait faire ;
- **le chiffrage de la complétion** contre un corpus de decks de tournoi, qui
  répond à « que puis-je construire ? » plutôt qu'à « qu'ai-je ? ».

Si ces deux apports ne justifient pas le coût, mieux vaut le savoir maintenant.

---

## 2. Sources et conditions

Le garde-fou §IV du [`CLAUDE.md`](../CLAUDE.md) impose de vérifier les conditions
**avant** toute dépendance : c'est ce qui a écarté EDHREC, techniquement
accessible mais contractuellement interdit. Les trois piliers du produit n'ont
pas le même statut ici.

| Pilier | Magic | Riftbound |
|---|---|---|
| Catalogue | Scryfall — libre, *bulk data*, sans clé | **API Riot officielle** — clé requise, attribution imposée, aucun export en masse annoncé |
| Prix | fournis par Scryfall | **ni Riot ni Riftcodex n'en servent** — relevés chez TCGplayer via l'export groupé TCGCSV, convertis en euros ([§ 6](#6-les-prix-riftbound)) |
| Corpus de decks | TopDeck.gg + MTGJSON | **TopDeck.gg**, la même source — les agrégateurs communautaires, eux, n'exposent aucune API ([§ 7](#7-le-corpus-de-decks)) |

### Contraintes Riot relevées, à confirmer sur le portail

Le portail développeur annonce un accès à des ressources choisies — illustrations,
texte officiel, rulesets, traductions — sous conditions :

- **attribution obligatoire**, formulation imposée (section 6 du « Legal Jibber
  Jabber ») ;
- **pas de simulation automatisée du jeu** ;
- **texte officiel obligatoire**, anglais ou traduction officielle ;
- **pas d'assets externes**.

Cette dernière demande une lecture attentive : DeckHand affiche aujourd'hui les
illustrations Scryfall, et la même pratique pourrait être interdite côté
Riftbound. Elle conditionne l'aperçu au maintien et le sélecteur d'édition.

**Débits et volumes ne sont pas documentés publiquement.** L'ingestion Magic
repose sur les *bulk data* de Scryfall ; sans équivalent, il faudra paginer, et
le débit décidera si c'est l'affaire de minutes ou d'heures.

### Ce qui reste ouvert

- **Les prix : réglé**, voir [§ 6](#6-les-prix-riftbound).
- **Le corpus de decks : réglé**, voir [§ 7](#7-le-corpus-de-decks). Ce qui
  suit reste vrai des agrégateurs communautaires, et explique pourquoi la
  réponse n'est venue d'aucun d'eux.
- Plusieurs sites annoncent des dizaines de milliers de
  listes, mais aucun n'a d'API publique documentée à ce stade — **relevé sur la
  spec OpenAPI de Riftcodex : 25 endpoints, tous sur le catalogue et les
  extensions, aucun sur les decks.** Sans corpus, le moteur de suggestion n'a
  rien à confronter. Les tournois organisés par Riot figurent sur Piltover
  Archive — piste à privilégier, la source étant officielle, mais elle dépend de
  l'ouverture de l'API Riot.

---

## 3. Couplage actuel à Magic — inventaire

Relevé sur le schéma et le code, pour remplacer l'impression par des nombres.

**Volume concerné** : 21 migrations, 10 tables, 2 vues, 14 fonctions SQL.
`oracle_id` apparaît **279 fois** dans les migrations et une centaine de fois
dans l'application.

### Ce qui accueille un second jeu sans se déformer

| Élément | Pourquoi il tient |
|---|---|
| `cards.legalities` (`jsonb`) | Structure libre : un format Riftbound s'y ajoute sans migration de colonne |
| `cards.color_identity` (`text[]`) | Un tableau de libellés accueille les *domaines* Riftbound aussi bien que les couleurs Magic |
| `decks.commander_oracle_id` | La *Légende* de Riftbound occupe la même place qu'un commandant |
| `card_prints`, `collection_items` | Édition, langue, finition, quantité : rien n'y est propre à Magic |
| Reconnaissance (nom lu, empreinte) | Ne suppose que « une carte porte un nom en haut » — vrai des deux jeux |

### Ce qui a dû changer

| Élément | Nature du changement |
|---|---|
| `cards.oracle_id uuid PRIMARY KEY` | C'est l'identifiant **Scryfall**. Riftbound n'en a pas : des UUIDv5 déterministes sont dérivés du triplet nom + type + texte, de sorte qu'une réingestion retombe sur les mêmes clés |
| `decks.format CHECK (…)` | **Élargie deux fois, jamais d'avance.** Elle n'a accueilli `constructed` (`20260815140000`) puis `edison`, `goat`, `redu`, `hat` (`20260816130000`) qu'une fois la donnée en main : chaque valeur vient d'un volume de decklists mesuré, non d'un nom de format lu quelque part. **L'horodatage d'une migration qui redéfinit une contrainte partagée doit suivre la dernière**, sinon une base rejouée depuis zéro voit le dernier fichier reprendre ce qu'un fichier antérieur avait ajouté — sans erreur |
| `cards.legal_pauper / legal_modern / legal_commander` | Colonnes **générées**, donc figées dans la définition de table |
| Les fonctions de lecture | `search_cards` prend un paramètre de jeu (`magic` par défaut). Les autres suivront quand l'application saura choisir un jeu |
| L'application | **Reste à faire** : un choix de jeu, et sa propagation jusqu'aux écrans de collection et de decks |

**Les migrations sont immuables** : tout se fait par ajout. `20260807210000_multi_game.sql`
ajoute `cards.game`, valorisée à `magic` pour les 31 634 cartes existantes, et
remplace `search_cards` — `DROP` puis `CREATE`, un `CREATE OR REPLACE` sur une
signature modifiée créant une surcharge qui ferait répondre HTTP 300 à *tous*
les appels.

### Révision d'un jugement

Un premier examen concluait à une « refonte ». L'inventaire le dément : les
notions les plus structurantes du modèle — légalités, identité de couleur,
commandant, impressions, collection — sont **déjà génériques ou extensibles**.
Le travail réel est l'ajout d'une dimension `game` et la mise à jour des
fonctions de lecture, pas une reconstruction.

---

## 4. Ce que la mesure devra trancher

### Sondage effectué : l'API officielle est fermée

Mesuré, clé de développement valide en main :

| Appel | Résultat |
|---|---|
| `lol/status/v4/platform-data` (endpoint banal) | **200** — la clé est valide |
| `riftbound/content/v1/content(s)` sur `americas`, `europe`, `asia`, `sea` | **403** sur les huit combinaisons |

Une clé valide qui obtient 403 partout sur un chemin par ailleurs documenté ne
laisse qu'une lecture : **l'API Riftbound n'est pas ouverte aux clés de
développement.** Le portail le confirme — l'accès demande une approbation
nommée, avec description détaillée, prototype fonctionnel et plateformes de
distribution déclarées, ou « a written license ».

Conséquence pratique : **le catalogue vient de Riftcodex**, faute d'accès à la
source officielle. La demande d'accès reste le bon chemin, et DeckHand a un atout
pour la déposer — l'application existe déjà et tourne, ce qui répond à l'exigence
de prototype.

**Source retenue en attendant, sur arbitrage explicite.** Riftcodex expose
une API publique, gratuite et sans authentification (nom, coût, puissance,
domaines, rareté, type, extension, illustration, artiste, texte, et des
identifiants croisés Riftbound et TCGplayer utiles pour les prix), paginée à 100
cartes. Mais c'est un projet de fans explicitement non affilié à Riot, dont les
conditions d'utilisation ne sont pas détaillées. C'est exactement la
configuration que le garde-fou §IV impose de vérifier avant toute dépendance —
celle qui a écarté EDHREC. Faute de conditions publiées, on lui applique celles
de Scryfall, et la bascule vers Riot reste l'objectif. Sa spec OpenAPI confirme
par ailleurs qu'elle ne sert **que** le catalogue : ni prix, ni decklists.

### Déjà répondu par la documentation

**L'API n'expose qu'un seul endpoint de contenu**, `riftbound-content-v1`
(`GET /riftbound/content/v1/content?locale=en` sur une route régionale). Il rend
l'intégralité du catalogue en une réponse — version, date de mise à jour, puis
les extensions et leurs cartes. C'est donc un *bulk data* de fait :

- **le débit n'est pas le sujet.** La contrainte de 100 requêtes par 2 minutes
  aurait rendu une ingestion carte par carte interminable ; un appel unique la
  rend sans objet. Restent les téléchargements d'illustrations, servis ailleurs ;
- **l'ingestion sera sans commune mesure avec celle de Magic.** Le catalogue
  Riftbound se compte en milliers de cartes quand celui de Magic en compte
  31 634, et son coût dominant — le téléchargement de chaque illustration pour
  en calculer l'empreinte — décroît dans la même proportion.

**Seule la locale `en` est servie en bêta.** C'est la limite la plus gênante pour
ce produit : DeckHand vise une collection franco-anglaise, et la reconnaissance
repose sur le **nom imprimé**. Sur une carte française, le nom lu ne
correspondrait à rien dans un catalogue anglais seul.

**Décision : pour Riftbound, l'illustration prime sur le nom** — l'inverse
exact du choix retenu pour Magic. L'art ne change pas d'une langue à l'autre :
l'empreinte est donc la seule voie qui traverse la barrière linguistique tant
que Riot ne sert que l'anglais. Le nom lu reste utile en confirmation, et
redeviendra la voie principale le jour où les traductions arriveront.

**Ce que cette inversion réintroduit, et qu'il faut savoir avant de coder.**
L'ordre a été inversé pour Magic parce que la reconnaissance par empreinte
exigeait un cadrage juste à 2 ou 3 % près — deux millimètres et demi sur la
hauteur d'une carte —, précision qu'aucun cadrage à main levée n'atteint (voir
[`architecture.md`](./architecture.md), « Ce que le premier test terrain a
montré »). Faire reposer Riftbound sur l'empreinte, c'est ramener cette
exigence au premier plan. Deux conséquences :

- le **recadrage guidé redevient obligatoire** pour ce jeu, là où il est devenu
  facultatif pour Magic ;
- la **détection des bords de la carte** — chantier déjà ouvert et non traité —
  cesse d'être un confort pour devenir la condition d'un scan utilisable.

En revanche, l'autre défaut mesuré de l'empreinte disparaît ici : l'index Magic
ne porte qu'une illustration par carte, et un quart des rééditions changent
d'art. Riftbound étant jeune, ses cartes n'ont pas encore de rééditions à
l'illustration différente — l'index couvrira donc tout ce qui existe.

### Ce qui reste à mesurer, clé en main

1. **Volume et champs** — combien de cartes, et quels attributs exactement
   (coût, domaine, type, rareté, extension, identifiants) ?
2. **Illustrations** — quelles URL, quelle résolution, et à quelles conditions
   d'affichage ? Répond à la clause « pas d'assets externes ».
3. **Identifiants** — quelle forme, et sont-ils stables entre extensions ?
   Décide de la clé primaire.
4. **Fraîcheur** — le champ `version` permet-il de sauter une ingestion inutile,
   comme le fait déjà `ingestion_state` pour Scryfall ?

---

## 5. La règle qui a conduit ce chantier

Le modèle de données ne se dessine pas sur des suppositions. C'est la règle qui a
produit les décisions tenables de ce projet — la zone d'illustration, la taille
d'empreinte, le seuil de taille de texte ont tous été mesurés avant d'être fixés,
et plusieurs hypothèses de départ y ont été démenties. Elle explique pourquoi
rien n'a été écrit ici avant que les champs réels de la source soient connus, et
pourquoi chaque affirmation de ce document porte un nombre.

---

## 6. Les prix Riftbound

`api/app/ingestion/tcgcsv_prices.py` — 21 requêtes, quelques secondes, idempotent
et sautant le jour déjà traité.

### D'où ils viennent, et pourquoi pas d'ailleurs

Riftcodex ne cote rien : sa spec OpenAPI ne porte que le catalogue et les
extensions. Riot non plus. Il restait deux voies :

- **les agrégateurs** (`tcg-cardmarket-api.com`, `cardmarket-api.com`,
  `riftbound-api.com`) — cotent en euros, mais plafonnent autour de cent requêtes
  par jour en gratuit. Un seul passage sur 1 451 impressions y demanderait une
  quinzaine de jours, quand les prix se rafraîchissent quotidiennement : le
  palier gratuit ne permet même pas un cycle ;
- **un export groupé**, ce qui rend l'ingestion Magic soutenable depuis le
  premier jour. [tcgcsv.com](https://tcgcsv.com/) publie les données TCGplayer par
  catégorie, rafraîchies chaque jour vers 20:00 UTC. Riftbound y est la catégorie
  **89**, avec ses dix extensions.

Mesuré : **1 196 de nos 1 224 `tcgplayer_id` (97,7 %)** portent un prix de
marché, séparé `Normal` / `Foil` — exactement la forme qu'attendent `price_usd`
et `price_usd_foil`.

**Ses conditions d'utilisation ne sont pas publiées.** Même configuration que
Riftcodex, et le garde-fou §IV impose de le dire plutôt que de l'ignorer : on lui
applique donc celles de Scryfall — `User-Agent` descriptif, débit bas,
attribution visible dans l'écran « à propos ».

### Les euros sont convertis, pas relevés

TCGplayer cote en dollars ; l'application affiche des euros de bout en bout
(`price_usd` existe dans le schéma mais aucune fonction SQL ni ligne de Dart ne
la lit). La conversion passe par le **taux de référence quotidien de la Banque
centrale européenne** — donnée publique, officielle et datée, non un taux
inventé.

Ce n'est pas pour autant un prix de marché européen : Cardmarket et TCGplayer
divergent sur ce jeu. Trois dispositions rendent le chiffre traçable plutôt que
péremptoire :

1. `price_usd` conserve le montant **relevé**, à côté du montant dérivé ;
2. `ingestion_state` consigne le taux et sa date
   (`2026-08-11 usd_par_eur=1.1540 (BCE 2026-08-11)`) ;
3. le sélecteur de jeu et l'écran « à propos » le disent à l'utilisateur.

La date consignée est celle de la BCE et non celle du jour : elle ne publie ni
les week-ends ni les jours fériés, et le taux du vendredi tient jusqu'au lundi.

`to_euros` **divise** par le taux publié, qui exprime le nombre de dollars que
vaut un euro. L'erreur inverse majorerait tout de 15 % en restant parfaitement
crédible à l'œil — c'est le premier cas que couvrent les tests.

### Deux limites à connaître

**`marketPrice` et non `lowPrice`.** Le prix bas est une annonce isolée — carte
abîmée, erreur de saisie ; le prix de marché est la valeur calculée sur les
ventes réelles, et c'est aussi ce que Scryfall publie pour Magic. Les deux jeux
se valorisent donc sur la même notion, condition pour que les totaux se
comparent. Un produit sans prix de marché est absent plutôt que mal valorisé.

**493 impressions de base ne sont cotées qu'en brillante.** Un exemplaire
ordinaire de ces cartes compte donc pour zéro : c'est la règle « une carte sans
cote compte pour 0 €, jamais pour une estimation inventée », appliquée à une
absence réelle de cote et non à un oubli. `card_cheapest_price` reste sur le prix
ordinaire, inchangée — la modifier changerait aussi la valorisation Magic.

**Les 227 impressions de `VEN` restent sans prix**, faute de `tcgplayer_id` chez
Riftcodex. TCGCSV connaît pourtant le groupe : on pourrait rapprocher par nom et
numéro. On ne le fait pas — un rapprochement approximatif écrirait un prix
plausible sur la mauvaise carte sans que rien ne le signale, là où une carte sans
cote compte pour zéro, ce qui est faux mais visible.

### Vérifié de bout en bout

Dans une transaction **annulée**, sous le rôle `authenticated` et les claims du
compte réel : trois exemplaires ajoutés (deux ordinaires, un brillant) donnent un
total de **34,87 €**, égal au centime à la somme attendue
(15,17 + 4,28 + 15,42). Le prix de la finition possédée est bien celui retenu.
La collection réelle n'a pas été touchée.

---

## 7. Le corpus de decks

`api/app/ingestion/topdeck_ingest.py --riftbound` — 2 500 decks, format
`constructed`, fenêtre de 180 jours.

### La sortie n'était pas une nouvelle source

Le blocage était réputé contractuel, et il l'était : aucun agrégateur
communautaire n'expose d'API. Relevé site par site, `robots.txt` en main —
c'est la vérification que le garde-fou §IV impose avant toute dépendance :

| Site | Ce que ses règles publiées disent |
|---|---|
| riftdecks.com | `ClaudeBot`, `Google-Extended`, `CCbot` → `Disallow: /`, et un commentaire nommant les « services concurrents » comme indésirables |
| riftbound.gg | `anthropic-ai`, `Claude-Web`, `GPTBot`, `CCbot` → `Disallow: /` |
| piltoverarchive.com | tout permis **sauf `/api/`**, explicitement interdit |
| riftools.app | `Allow: /` pour tous, y compris `ClaudeBot` — le seul à publier une permission |

Aucun n'ouvrait de porte utilisable : soit ils refusent l'accès automatisé, soit
ils interdisent précisément l'API qui servirait. Et scraper reste exclu — le
garde-fou §IV.1 a écarté EDHREC pour cette raison exacte.

**La réponse était sous la main.** TopDeck.gg, la source qui alimente déjà le
Pauper et le Modern, couvre Riftbound : `{"game": "Riftbound", "format":
"Constructed"}` rend **159 tournois**, dont 59 portent des decklists, pour 2 501
participations documentées. Même clé, même obligation d'attribution déjà honorée
par `deck_sources`, aucune condition nouvelle à vérifier. Le format `Sealed`
répond aussi (13 tournois) mais n'entre pas : un format scellé ne se confronte
pas à une collection, on y joue ce que la boîte donne.

### Deux différences avec Magic, toutes deux à notre avantage

**Les cartes portent un code d'impression**, `OGS-019`, et non seulement un nom.
Le rapprochement redevient exact : `PrintCodeResolver` traduit le couple
(extension, numéro) en `oracle_id`, et **785 codes sur 786 se résolvent**. Le
seul manquant est `SFD-171a`, une variante que le catalogue ne porte pas. Là où
Magic doit composer avec la casse, les accents et les cartes à deux faces,
Riftbound n'a aucune ambiguïté — ce qui compte d'autant plus ici que le jeu a
80 homonymes qu'un rapprochement par nom rendrait indiscernables.

Le numéro est **cadré sur trois chiffres** : la source écrit `OGN-042`, le
catalogue retient `42`. Comparer les chaînes telles quelles échouerait sur toute
carte numérotée sous 100, soit la majorité.

**Un deck a six zones** : `Legend`, `Champion`, `Runes`, `Battlefields`,
`Mainboard`, `Sideboard`. Toutes sauf la réserve désignent des cartes qu'il faut
posséder — on ne joue pas sans ses runes ni ses champs de bataille —, elles sont
donc fondues dans le pan principal, celui qui porte le calcul de complétion. Les
omettre ferait paraître constructible une liste dont quinze cartes manquent. La
Légende est en outre retenue à part, pour occuper `decks.commander_oracle_id`
comme le fait un commandant : c'est ainsi qu'on choisit un deck.

### Un seuil de taille, tiré de la distribution

Le contrôle qualité existant ne mesurait que la **proportion de cartes
inconnues** : une decklist enregistrée à moitié à la source le franchit sans
peine, puisque le peu qu'elle contient se résout parfaitement. Elle
apparaîtrait ensuite comme presque constructible — le pire défaut possible pour
ce produit.

Mesuré : sur 2 501 participations, **2 459 comptent exactement 56 cartes** hors
réserve, l'écart total allant de 55 à 65 — sauf une liste à 5 cartes. Le seuil
est posé à 40, très en deçà de tout deck réel et très au-dessus d'un fragment :
il écarte l'accident sans prétendre juger les règles du jeu.

### Ce qu'il a fallu changer ailleurs

- `decks.format` accueille `constructed` (migration `20260815140000`).
- `store_deck` écrit `decks.game` — il ne le faisait pas, et une source couvrant
  deux catalogues aurait laissé les decks Riftbound étiquetés « magic ».
- `deckFormatsFor(game)` côté application : proposer Pauper en Riftbound
  afficherait un onglet vide, et l'écran aurait l'air en panne alors qu'il dit
  vrai. La sélection se remet au premier format du jeu à chaque bascule.
- **`p_game` accompagne enfin `p_format`** dans l'appel à `deck_suggestions`. Il
  manquait : tant que Riftbound n'avait aucun deck, l'omission ne se voyait pas.
  Un test le verrouille, comme pour la recherche de cartes.
- Le **constructeur** n'a pas de gabarit pour ce format et le dit. Les
  proportions d'un deck se mesurent sur un corpus ; celles de Magic ne se
  transposent pas à un jeu qui compte des runes et des champs de bataille plutôt
  que des terrains. `DeckBlueprint.of` rend `null` plutôt qu'un gabarit par
  défaut, ce qui aurait produit un deck faux sous une apparence de rigueur.

### Vérifié

`api/app/measure/deck_math.py` prend désormais `<format> <jeu>` :

```
$ python -m app.measure.deck_math constructed riftbound
100 decks confrontés, format constructed (riftbound).
Aucun écart : les deux calculs concordent sur tous les decks.
```

Et par le chemin réel de l'application, sous le rôle `authenticated` :
`deck_suggestions(p_format='constructed', p_game='riftbound')` rend des decks
avec leur Légende, leurs cartes manquantes et leur coût en euros.
