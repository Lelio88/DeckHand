# Multi-jeu — accueil des jeux qui ne sont pas Magic

Annexe de [`architecture.md`](./architecture.md). Cinq jeux partagent
aujourd'hui la base de DeckHand : **Magic**, **Riftbound** (le TCG League of
Legends de Riot), **Yu-Gi-Oh**, **Pokémon** et **Wankul**. Ce document dit ce que
chacun a demandé, et ce que le modèle a absorbé sans se déformer.

Quatre bouclent la promesse entière — collection, prix, decks constructibles.
**Wankul n'en boucle qu'une partie, et c'est structurel** : ni marché secondaire
coté, ni corpus de listes publié, ni illustration accessible. La
[§ 9](#9-wankul--un-catalogue-sans-prix-sans-decks-et-sans-images) dit pourquoi
et ce qu'il en reste.

---

## 0. Yu-Gi-Oh — 13 866 cartes, et presque rien à inventer

**Ce jeu a coûté moins cher que Riftbound**, et l'écart tient entièrement à la
source. Tout ce qui suit est relevé sur les données, pas repris d'une
documentation.

| | Riftbound | Yu-Gi-Oh |
|---|---|---|
| Catalogue | 15 requêtes paginées | **un seul appel**, 21 Mo, 14 491 cartes |
| Identité | UUIDv5 dérivés du triplet titre + type + champion | **le passcode imprimé sur la carte**, unique sur 14 491 |
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
pour ces cartes et pour elles seules. Pokémon a longtemps paru dépourvu d'un tel
contrat — la rareté, quarante valeurs remaniées en vingt-sept ans, semblait le
seul recours. La mesure de #28 a démenti cette crainte : ce jeu offre **cinq**
champs à vocabulaire fermé qui font le travail, voir
[§ 8](#8-pokémon--ce-que-la-mesure-a-rendu-avant-toute-ingestion).

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
`20260816130000`). `DeckBlueprint.of` continue de rendre `null`, et la section
suivante dit pourquoi — ce n'est plus faute d'avoir mesuré.

### Le gabarit de deck, et un constructeur aux axes du jeu

Les proportions d'un deck Yu-Gi-Oh se lisent sur ses 3 935 listes
(`python -m app.measure.deck_anatomy --game yugioh`). Ce sont **les plus nettes
du projet** :

| | edison (3 050) | goat (484) | redu (320) | hat (81) |
|---|---|---|---|---|
| Deck principal | 40 (écart 1) | 40 (écart 0) | 40 (écart 1) | 40 (écart 0) |
| Extra Deck | 15 (écart 0) | 11 (écart 15) | 15 (écart 0) | 15 (écart 0) |
| Monstres | 52,5 % (12,2) | 45,0 % (15,0) | 43,9 % (16,2) | 45,0 % (12,2) |
| Magies | 21,4 % (9,8) | 30,0 % (10,0) | 27,5 % (15,8) | 26,8 % (24,0) |
| Pièges | 24,4 % (16,6) | 22,5 % (12,5) | 27,5 % (16,6) | 25,0 % (20,0) |

Trois faits en sortent :

- **La taille est un contrat, pas une tendance.** 40 cartes, écart interquartile
  de 0 à 1 sur les quatre formats. Aucun format Magic n'approche cette
  régularité — la mesure la plus serrée y était les terrains de Commander, à
  2 points.
- **Trois exemplaires au maximum**, vérifié sur tout le corpus. Un seul deck HAT
  en affiche 6, ce qui trahit une liste mal découpée plutôt qu'une infraction.
- **La composition, elle, est dispersée** — 12 à 24 points d'écart sur les
  monstres. Comme le Pauper et le Modern, ce format mêle des archétypes dont la
  médiane décrit un deck qui n'existe nulle part.

**Le corpus ne distingue pas l'Extra Deck, et il fallait le voir.** TopDeck.gg ne
publie qu'un `main` et un `side` ; les quinze cartes de l'Extra arrivent donc
mêlées au deck principal. Une taille lue naïvement sur ce board vaut **55** — un
nombre qui ne correspond à aucune zone du jeu. Les séparer demande de reconnaître
les types d'Extra (Fusion, Synchro, Xyz, Link), ce que le banc fait désormais.
Sans cette séparation, le gabarit aurait déclaré des decks de 55 cartes avec
l'assurance d'une mesure.

**Le constructeur a donc été refait sur les axes du jeu.** Le gabarit a
longtemps rendu `null`, et ce n'était plus faute de mesure : le constructeur
était bâti sur des notions que ce jeu n'a pas, et la mesure le chiffrait.

| Ce que le constructeur demande | Ce que Yu-Gi-Oh en offre |
|---|---|
| `isCreature` — cherche « Creature » | **aucune** carte sur 13 866 |
| `isLand` | **aucune** |
| `playableIn` — identité de couleur | le champ porte l'**Attribut**, qui n'impose aucune contrainte de construction |
| `cmc` — coût de mana | le champ porte le **Niveau** |

Deux quotas sur cinq étaient donc introuvables, et le filtrage par « couleur »
écartait **32 % du catalogue** sur une règle qui n'existe pas — rien n'interdit
de mêler DARK et LIGHT. `cmc` et `color_identity` sont des analogues de forme,
pas de sens : l'ingestion y range le Niveau et l'Attribut faute de champs
dédiés, et s'en servir comme le fait Magic aurait produit un deck faux avec
l'assurance d'un deck mesuré.

**Ce qui a changé, et où.** Ce qui dépend du jeu est devenu une propriété du
jeu, comme le format d'une carte l'était devenu en #24 :

| Notion | Magic | Yu-Gi-Oh |
|---|---|---|
| `BuildableCard.game` | `magic` | `yugioh` — c'est lui qui décide comment lire le reste |
| Rôles (`rolesOf`) | créature, terrain, rampe, retrait, pioche — devinés au texte oracle | monstre, magie, piège, magie rapide, piège continu — **imprimés dans le type** |
| Filtre du pool | identité de couleur | **aucun** (`usesColorIdentity: false`) |
| Quota de terrains | mesuré | **`null`**, non pas zéro : il n'y a rien à manquer |
| Paliers | coût de mana | **Niveau** — sans tribut jusqu'à 4, un tribut à 5-6, deux au-delà |
| Zones | une, plus les terrains de base | **deux** : deck principal et Extra Deck |

Le pool de l'Extra Deck est **disjoint** : ses cartes ne concourent pas pour les
places du deck principal, et n'entrent pas dans ses quotas — les y compter
fausserait la part des monstres de moitié. Aucun quota ne gouverne son contenu,
et c'est un résultat de mesure : le corpus donne sa taille, jamais une
composition stable à viser.

Le jeu se lit mieux que Magic sur un point : **le rôle est imprimé**. Là où
Magic doit chercher « Destroy target » dans un texte oracle — méthode grossière
assumée —, Yu-Gi-Oh écrit « Quick-Play Spell » dans le type. Ce qui reste
approximatif chez l'un est exact chez l'autre.

**Ce que le constructeur ne promet toujours pas** : un deck optimal. Les
proportions visées sont dispersées, et l'écran le dit — `BlueprintReliability
.averaged` sur les quatre formats, comme pour le Pauper et le Modern.

### Vérifié sous le rôle qui subira les règles (decks)

Sous `authenticated`, `deck_suggestions(p_game => 'yugioh')` rend des decks pour
les quatre formats, avec leur coût de complétion valorisé (16,20 € pour la
première liste Edison). Aucune carte d'un autre jeu n'est entrée dans un deck
Yu-Gi-Oh — vérifié par jointure, zéro ligne.

**Le corpus et les prix se rejoignent** : 1 555 des 1 562 cartes citées par ces
decks portent un prix, soit **99,6 %**. Le coût de complétion est donc chiffrable
pour presque toute liste — c'est la promesse du produit, pas un chiffre
d'agrément.

**Ce qui reste dû** : l'index d'empreintes est plein, les prix, les decks et les
proportions de deck sont mesurés. Reste **le carton**, et il faut dire pourquoi
il ne viendra pas de la même façon que pour Riftbound : **le propriétaire de la
collection n'a aucune carte Yu-Gi-Oh**. Ce n'est donc pas une tâche en attente
mais une validation indisponible, et l'écrire comme un dû ferait espérer une
preuve qui ne viendra pas d'ici. Le précédent Riftbound donne le seul substitut
connu : ses huit cartes ont été photographiées par un **tiers**.

**Ce que l'absence de carton coûte réellement est plus étroit qu'il n'y paraît.**
Les deux défauts que le carton Riftbound a révélés étaient l'un générique et
l'autre spécifique, et ils ne laissent pas le même trou :

- la **réduction qui repliait une texture** en bruit lu comme du carton était
  dans `_analysisImage` et `_boxReduceLuma`, partagés par tous les jeux sans
  paramètre. Yu-Gi-Oh en bénéficie sans avoir eu à le payer ;
- l'**orientation** d'une carte couchée glissée dans une pochette droite ne
  concerne que les jeux qui impriment en travers, et Yu-Gi-Oh n'en a aucun.

Ce qui reste non éprouvé lui est donc propre : que son gabarit d'illustration
rencontre l'index sur une **photo** et non sur un rendu de catalogue. Le risque
y est plus faible qu'il ne l'était pour Riftbound, dont le gabarit venait d'une
heuristique sur seize cartes : celui de Yu-Gi-Oh a été obtenu par recoupement
contre l'illustration détourée que la source publie elle-même, à 0,001 près sur
vingt cartes de dix familles de cadre. Plus faible n'est pas nul.

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

**L'index d'empreintes est construit** : 1 193 empreintes pour 929 cartes,
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

### Une identité ne se dérive pas d'un champ d'affichage

Le triplet retenu était **nom + type + texte**. Les deux champs de texte y sont
faits pour être lus par un joueur, pas pour identifier : la source les réécrit
d'une extension à l'autre, et l'identité se dédoublait à chaque réécriture.

Le *nom* varie de deux façons — le champion y est tantôt présent tantôt absent
(« Ambessa - Matriarch of War » / « Matriarch of War »), et son séparateur change
(« Lux - Crownguard » en OGS, « Lux, Crownguard » en VEN). Le *texte* varie
davantage : l'extension VEN retire les rappels de règles entre parenthèses, la
source écrit tantôt `''` tantôt `'[NO TEXT]'` pour une carte sans texte, mêle
apostrophes droites et typographiques, entités HTML et flèches, et reformule au
passage.

**87 identités nouvelles en réunissent 192 anciennes** : 5 groupes s'expliquent
par le seul nom, **63 par le seul texte**, 19 par les deux. L'issue #29 avait
relevé les 24 groupes visibles au nom ; les trois quarts du défaut tenaient au
texte, et aucune normalisation de nom ne les aurait touchés. Le catalogue passe
de 1 035 à **929 cartes**.

La règle est désormais **titre + type + champion**, où le titre est le nom privé
de son préfixe et le champion vient des `tags`, pas du nom. Le champion est
nécessaire : trois titres sont portés par deux champions différents, et ce sont
deux cartes (« Rumble - Hotheaded » / « Vi - Hotheaded », « Vayne - Hunter » /
« Warwick - Hunter », « Fiora - Victorious » / « Qiyana - Victorious »).

**Trois pistes mesurées puis écartées.** `riftbound_id` (« ven-190-166 »)
ressemble à un identifiant de carte : son dernier segment ne prend que **13
valeurs** sur tout le catalogue et regroupe des centaines de cartes sans rapport
— c'est un code de produit. Le titre seul fusionne les trois paires ci-dessus.
L'ensemble des tags dédouble « Vayne - Hunter », dont le tag « Sentinel »
n'apparaît qu'en VEN ; l'intersecter avec le vocabulaire des champions — les 100
préfixes observés — ne garde que ce que la source dit de stable.

**Changer une règle d'identité déplace tout ce qui s'y accroche.** Les
impressions se repointent seules, mais les empreintes portent aussi
`oracle_id` — sans recalage, la purge des anciennes cartes en aurait détruit
1 193, à retélécharger chez une source qu'on s'est engagé à ménager. Les decks,
eux, citent `oracle_id` sans cascade : la purge conserve ce qu'elle ne peut pas
supprimer et le dit, le remède étant de rejouer l'ingestion des decks — qui
résout par code d'impression, donc retombe sur les nouvelles identités.

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
| `cards.oracle_id uuid PRIMARY KEY` | C'est l'identifiant **Scryfall**. Riftbound n'en a pas : des UUIDv5 déterministes sont dérivés du triplet titre + type + champion, de sorte qu'une réingestion retombe sur les mêmes clés. Le triplet a changé une fois — voir « Une identité ne se dérive pas d'un champ d'affichage » |
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

**704 impressions ne sont cotées qu'en brillante** (493 lors de la première
mesure ; le nombre suit les extensions). Un exemplaire ordinaire de ces cartes
compte donc pour zéro : c'est la règle « une carte sans cote compte pour 0 €,
jamais pour une estimation inventée », appliquée à une absence réelle de cote et
non à un oubli. `card_cheapest_price` reste sur le prix ordinaire, inchangée —
la modifier changerait aussi la valorisation Magic.

**Compter les cotes sur la seule colonne ordinaire donne un chiffre faux**, et
alarmant : 492 sur 1 451, soit 34 %. La bonne question est « cotée dans au moins
une finition », et la réponse est **1 196 sur 1 451, 82,4 %** — le reste étant
les 227 `VEN` non chaînées ci-dessous et 28 produits que TCGCSV connaît sans
leur trouver de prix de marché. C'est la même leçon que le corpus Limitless :
un compteur qui ne mesure pas ce qu'on croit rend un diagnostic, pas une donnée.
Le connecteur lit désormais la base **après** écriture et publie cet état, au
lieu d'annoncer le nombre de lignes touchées.

### La finition brillante était inatteignable, et le silence était total

`card_editions` décide quelles finitions proposer en lisant
`card_prints.finishes`, avec ce repli :

```sql
COALESCE('nonfoil' = ANY(p.finishes), true),                 -- has_nonfoil
COALESCE('foil'    = ANY(p.finishes), false)                 -- has_foil
```

**Seul le connecteur Scryfall remplissait cette colonne.** Pour Riftbound —
comme pour Pokémon, Yu-Gi-Oh et Wankul — elle était nulle, donc `has_foil`
valait `false` partout : *aucune* carte de ces jeux ne pouvait être déclarée
holographique. Rien ne le signalait, la colonne étant simplement vide.

Ce que ça coûtait, mesuré sur Riftbound : **511 impressions existent dans les
deux finitions**, avec des écarts allant jusqu'à dix-huit fois — « Pack of
Wonders » vaut 0,53 € en ordinaire et 9,71 € en brillante. Une brillante saisie
comme ordinaire était donc sous-évaluée d'autant. Les 704 cotées **en brillante
seulement** ne perdaient rien, en revanche : `print_price` retombe sur l'autre
finition faute de mieux.

**La finition se lit sur la déclaration de la source, pas sur ses prix.** TCGCSV
publie une ligne par couple produit-finition, et cette ligne existe même quand
`marketPrice` est nul — 15 lignes dans ce cas sur 1 993, dont une portant
pourtant un `lowPrice`. Déduire les finitions des prix conclurait « n'existe pas
en brillante » à partir de « personne n'en vend en ce moment ».

| Produits Riftbound chez TCGCSV | |
|---|---|
| brillante seulement | 822 |
| les deux finitions | 511 |
| ordinaire seulement | 149 |

Résultat en base : **1 157 impressions déclarent la brillante** contre zéro
avant, 749 l'ordinaire, et **aucune n'en offre plus une seule** — le contrôle qui
importait, une impression sans finition étant impossible à saisir. Magic n'est
pas touché : le filtre `cards.game` protège la colonne que Scryfall renseigne.

**Cette table de traduction ne se transpose pas aux jeux voisins, et c'est
mesuré.** Chez Yu-Gi-Oh, `subTypeName` porte une **édition** — `Unlimited`,
`1st Edition`, `Limited` — et non une finition : l'appliquer là-bas déclarerait
« existe en brillante » sur la foi d'un tirage. Un test le verrouille.

### Le même trou, jeu par jeu

Le défaut touchait les quatre jeux non-Magic. Trois sont réglés, chacun avec sa
propre source de vérité — et c'est le point : **la finition ne se déduit pas
d'un principe, elle se lit là où le jeu la déclare.**

| Jeu | Ce qui dit la finition | Déclarent la brillante |
|---|---|---|
| **Riftbound** | `subTypeName` de TCGCSV : `Normal`, `Foil` | **1 157** sur 1 451 |
| **Pokémon** | `subTypeName` : `Normal`, `Holofoil`, `Reverse Holofoil` — trois valeurs, mesurées sur 15 016 lignes. La brillante inversée est repliée sur `foil`, comme le faisaient déjà les prix | **15 350** sur 20 964 |
| **Wankul** | `imageUR`, un rendu de remplacement — la rareté et `holoMasks` ont tous deux échoué, voir [§ 9](#9-wankul--un-catalogue-sans-prix-sans-decks-et-sans-images) | **200** sur 958 |
| **Yu-Gi-Oh** | rien : son `subTypeName` est une édition | 0 — **et c'est un état, pas un oubli** |

Chez Pokémon, la combinaison la plus courante est `Normal` + `Reverse Holofoil`
— un tiers des produits mesurés. C'est le motif classique du jeu : une carte
commune existe en ordinaire et en fond brillant.

**Le contrôle qui importait, sur les cinq jeux : aucune impression n'offre plus
zéro finition.** Une impression sans finition serait impossible à saisir ; la
vérification passe par l'expression exacte de `card_editions`, `etched` compris —
l'omettre faisait compter 1 505 faux positifs chez Magic.

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

### Cardmarket : évalué, et écarté par ses conditions

La question valait d'être posée — Cardmarket **couvre Riftbound**, cote en euros
**relevés** plutôt que convertis, et connaît des extensions que TCGCSV ignore
(`OGNX`, `UNLX`, `SFDX`, `VENX`, `PROK`, `SGN`, `RAD`), y compris des `VEN` que
notre catalogue laisse sans prix. Techniquement, ce serait un gain.

Ses conditions l'interdisent, et deux fois plutôt qu'une.

**L'API est fermée.** Page d'aide officielle, verbatim : « The API provides an
interface for users to create their own apps for using Cardmarket. *Currently,
we are not accepting applications for access to the Cardmarket API.* » Aucun
identifiant n'est délivré. (La documentation v1 rend d'ailleurs `410 Gone` et
renvoie vers `apiv2.cardmarket.com`.)

**Et même avec des identifiants, l'usage visé est nommément exclu.** CGU n° 9 :
« The API may only be used for managing your own contents. ***The presentation
of the trading cards and their respective prices require our prior written
agreement.*** The use of the API and the transfer and use of data for any other
purpose is prohibited. » Afficher un prix de carte demande donc un **accord
écrit préalable** — exactement ce que DeckHand ferait.

**Le contournement par les pages publiques est fermé aussi.** CGU n° 10 : « you
are prohibited from disseminating or publicly reproducing contents of the online
platform ». Le `robots.txt` autorise pourtant `Allow: /` au crawler générique :
**s'y fier aurait été une erreur**, ce sont les CGU qui font foi. Il porte par
ailleurs une réserve expresse au titre de l'article 4 de la directive 2019/790.

C'est donc le cas EDHREC du garde-fou §IV.1, à une différence près : ici la
porte existe. Elle s'appelle « prior written agreement », elle se demande à un
humain, et c'est le même chemin que celui qui a ouvert Wankul.

**La bonne nouvelle est ailleurs** : le manque que cette piste devait combler
n'existe pas. La couverture est de 82,4 %, et les 227 `VEN` sans prix attendent
un `tcgplayer_id` de Riftcodex, pas une autre source.

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

---

## 8. Pokémon — ce que la mesure a rendu, avant toute ingestion

**Rien de Pokémon n'est en base, et ce n'était pas le but.** #28 est un chantier
de mesure : son résultat devait dire si un quatrième jeu est tenable, et à quel
prix. Tout ce qui suit est relevé sur les données par trois bancs —
`api/app/measure/pokemon_taxonomy`, `pokemon_art_window`,
`pokemon_energy_collisions` — et non repris d'une documentation.

**La crainte de départ portait sur le bon endroit, et la réponse est l'inverse
de celle qu'on attendait.** L'issue redoutait un jeu dont l'illustration « n'a
pas une position, elle en a au moins quatre », et dont le seul discriminant
serait la rareté — quarante valeurs remaniées en vingt-sept ans. Les positions
sont bien multiples. Le discriminant, lui, n'est pas la rareté : la source
publie **cinq champs à vocabulaire fermé** qui font le travail, et la rareté est
précisément celui qu'il ne faut pas prendre.

### La source, et sous quelles conditions

TCGdex — licence MIT, sans clé, **23 444 cartes en 218 sets et 21 séries**, plus
de dix langues. Ses conditions ne sont pas publiées : le garde-fou §IV.9
s'applique et lui donne celles de Scryfall, comme à Riftcodex — `User-Agent`
descriptif, débit bas, attribution visible, aucune illustration réhébergée.

Une nuance de plus, propre à ce jeu, mérite d'être écrite **avant** d'investir :
les deux CDN d'images sont eux-mêmes des tiers non affiliés, et **aucune source
Pokémon n'a de bénédiction éditeur** comparable à la *Fan Content Policy* qui
légitime Scryfall. Les CGU de pokemon.com interdisent de « download quantities
of content to a database » — clause qui gouverne les services de l'éditeur, non
les API tierces, mais qui retire toute marge d'interprétation confortable.

### Ce que la source ne publie pas ferme la méthode la moins chère

TCGdex ne sert que **la carte entière** : `image` est une URL de base à laquelle
on accole la qualité (`/high.webp`), et il n'existe aucune illustration
détourée. La méthode qui a rendu Yu-Gi-Oh à 0,001 près — chercher, dans la carte
entière, la région qui reproduit l'illustration publiée à part — est donc fermée
d'emblée.

En contrepartie, toutes les images sortent en **600 × 825**, d'une carte de 1999
comme d'une de 2024. C'est ce qui permet de les empiler sans redimensionner,
donc sans introduire le flou d'un rééchantillonnage là où on cherche des arêtes.

### Trois signaux essayés, un seul qui tranche

| Signal | Ce qu'il donne | Verdict |
|---|---|---|
| Écart-type entre cartes | 50 à 65 niveaux sur **toute** la carte | inutilisable |
| Luminosité de l'image moyenne | illustration 137, pavé de texte 165 | insuffisant seul |
| **Gradient de l'image moyenne** | fond à 5, traits de fenêtre à **63** | tranche |

L'écart-type est l'impasse propre à ce jeu, et elle n'était pas prévisible :
**la couleur du cadre Pokémon suit le type du Pokémon**, si bien que le cadre
varie autant que l'illustration. C'est pourtant le signal qui aurait dû marcher,
et une variante de celui qui a servi à Riftbound.

Ce qui reste tient en une phrase : *ce qui survit à la moyenne, c'est ce qui ne
bouge pas — donc les traits du cadre.* Empiler quarante cartes alignées éteint
les illustrations en un gris terne dont le gradient tombe à 5, tandis que les
traits imprimés au même endroit sur chaque carte y montent à 63. La fenêtre est
la plage calme ; ses bords sont les traits qui l'arrêtent. La luminosité sert
alors de **contrôle croisé** : l'illustration doit ressortir plus sombre que le
pavé de texte qui la suit, et le banc le vérifie au lieu d'y croire.

**Une quatrième piste a été suivie puis retirée**, et elle mérite d'être écrite
pour ne pas la refaire : délimiter d'abord la « zone imprimée » par l'écart-type,
en croyant qu'un bord de carte ne varie jamais. L'écart-type tombe bien à zéro
dans les vingt premières colonnes des cartes ordinaires — mais parce que leur
**bordure jaune est identique partout**, non parce qu'on serait hors du carton.
Les cartes *ex*, à bordure argentée variable, y affichent 40. La même mesure
rendait 24..575 pour les unes et 0..599 pour les autres, sur des images pourtant
cadrées de la même façon.

### Le discriminant n'était pas la rareté — il y en a cinq

| Question | Champ | Vocabulaire | Ce qu'il rend |
|---|---|---|---|
| Cette carte existe-t-elle sur carton ? | `serie` | 21 séries | `tcgp` = **2 480 cartes en 15 sets**, à écarter |
| Encadrée, ou pleine page ? | `localId` vs `set.cardCount.official` | des nombres | 17 365 encadrées, 1 937 pleine page |
| Quelle mise en page de cadre ? | `category` | 3 valeurs | Pokémon, Dresseur, Énergie |
| Fenêtre haute (`ex`, `V`, `VMAX`…) ? | `suffix` ou `stage` | 8 + 7 valeurs | **1 882 cartes**, soit 10,8 % des encadrées |
| A-t-elle seulement une illustration ? | `energyType` | 2 valeurs | 336 énergies de base, qui n'en ont pas |

Deux de ces champs contredisent le relevé d'ouverture, et c'est le gain
principal du chantier :

- **La famille à fenêtre haute a bien un discriminant structuré.** Le relevé la
  disait sans. Le partage entre `suffix` et `stage` ne suit aucune logique
  apparente — `ex`, `V` et `GX` sont des suffixes ; `VMAX`, `VSTAR` et `MEGA`
  sont des *stages* — mais les deux vocabulaires sont **publiés et fermés**, ce
  qu'une liste de raretés qui s'allonge à chaque extension n'est pas. Lire un
  seul des deux champs manquerait 274 cartes.
- **`category` est un axe, et il manquait.** Mesuré dans la même série : la
  fenêtre d'un Pokémon s'arrête à la ligne 390, celle d'un Dresseur à la ligne
  430 — quarante pixels, 5 % de la hauteur.

**Ce que la rareté ne saurait pas faire**, chiffré plutôt qu'affirmé :

- pour la famille à fenêtre haute — 3 valeurs de rareté la désignent purement,
  **7 sont mélangées**, et **1 783 cartes** ne pourraient pas être isolées ;
- pour le périmètre — 10 valeurs ne servent que sur écran, 16 que sur carton, et
  **une sert des deux côtés** (`None` : 430 cartes de carton, 62 d'écran). La
  série, elle, est une propriété du set : elle coupe sans reste.

**L'ordre des règles compte, et il n'est pas indifférent.** 684 cartes pleine
page — 35,3 % d'entre elles — portent aussi un `suffix` ou un `stage`. Lire la
marque avant le numéro les rangerait parmi les encadrées, où elles n'ont pas de
cadre. Le numéro tranche d'abord, la marque ensuite.

### Les fenêtres mesurées

Sur la série Écarlate-Violet, 40 cartes par groupe et 40 autres en contrôle :

| Famille | gauche | haut | droite | bas | dérive du contrôle |
|---|---|---|---|---|---|
| Pokémon encadré | 0,0850 | 0,1055 | 0,9200 | 0,4727 | **2 px** |
| Dresseur | 0,0850 | 0,1455 | 0,9200 | 0,5164 | **0 px** |

Les arêtes sont bordées de traits qui dépassent le calme intérieur de 3 à 33
fois, et la luminance est dans l'ordre attendu (137 contre 165 pour le Pokémon,
142 contre 198 pour le Dresseur). Le contrôle sur tirage disjoint est ce qui a
démasqué `category` : tant que Pokémon et Dresseurs étaient mêlés, l'arête haute
dérivait de **32 px** d'un tirage à l'autre, et cette dérive était le seul
symptôme.

### Une seule fenêtre pour vingt ans

Le cadre Pokémon a changé plusieurs fois. La fenêtre, presque pas :

| Série | année | gauche | haut | droite | bas | dérive |
|---|---|---|---|---|---|---|
| `ex` | 2003 | 0,0750 | 0,0958 | 0,9250 | 0,4655 | 2 px |
| `dp` | 2007 | 0,0733 | 0,1091 | 0,9283 | 0,5006 | 12 px |
| `xy` | 2014 | 0,0883 | 0,1152 | 0,9117 | 0,4933 | 1 px |
| `swsh` | 2020 | 0,0850 | 0,1200 | 0,9183 | 0,4727 | 0 px |
| `sv` | 2023 | 0,0850 | 0,1055 | 0,9200 | 0,4727 | 2 px |

**Et la question « un gabarit ou cinq » se tranche en bits, pas en pixels.**
Chaque époque a été éprouvée sous la fenêtre des quatre autres : la distance
moyenne entre empreintes reste entre 31,1 et 32,3 bits, et la paire la plus
serrée entre 16 et 21 — le gabarit d'origine n'est jamais meilleur de façon
significative, et il lui arrive d'être battu par un étranger (`ex` sous la
fenêtre de `sv` : 18 bits de marge, contre 16 sous la sienne). **Les quatre
gabarits sont interchangeables.**

`base` (1999) est le seul à résister : dérive de 66 px entre deux tirages, arête
gauche introuvable. La série y est un regroupement commercial et non une mise en
page — c'est la limite du découpage retenu, pas celle de la méthode.

### La famille à fenêtre haute se fond dans la standard

Son cadre est pourtant visiblement différent : l'illustration va **bord à bord**,
sans trait latéral — le relief de ses arêtes gauche et droite vaut 0,0, ce qui
est la façon dont le banc dit « il n'y a rien à trouver ici ».

Cela ne justifie pas un second gabarit, et c'est la mesure qui le dit :

| Cartes | sous la fenêtre standard | sous la leur |
|---|---|---|
| Fenêtre haute | 32,1 bits, paire la plus serrée **20** | 32,1 bits, paire **19** |
| Standard | 32,0 bits, paire **17** | 29,3 bits, paire **15** |

La fenêtre standard tient entièrement dans l'illustration des cartes à fenêtre
haute : elle y capte donc de l'illustration pure, et fait aussi bien que la
leur. L'inverse est faux — la fenêtre large embarque du cadre sur une carte
standard et lui coûte deux bits de marge. **Un seul gabarit, le plus étroit.**

Le Dresseur, lui, garde le sien : sous la fenêtre standard il perd 1,8 bit de
moyenne et 3 bits sur la paire la plus serrée.

### La famille « pleine page » n'est pas une famille

Découpée par rareté, elle se disloque :

- `Shiny rare` rend (0,0850 · 0,1164 · 0,9183 · 0,4715) avec **0 px de dérive**
  et un relief de 44,8 — c'est le cadre standard, à un pixel près ;
- `Special illustration rare` rend un relief de 3,3 / 1,1 / **0,0** / 1,9 :
  aucune arête, dans aucune direction. L'illustration *est* la carte, et c'est
  la bonne réponse ;
- `Ultra Rare` et `Secret Rare` donnent des fenêtres stables mais distinctes
  d'une série à l'autre.

Autrement dit, « au-dessus du décompte officiel » désigne un **statut
d'impression**, pas une mise en page. C'est ici, et ici seulement, que la rareté
redevient le bon champ — parce que ces traitements *sont* des raretés.

### Les énergies de base : le chiffre qui justifie de les exclure

L'issue posait que ces cartes « produisent des collisions massives ». C'était
juste, et ce n'était pas chiffré. Sur les **175** énergies de base dont la source
publie une image (161 des 336 n'en ont pas), hachées entières faute de fenêtre :

| Mesure | Résultat |
|---|---|
| Empreintes distinctes | 161 pour 175 cartes |
| Cartes dont l'empreinte est portée par une autre | 26 (**14,9 %**) |
| Une *autre* énergie sous le seuil de confiance | 170 (**97,1 %**) |
| **Annoncées à tort et avec assurance** | 21 (**12,0 %**) |
| Paire la plus serrée | **0 bit** |

Le pipeline est mesuré à zéro fausse carte annoncée avec assurance
([`architecture.md`](./architecture.md)). Les accueillir casserait ce résultat
sur 12 % d'entre elles. **Elles sont donc exclues de l'index, et il faut le dire
à l'utilisateur** plutôt que de laisser la reconnaissance en rendre une au
hasard : une énergie de base ne se scanne pas, elle se saisit.

Ce qu'elles coûteraient aux autres est en revanche modeste : sur 147 cartes
ordinaires, **aucune** n'a d'énergie sous le seuil, et 6 seulement en ont une
assez proche pour leur manger leur marge. La plus proche est à 13 bits.

**`category` ne suffit pas à les désigner** : il compte 533 cartes, dont 196
énergies **spéciales** qui, elles, ont une illustration. Les exclure sur ce champ
retirerait 196 cartes illustrées de l'index sans raison. `energyType == Normal`
coupe exactement.

### Deux limites relevées, non résolues

- **La règle du numéro ne s'applique qu'à 92,1 % du catalogue.** 1 662 cartes y
  échappent : 1 602 portent un `localId` non numérique — 1 533 de forme `H01`,
  32 de forme `50b` —, 60 appartiennent à un set sans décompte officiel. Seules
  26 se récupèrent en retirant une lettre finale. Ce huitième-là n'a pas de
  gabarit, et rien ne dit encore ce qu'il faudrait en faire.
- **Une réédition n'est pas une confusion.** La paire la plus serrée du groupe
  Dresseur est à **0 bit** : `sv08.5-121` et `sv04-171` sont la même carte,
  *Professor Turo's Scenario*, rééditée avec la même illustration et le même
  illustrateur. Ce n'est pas un défaut de l'index mais une question d'identité —
  celle que #29 a coûté cher à Riftbound. Pokémon la pose plus simplement : nom
  et effet sont identiques, là où Riftbound réécrivait ses champs d'affichage
  d'une extension à l'autre.

### Le catalogue, en deux requêtes

**20 964 cartes sur carton, 20 964 impressions, 37 402 noms dont 16 438 en
français.** Le point GraphQL rend le tout en **8,95 Mio et 1,5 seconde**, là où
l'API REST carte par carte en aurait demandé 21 000.

Trois pièges de la source, tous silencieux :

- le GraphQL se sert **sans `pagination`**. L'argument existe et son resolveur
  est cassé — `value.indexOf is not a function` — quel que soit le champ ;
- il faut un **POST**. En GET, l'endpoint rend la page GraphiQL : 1,6 Mio de
  HTML qui ressemble à une réponse jusqu'à ce qu'on la parse ;
- **la langue ne passe pas par `Accept-Language`.** La première version l'a
  essayé et a écrit zéro nom français **sans lever d'erreur**. Un catalogue
  amputé de sa moitié française se lit exactement comme un catalogue complet.
  C'est la route REST `/v2/fr/cards`.

**L'identité est l'identifiant TCGdex, pas le nom** : 92 % des cartes de carton
partagent leur nom avec une autre — 112 Pikachu, 69 Évoli. Les fusionner par le
nom en ferait une seule. La source publie une clé stable, `<set>-<numéro>`, qui
est exactement ce que les decklists citent. Conséquence assumée : deux
impressions d'un même Dresseur, interchangeables en jeu, sont ici deux cartes,
donc la complétion sera **sous-estimée** plutôt que surestimée — le bon sens de
l'erreur pour un outil qui annonce un coût.

Le gabarit mesuré plus haut est rangé dans `layout`. La ventilation obtenue
confirme la mesure : `pokemon` 16 158, `trainer` 2 392, `full` 1 901, `energy`
336, `special-energy` 177.

### Les prix : le nom propose, les alias tranchent, la date dispose

Le catalogue ne peut pas les servir. Le type GraphQL `Card` ne porte ni cote ni
identifiant TCGplayer — introspection à l'appui, ses 29 champs sont connus. Les
cotes n'existent que carte par carte : 21 000 appels, écarté. Ce sera donc
TCGCSV, catégorie 3, comme Riftbound et Yu-Gi-Oh.

Le rapprochement se joue à deux niveaux, et un seul est difficile. Dans une
extension, la carte se retrouve **exactement** : TCGplayer publie le numéro
d'impression (`001/102`) que le catalogue porte sous `localId` (`001`), et sur
dix extensions échantillonnées d'un bout à l'autre de l'histoire du jeu, **zéro
numéro en double**. C'est l'**extension** qui pose problème, les deux sources la
nommant librement — « SWSH09: Brilliant Stars » contre « Brilliant Stars ».

Le nom seul rapproche 46 % des extensions. En retirant le préfixe d'ère, 73 %.
Mais ce chiffre était **faux dans le mauvais sens** : la normalisation supprimait
les mots « base set », si bien que *Base Set* (1999) et *SM Base Set* (2017) se
réduisaient tous deux à une clé **vide**, et s'appariaient. Le connecteur aurait
écrit des prix de Soleil et Lune sur des cartes de la première édition. Un
rapprochement de noms ne produit pas que des manques : il produit des **faux
couples**, et le faux couple est le seul des deux qu'aucun écran ne détrompe.

D'où trois temps, dans cet ordre :

| Temps | Rôle | Effet mesuré |
|---|---|---|
| Le **nom** propose | préfixe d'ère retiré, plus un « Base Set » final que TCGplayer ajoute parfois | 143 / 203 |
| Les **alias** tranchent | 26 entrées, toutes systématiques : les promos (« Wizards Black Star Promos » contre « WoTC Promo ») et les collections McDonald's | **170 / 203** |
| La **date** dispose | un couple dont les sorties s'écartent de plus de 200 jours est refusé | 0 couple retenu au-delà de 120 j |

Le troisième temps est un **veto, pas un critère**, et la distinction s'est payée
en mesure : les neuf POP Series portent chez TCGplayer une date de publication
égale au jour de la requête — un remplissage. Exiger la date les aurait toutes
refusées. Une date invraisemblable est donc traitée comme une absence
d'information. La tolérance est large à dessein — *Gym Heroes* sépare ses deux
dates de deux mois — parce qu'elle garde contre dix-huit ans d'écart, pas contre
huit semaines.

**Les finitions, elles, sont celles de Magic.** TCGplayer n'en emploie que trois
pour Pokémon — `Normal` (1 131 relevés), `Reverse Holofoil` (1 150), `Holofoil`
(462) —, ce qui recouvre exactement la distinction ordinaire / brillante que le
modèle porte déjà. C'est la différence avec Yu-Gi-Oh, où `1st Edition` et
`Unlimited` sont des tirages et non des finitions, et où `price_eur_foil` reste
donc vide.

Résultat : **15 894 impressions valorisées sur 20 964 (75,8 %)**, dont 9 599 en
ordinaire et 15 341 en brillant. Les huit plus chères sont les cartes de chasse
connues — Lugia Cristal d'Aquapolis à 3 902 €, Pikachu ☆ d'EX Holon Phantoms à
2 789 €, Umbreon VMAX alternatif à 1 959 € —, ce qui vaut vérification a
posteriori des couples : une extension mal appariée aurait dispersé ces montants
sur des cartes ordinaires.

Les 33 extensions sans prix sont pour l'essentiel les **Trainer Kits**, que
TCGdex découpe en deux demi-decks là où TCGplayer n'a qu'un groupe, et quelques
sets d'énergies. Elles se comptent et s'impriment à chaque exécution : une
couverture partielle doit se voir, un silence ne vaut pas un succès.

### Le corpus de decks : Limitless, et un sigle à trois gisements

`play.limitlesstcg.com/api` répond sans clé. Le filtre `?game=PTCG` est
nécessaire — sans lui l'API est multi-jeux (One Piece, VGC, Gundam, Digimon).
Aucune condition d'utilisation n'est publiée (404 sur `/terms`) : le garde-fou
§IV.9 lui applique donc celles de Scryfall, dont l'attribution visible.

**Et le débit, lui, est limité sans être publié.** La première version du connecteur
n'avait aucune pause : elle a tenu treize mille decks, puis reçu un **429 en
pleine pagination**, et la fenêtre s'est arrêtée aux deux tiers. Rien ne
l'annonçait — ni en-tête de quota, ni page de conditions — et c'est justement ce
que §IV.9 prévoit : une source muette reçoit un débit bas par défaut, sans
attendre qu'elle le réclame. Le connecteur pose donc 0,4 s entre deux requêtes et
retente 429 et 5xx avec une attente doublée à chaque tour, en respectant le
`Retry-After` du serveur quand il en donne un — borné à deux minutes, un délai
d'une heure arrêtant l'import aussi sûrement qu'une exception. Le 404 reste
terminal : une ressource absente ne le devient pas moins en insistant.

**La decklist est structurée, pas du texte.** Trois zones, et chaque ligne porte
un identifiant plutôt qu'un nom :

```json
{"count": 4, "set": "TWM", "number": "128", "name": "Dreepy"}
```

C'est le meilleur des trois cas rencontrés dans le projet. Mieux que Magic, qui
se résout par le nom ; mieux que Yu-Gi-Oh, dont les libellés de zone sont saisis
à la main et coûtaient 305 decks lus strictement. Et ici le nom aurait été
inutilisable : **92 % des cartes Pokémon partagent le leur**.

#### Les formats, choisis par volume et non par notoriété

Relevé sur **6 000 tournois et 321 992 participations**, dix-neuf mois :

| Format | Participations | Retenu |
|---|---:|---|
| `STANDARD` | 307 090 (95,4 %) | oui |
| `CUSTOM` | 4 650 | **non** |
| `GLC` | 3 948 | oui |
| `EX` | 1 720 | oui |
| `BASENEO` | 666 | non |
| `BASEFOSSIL` | 504 | non |
| `EXPANDED` | 362 | oui |

C'est l'**exacte inverse de Yu-Gi-Oh**, où les formats rétro portaient 97 % du
corpus et où le format courant n'avait que trois listes. Ici le format courant
écrase tout. Cela dessert plutôt le produit — Standard tourne sur des extensions
récentes, donc chères et peu probables dans une collection ordinaire — mais c'est
ce que la source publie, et l'inventer serait pire.

`CUSTOM` arrive deuxième en volume et n'est pas importé : c'est un fourre-tout de
règles maison, sans légalité reproductible. Un deck ainsi étiqueté ne dit pas
avec quelles cartes il peut être rejoué, ce qui est précisément ce que le calcul
de complétion doit savoir. Les trente-huit autres libellés relevés pèsent moins
de sept cents participations chacun.

#### Le sigle d'extension : trois gisements, complémentaires

Limitless écrit `TWM`, le catalogue range la carte sous `sv06`. Il faut une
table, et **aucune source ne la donne en entier** :

| Gisement | Sigles | Ce qu'il couvre |
|---|---:|---|
| `abbreviation` du groupe TCGplayer, atteint par le rapprochement déjà mesuré pour les prix | 153 | les extensions modernes (`TWM`, `MEG`, `ASC`) |
| `Set.tcgOnline` du catalogue, le code PTCGO | 37 | l'ère PTCGO (`GRI`, `BUS`, `SUM`) |
| l'identifiant d'extension lui-même | 190 | le reste (`MEE`, `SVE`) |

La première piste essayée seule — `tcgOnline` — donne **0 %** : elle ne couvre
que 113 des 218 extensions et ne connaît ni `TWM`, ni `JTG`, ni `TEF`. Le seul
gisement TCGplayer donne **86,55 %**, et son manque est concentré : `MEE` pèse à
lui seul 6 762 citations, « Mega Evolution Energy » n'ayant pas de groupe
TCGplayer. **Les trois ensemble résolvent 99,88 %** — 204 cartes perdues sur
~170 000, un reliquat très en deçà du seuil de tolérance par deck.

Le premier gisement garde la clé : un identifiant d'extension générique ne doit
pas déloger une abréviation officielle. Et le **veto par date** du rapprochement
des prix protège aussi les decks — un couple faux ne transmet pas son sigle,
ce qu'un test vérifie.

#### Aucun deck partiel n'a été observé

Sur **4 116 listes relevées, toutes font exactement 60 cartes**. Le seuil de
taille (50) ne garde donc contre rien de constaté. Il est posé quand même : une
liste enregistrée à moitié à la source franchirait sans peine le seuil de
résolution — le peu qu'elle contient se résout parfaitement — et s'afficherait
comme presque constructible, le pire défaut possible pour ce produit.

#### Le classement n'identifie pas un deck, et le silence a coûté un quart du corpus

Le connecteur identifiait un deck par `{tournoi}-{placing}`. Le classement
paraît être la clé naturelle d'un standing — il l'est dans un tournoi terminé.
**Limitless rend `placing: null` pour tout joueur non classé**, ce qui est le cas
de tous les participants d'un tournoi encore en cours, et des joueurs sortis en
route. Tous recevaient alors la clé `{tournoi}-None`, et l'`ON CONFLICT DO
UPDATE` qui rend l'ingestion rejouable les écrasait l'un après l'autre : il n'en
restait qu'un par tournoi.

Le défaut ne s'annonçait pas. Le connecteur lisait, parsait et résolvait ces
decks correctement ; il rendait même un compte juste de **ce qu'il avait
écrit** — 23 488 — sans que rien ne dise que la base n'en portait que **18 041**.
C'est le rapprochement des deux nombres qui l'a révélé, et non une erreur.

**La correction est le pseudonyme**, présent sur tous les standings et unique
dans un tournoi (vérifié : 229/229 distincts, aucun absent). Il a une seconde
vertu que le classement n'a pas : il est **stable dans le temps**. Un joueur non
classé pendant le tournoi est classé une fois qu'il est fini ; une clé bâtie sur
le classement passerait de `null` à `5` et la réingestion créerait un doublon au
lieu de remplacer le deck déjà écrit. Deux tests tiennent les deux propriétés.

La leçon rejoint celle de #29 sur Riftbound et celle des noms Pokémon : **une
identité ne se dérive pas d'un champ d'affichage**. Le classement est un
résultat, pas un identifiant — il change, il manque, et il se répète.

**La course qui suit la correction le prouve sur pièces** : 23 574 decks
annoncés, 23 574 en base, rapport exact. Le corpus gagne **5 533 decks, soit
+30,7 %**, sans qu'une seule requête de plus ait été faite à la source — ils
étaient lus depuis le début.

Le compteur de progression, lui, ne pouvait pas le voir : il mesure ce que le
connecteur **écrit**, jamais ce qui survit à l'écriture. Les deux courses
écrivent le même nombre de decks à dix près ; seule la seconde les conserve.
Un compteur d'écritures n'est pas un compteur de résultats, et le seul contrôle
qui les sépare est de compter les lignes en base à la fin.

#### Le corpus ingéré, fenêtre de trente jours couverte

| | |
|---|---|
| Decks | **23 574** (602 121 lignes, aucune orpheline) |
| Tournois | 334 |
| Fenêtre | 15 juillet → 14 août |
| Standard | 23 431 · GLC 105 · Expanded 24 · EX 14 |
| Écartés (trop lacunaires) | 201, soit 0,8 % |

C'est le plus gros corpus de decks du projet, devant Yu-Gi-Oh (3 935),
Riftbound (2 500) et Magic (1 028).

Standard pèse 99,4 % du corpus réellement importé, plus encore que les 95,4 %
relevés sur dix-neuf mois. Cela dessert le produit — Standard tourne sur des
extensions récentes, donc chères et peu probables dans une collection ordinaire
— mais c'est ce que la source publie.

**Les sigles ont été réglés, et la cause n'était pas celle qu'on croyait.** Le diagnostic disait « `ASR` pointe sur la *Trainer Gallery* au lieu de l'extension mère » — vrai, mais la cause tenait en trois défauts distincts.

Le premier était dans l'ordre du parcours : la table essayait les trois gisements **extension par extension**, si bien qu'une extension rencontrée tôt posait son identifiant générique avant qu'une autre n'ait pu poser son abréviation officielle. La priorité des gisements n'était respectée qu'à l'intérieur d'une extension. Le parcours se fait désormais **gisement par gisement**.

Le deuxième : `swsh10` et `swsh10.5tg` déclarent **toutes deux** `tcgOnline = "ASR"` — côté jeu numérique, les cartes de la Gallery font partie du même produit. Il n'y avait donc rien de faux à corriger, mais un choix à faire, et le champ qui l'aurait permis (`cardCount`) n'était pas demandé par la requête GraphQL. Il l'est, et **un sigle désigne désormais plusieurs extensions** : leurs plages de numéros sont disjointes (1…216 contre TG01…TG30), les indexer ensemble ne perd rien.

Le troisième ne se réglait ni par l'ordre ni par la taille : pour `LOR` et `SIT`, **seule l'annexe porte le code**, la mère n'en déclare aucun. Il n'y avait qu'un candidat, donc rien à départager — la mère se déduit du nommage (`swsh11.5tg` → `swsh11`), avec deux gardes : elle n'est ajoutée que si le catalogue la connaît, et jamais en remplacement de l'annexe.

Mesuré sur une fenêtre de trois jours (2 468 decks) : **49 267 codes d'impression indexés contre 43 361** (+13,6 %), **4 sigles non résolus contre 103**, et **un seul deck écarté** contre 0,9 % du corpus. Les quatre restants — `MEP`, `SP`, `BWP` — sont des promos anciennes qu'aucun gisement ne nomme.

**Sur le corpus complet réingéré**, 45 sigles restent non résolus, très largement dominés par `TRR` (192 + 114 + 102 + 35 occurrences pour ses quatre premiers codes) puis `P5` et `MEP` — des promos qu'aucun des trois gisements ne nomme. Ils coûtent 201 decks écartés, soit 0,8 % du corpus.

### Le gabarit de deck, mesuré sur 17 295 decks Standard

| | médiane | écart interquartile |
|---|---|---|
| **corps du deck** | **60 cartes** | **0,0** |
| dresseurs | 51,7 % | 6,7 |
| pokémon | 33,3 % | 6,7 |
| énergies | 15,0 % | 6,7 |
| supporters | 16,7 % | 3,3 |
| objets | 26,7 % | 6,7 |
| stades | 5,0 % | 3,3 |
| exemplaires d'une même carte | **4** | |

**La taille est le chiffre le plus net du projet, tous jeux confondus** : écart interquartile 0,0, pas un deck du corpus ne s'écarte de 60. Et les trois familles portent le même écart de 6,7 points — une régularité qu'aucun autre jeu n'affiche sur ses familles principales.

**Ce jeu ne dose que trois choses**, et elles partitionnent le deck : Pokémon, Dresseurs, Énergies. Les sous-familles Dresseur s'y ajoutent au lieu de le découper — un Supporter reste un Dresseur —, comme une créature Magic qui produit du mana compte dans deux rôles.

**Aucune courbe, et c'est mesuré plutôt qu'omis.** L'ingestion range les points de vie dans `cmc` faute d'un champ dédié : 70, 60 et 80 sont les valeurs les plus fréquentes du catalogue. Découper les PV en paliers décrirait la robustesse des créatures, pas une contrainte de construction — rien ne se paie dans ce jeu, on pose une énergie par tour et c'est tout. C'est le piège du Niveau de Yu-Gi-Oh en pire : là-bas au moins, le Niveau conditionne l'invocation. Le banc a été rendu capable d'un jeu **sans courbe**, ce qu'il ne savait pas faire — la chaîne vide produisait un `, ,` que Postgres refuse.

**L'énergie de base est illimitée**, comme le terrain de base à Magic, et elle est exclue du décompte d'exemplaires : l'y laisser aurait fait annoncer un plafond de vingt là où la règle en autorise quatre. Un plafond qui se lit comme une infraction alors qu'il décrit une exception est pire qu'une absence de mesure.

**Standard seul.** Il porte 99,5 % du corpus importé (17 295 decks sur 17 380) ; GLC en a 58, EX 14, Expanded 9. GLC est d'ailleurs mesuré à **1 exemplaire maximum** — c'est un format singleton — mais 58 decks ne font pas un gabarit.

**Ce que l'accueil du jeu a demandé en plus du gabarit** : `Game.pokemon` n'existait pas côté application. Le catalogue, les prix, les decks et l'index d'empreintes étaient en base sans que le jeu puisse être *sélectionné*. Trois `switch` sur `Game` l'ont signalé en refusant de compiler, et l'un d'eux affichait encore « Yu-Gi-Oh : 14 491 cartes, aucun deck » — un texte devenu faux sans que rien ne le dise.

### Ce qui reste dû

- l'**index d'empreintes**, et c'est le mur : ~21 000 images, soit plusieurs
  heures à débit nominal et une cinquantaine à celui qu'on mesure ici. À lancer
  en tâche de fond, sur plusieurs sessions ;
- une **carte de papier**. Aucune n'a été photographiée, et c'est le carton qui a
  livré les deux derniers défauts de Riftbound. Le propriétaire de la collection
  n'a pas de cartes Pokémon : cette validation dépendra d'un tiers ;
- ~~le gabarit de deck~~ — **mesuré et câblé**, voir ci-dessous ;
- les **103 sigles non résolus** ci-dessus, dont le diagnostic est fait : les
  mini-extensions volent la clé de leur extension mère.

---

## 9. Wankul — un catalogue sans prix, sans decks et sans images

Cinquième jeu, et le seul ingéré **sous autorisation nominative** de son
éditeur, LINK DIGITAL SPIRIT : ses conditions (article 4) interdisent sinon
toute collecte automatisée, sans condition de finalité. C'est le cas EDHREC du
garde-fou §IV.1, levé par un accord explicite — le retirer remettrait la source
hors la loi du projet.

### Trois manques structurels, et non trois retards

| | Pourquoi |
|---|---|
| **Aucun prix** | Aucune source ne publie de cote carte par carte — cherché, voir ci-dessous. `card_prints.price_eur` reste nul, et la colonne est laissée **hors de la requête** d'écriture : y ranger un zéro se lirait « cette carte ne vaut rien » là où la vérité est « personne ne la cote ». |
| **Aucun deck** | Nul corpus de listes n'est publié. Le constructeur n'a donc rien à proposer. |
| **Aucune illustration servie par la source** | Le CDN rend `403 Hotlinking not allowed`. Mesuré dans les trois cas : sans `Referer`, avec un `Referer` étranger, **et avec celui de `wankul.fr`**. Ce n'est pas un blocage par en-tête que l'on contournerait — c'est une politique. L'accord de l'éditeur couvrant l'hébergement, les rendus sont versés dans un bucket ; voir plus bas. |

La collection s'y saisit, s'y range, s'y compte et **s'y regarde** ; elle ne s'y
valorise pas.

### Les prix : quatre pistes suivies, aucune n'aboutit

L'absence de cote était **affirmée** — « le jeu se vend en direct par son
éditeur, il n'existe aucune cote carte par carte » — sans qu'aucune recherche ne
soit consignée. Elle l'est maintenant, et la conclusion tient, mais pour des
raisons plus étroites que ce qui était écrit.

| Piste | Résultat |
|---|---|
| **TCGCSV / TCGplayer**, qui cote déjà Riftbound, Yu-Gi-Oh et Pokémon | Absent des **90 catégories**, sous ses quatre orthographes (`wankul`, `wankil`, `laink`, `terracid`). Et l'index **ne couvre aucun jeu du marché français** : son silence ne prouve pas l'absence de marché, seulement qu'il n'indexe pas celui-ci. |
| **wankul.trade**, plateforme d'échange citée par les moteurs | **Le domaine n'existe plus** (NXDOMAIN). Résultat de recherche périmé. |
| **Coleka**, qui catalogue bien le jeu (182 cartes Origins, 162 Campus) | Les fiches de carte **n'affichent aucun prix** en visiteur. Ses fonctions de valeur sont derrière un compte, et son `robots.txt` interdit explicitement `/sale/`, `/shop/`, `/marketplace/`, `/exchange/` — la valeur vit précisément là où le crawl est refusé. |
| **eBay, Vinted, LeBonCoin, Beebs** | Des annonces, pas une cote — voir ci-dessous, la piste a été instruite et le mur n'est pas celui qu'on attendait. |
| **Cardmarket**, seul index européen sérieux | **Absent de ses 20 jeux**, et `/en/Wankul` rend 404. Vérifié dans un navigateur : son `403` sur une requête simple était une détection de robot, pas une absence de page — l'écarter sur ce seul motif aurait été une erreur. |

Ce qu'il faut retenir pour la suite : **ce n'est pas « il n'existe pas de
marché »** — il y en a un, sur Vinted et eBay — c'est « aucun index public ne le
cote carte par carte, et les endroits où des prix circulent sont soit fermés,
soit interdits au crawl ». La différence compte : le jour où une place de marché
référencera le jeu, la porte se rouvre sans rien changer au modèle, `price_eur`
étant déjà là et déjà nul.

**Une observation faite au passage, sans rapport avec Wankul** : Cardmarket
*couvre* Riftbound. Les prix Riftbound du projet viennent aujourd'hui de TCGCSV
en dollars, convertis au taux BCE (§ 6) ; Cardmarket les donnerait en euros
relevés. À mettre en regard de ses conditions, qui sont restrictives — c'est une
piste, pas une recommandation.

### Les places de revente : l'identification marche, le reste non

La piste « moissonner eBay, Vinted, LeBonCoin » a été instruite plutôt
qu'écartée d'un principe, et **elle échoue là où on ne l'attendait pas**.

**Ce qui marche, et c'est contre-intuitif : l'identification.** On supposait que
des intitulés libres seraient inexploitables. Mesuré sur neuf annonces eBay
réelles, **huit se résolvent exactement** vers une carte du catalogue :

```
Carte Wankul - Legacy - Alpiniste - Légendaire Bronze - #166 - FR FOIL
   -> legacy #166 = « Alpiniste », rareté « Légendaire Bronze »
Carte Wankul Stellar (s4) DÉNUÉ D'ÉCLAT / LÉGENDAIRE ARGENT #178
   -> stellar #178 = « DÉNUÉ D'ÉCLAT », rareté « Légendaire Argent »
```

Les vendeurs écrivent l'extension **et le numéro** ; le nom et la rareté servent
alors de contrôle croisé, et ils concordent. C'est le rapprochement à deux
signaux que le projet exige ailleurs. La neuvième est une carte « Gagnant Ticket
Or », qui n'a pas de numéro — un cas identifiable comme tel, pas un faux.

**Ce qui ne marche pas, et qui décide :**

- **Le droit.** Moissonner le HTML est interdit par les conditions des trois
  sites. Les API sanctionnées, elles, ne donnent pas la donnée voulue : celle
  d'eBay qui expose les **ventes réalisées** (Marketplace Insights) est
  « restricted and not open to new users », exactement le mur rencontré chez
  Cardmarket. Vinted et LeBonCoin n'exposent rien.
- **La nature du chiffre.** Une annonce est un **prix demandé**, pas une vente.
  Le projet a déjà tranché cette question en choisissant `marketPrice` plutôt
  que `lowPrice` chez TCGCSV — « le prix bas est une annonce isolée, carte
  abîmée ou erreur de saisie ». Ici *tout* serait une annonce isolée.
- **Le volume et les lots.** ~1 600 annonces pour 958 cartes, concentrées sur
  les rares ; la majorité du catalogue resterait sans rien. Et une bonne part
  est vendue en lots (« 20,00 € à 40,00 € ») ou aux enchères, d'où aucun prix
  par carte ne s'extrait.

**Ce qui resterait légitime, et ce que ce serait.** L'API Browse d'eBay est
ouverte et gratuite, et rend les **annonces en cours**. Elle permettrait
d'afficher « en vente aujourd'hui : de X à Y € », ce qui est une information
honnête — mais ce n'est **pas** une cote, et cela n'a rien à faire dans
`price_eur`. Le garde-fou tient dans les deux sens : une carte sans cote compte
pour 0 €, jamais pour une estimation inventée ; et une estimation, si elle est
un jour affichée, doit se présenter comme telle et sous un autre nom.

### Les vignettes sont hébergées — la seule source dans ce cas

La règle du projet est de ne jamais réhéberger l'illustration d'une source : on
pointe l'URL de l'éditeur et l'on n'en garde rien (§IV.3, §IV.9). Wankul est
l'exception, et elle repose entièrement sur l'accord nominatif de LINK DIGITAL
SPIRIT, qui couvre la copie comme il couvre la collecte.

Le bucket `card-art` est créé par migration, public en lecture, plafonné à
2 Mio par objet. **Ce n'est pas un cache générique** : un autre jeu n'y entre pas
parce que son CDN a eu un hoquet, il y entre avec son propre accord — d'où le
préfixe de jeu dans le chemin, qui force la question à chaque fois.

**Le chemin calque celui de Scryfall, et c'est ce qui a évité d'écrire du
Dart** :

```
.../object/public/card-art/wankul/normal/<illustration_id>.jpg   430 × 600, 52 Kio
.../object/public/card-art/wankul/small/<illustration_id>.jpg    146 × 204,  9 Kio
```

L'application affiche déjà une vignette légère avant la grande en échangeant le
segment de taille (`previewCardImage`). Calquer la convention donne les deux
paliers gratuitement ; s'en écarter aurait demandé un cas particulier dans un
module que les cinq jeux partagent. Total versé : **1 916 objets, 65,1 Mio**.

**L'URL est dérivée, jamais relevée.** Elle se calcule depuis `illustration_id`
sans savoir ce que le bucket contient : l'ordre des deux courses est libre, et
une image pas encore versée rend 404 — ce qu'un classeur affiche comme une case
vide, soit exactement l'état d'avant. Surtout, l'ingestion la recalcule à chaque
course : sans cela, une réingestion aurait fait retomber `art_crop_url` sur le
CDN bloqué et rendu muet un classeur qui fonctionnait.

**Les Terrains sont versés couchés**, dans leur sens de lecture. Verser la
vignette portrait du Wankuldex aurait rempli la case sans rien faire, mais
rendrait le texte illisible en plein écran — la vue où il compte. C'est
l'application qui tourne la carte là où il le faut, et nulle part ailleurs :
voir ci-dessous.

### Une case de classeur tourne les cartes couchées

Le défaut n'a pas été trouvé en relisant du code mais en **composant une page de
classeur depuis les images réellement servies**. Une case est debout (0,72), une
carte couchée fait 1,4 : `BoxFit.cover` jetait les deux tiers de la largeur, et
ce qui restait était moitié illustration moitié pavé de texte.

**Il était antérieur à Wankul.** Riftbound sert des champs de bataille couchés
depuis toujours et souffrait exactement du même recadrage — en pire, ses noms
étant collés au bord. 210 cartes étaient concernées : 64 champs de bataille et
146 Terrains.

`CardImage.uprightInCell` tourne la carte d'un quart de tour anti-horaire, celui
que le Wankuldex applique à ses propres vignettes. Le résultat est exact au
pixel près : une carte couchée tournée fait 63 × 88, c'est-à-dire la case.

**L'orientation se lit sur l'image, jamais sur un champ.** Faire descendre
`cards.layout` jusqu'à la case aurait demandé un RPC, quatre classes du modèle
et leurs tests, pour une information que l'image porte déjà — et qu'elle porte
*juste*, là où un champ peut se désynchroniser de ce qu'on affiche. C'est aussi
ce qui règle les deux jeux du même geste, sans que ni l'un ni l'autre ne soit
cité dans le widget.

La sonde est la **vignette légère**, pas la grande : c'est elle qui s'affiche en
premier, et mesurer la grande ferait pivoter la case sous les yeux au moment où
celle-ci arrive. Les deux paliers ayant les mêmes proportions — le contraire a
été le défaut corrigé plus haut —, la sonde est fiable.

L'option est **explicite à chaque appel**. En plein écran ou dans une ligne de
liste, tourner la carte rendrait son texte illisible pour rien : l'espace y est
libre. La tuile d'étagère non plus ne tourne rien — c'est une bannière large, où
une image couchée tient mieux que debout.

**Un défaut trouvé en regardant ce qui avait été versé**, et non en relisant le
code : le palier léger imposait une boîte de 146 × 204, ce qui écrasait les 146
Terrains. Leur grande sortait en 600 × 430 et leur vignette en 146 × 204 — deux
proportions pour la même carte, que l'application pose l'une sur l'autre sans
transition (`gaplessPlayback`). La déformation se serait vue en mouvement. Le
palier léger contraint désormais le **plus grand côté** ; un test le verrouille
dans les deux orientations.

### L'index d'empreintes est bâti depuis un dossier local

Puisque les images ne peuvent pas être téléchargées, `app.vision.local_index`
lit un dossier de rendus déjà présents sur le disque, calcule les empreintes et
écrit les mêmes lignes que `index_builder`. **Rien de la chaîne de calcul n'est
réimplémenté** — `box_for`, `crop`, `dhash` sont les mêmes — sans quoi les
empreintes locales et téléchargées ne se compareraient plus, alors qu'elles
cohabitent dans la même table.

Le rapprochement fichier ↔ impression passe par **l'UUID que la source donne à
chaque rendu** : elle nomme ses fichiers `<uuid>_main.jpg` et publie ce chemin ;
l'ingestion en tire `card_prints.illustration_id`. Mesuré : 958 fichiers, 958
impressions, aucun orphelin d'un côté ni de l'autre.

Deux pièges propres à un dossier, qu'un téléchargement n'a pas :

- **308 fichiers sur 1 268 ne sont pas des illustrations** — masques
  holographiques `opw_*`, `diag_mask_*`, `metal_inverted`. Ce sont des images
  valides : un masque s'ouvre, se hache, et produirait une entrée d'index
  parfaitement fausse dont rien ne dirait qu'elle l'est. Le filtre porte sur le
  suffixe `_main`, pas sur l'extension ;
- **`art_crop_url` ne désigne pas le fichier**. Il porte le rendu *paysage* pour
  un Terrain — celui qui montre la carte dans son sens de lecture, et qui n'est
  pas dans le dossier. C'est `illustration_id` qui fait le lien, et lui seul.

### Les Terrains : une rotation, deux maquettes

Les 146 Terrains sont des cartes **couchées**, mais leur rendu principal les
montre debout, tournées d'un quart de tour — c'est la vignette du Wankuldex.

**Un seul quart de tour horaire les redresse toutes.** Vérifié en regardant les
146 redressées : aucune n'est à l'envers.

**Il existe deux maquettes**, distinguées par la position du bloc titre +
bandeaux, et **elles ne sont pas deux rotations l'une de l'autre** :

| Maquette | Bandeaux | Cartes | Fenêtre d'illustration |
|---|---|---|---|
| bandeaux en haut | 0,1700 → 0,4150 | 77 | (0,0440, 0,4150, 0,9536, 0,9385) |
| bandeaux en bas | 0,6300 → 0,8750 | 69 | (0,0440, 0,0615, 0,9536, 0,6300) |

Un demi-tour placerait le second bloc à 0,5850 → 0,8300, or il est à 0,6300 →
0,8750 : **0,045 d'écart**. C'est ce qui oblige à déclarer deux cadres plutôt
que de compter sur les deux quarts de tour que la reconnaissance essaie déjà.
Le bloc a en revanche exactement la même hauteur (0,2450) des deux côtés — c'est
le même gabarit de bandeaux, posé ailleurs, et cette égalité rend chaque mesure
crédible par l'autre.

**Ce qu'une mesure précédente avait conclu, et pourquoi c'était faux.** L'image
moyenne de 150 Terrains montrait deux jeux de bandeaux symétriques ; on en avait
déduit que le lot mêlait les deux sens de rotation, et ajouté un demi-tour
conditionnel au redressement. Les deux jeux venaient des deux maquettes : le
demi-tour conditionnel **introduisait** le résidu mal orienté qu'il croyait
supprimer. Trois tentatives s'y sont épuisées avant qu'on regarde les cartes.

**La maquette se lit sur l'image**, la source ne publiant rien qui la trahisse —
ni le champ `orientation`, déjà pris en défaut, ni la rareté, ni l'effigie. Deux
hypothèses sont confrontées aux quatre traits que les bandeaux dessinent, chacune
notée par la **force des traits × la platitude des bandeaux** : la force seule se
laisse imiter par une texture rayée (« TERRADOLLAR » est un billet de banque), la
platitude seule par un ciel. Pire cas mesuré : 1,28 ; les douze décisions les
moins tranchées ont été vérifiées à l'œil, toutes justes.

Se tromper ne coûte pas un peu de précision : la fenêtre de l'autre maquette
contient le bloc de texte **en entier**.

### Le gabarit debout : un échantillon plus grand ne fait pas un meilleur gabarit

La fenêtre verticale avait été mesurée sur 11 cartes. Reprise sur les 812 du
catalogue, le gradient de la moyenne donne (0,0450, 0,0321, 0,9517, **0,7024**)
au lieu de (0,0483, 0,0298, 0,9450, **0,6857**). Elle est **moins bonne** : sous
elle, l'index annonce à tort avec assurance 1,04 % des cartes contre 0,84 %.
Les 0,017 de hauteur supplémentaires mordent sur le haut du pavé de texte, qui
est identique sur toutes les cartes — de l'information dépensée en constante.
Le gabarit d'origine est conservé.

### Ce que l'index donne, et ce que le chiffre brut disait de travers

958 empreintes, aucun échec. Mesuré par `app.measure.art_collisions` :

| | brut | suffixe de produit retiré |
|---|---|---|
| annoncées à tort avec assurance, sous un autre nom | 3,44 % | **0,84 %** |

L'écart n'est pas une amélioration du pipeline, c'est une correction de la
mesure. 46 empreintes portent un nom suffixé — « CAMIONNEUR - PGW 2024 »,
« SKIEUR - Starter Pack Civilisations » — qui désigne **l'emballage et non la
carte** : ce sont des promos reprenant l'illustration d'une carte ordinaire, à
0 bit près. Les compter comme des cartes différentes reprochait au scan de bien
reconnaître l'image qu'il a sous les yeux — exactement le piège des rééditions
Pokémon (7,36 % annoncés contre 1,49 % réels).

**Le retrait ne peut pas être global, et c'est mesuré** : chez Yu-Gi-Oh il
fusionnerait 101 clés — « Raidraptor - Fuzzy Lanius » et « Raidraptor - Skull
Eagle » sont deux cartes, pas deux tirages —, chez Riftbound 41. La règle est
donc bornée par jeu (`GAMES_WITH_VARIANT_SUFFIX`), et ajouter un jeu demande de
vérifier qu'aucune fusion ne réunit deux illustrations distinctes.

### La brillance : trois candidats, et le troisième tient

Wankul n'a ni prix ni `subTypeName`. Il a fallu chercher, et **les deux premiers
signaux étaient faux** :

1. **La rareté.** `/api/wankuldex/rarities` publie `dropRate`, `horsSerie` et
   `sortOrder` — aucun indicateur de finition. Deux noms sur vingt-sept
   contiennent « holo », ce qui manquait les Légendaires, les Edition Gold et les
   DUO : 111 cartes perdues.
2. **`holoMasks`.** Le nom promet exactement ce qu'on cherche, et c'est un faux
   ami **par incomplétude** : 48 cartes en portent quand 71 « Ultra rare holo »
   n'en ont pas. Le site n'a produit l'animation que pour une partie du
   catalogue ; l'absence du calque ne dit pas que la carte est mate.
3. **`imageUR`** — un rendu de remplacement, présent sur **200 cartes**. C'est
   lui qui décide.

**Ce qui rend `imageUR` fiable, ce sont deux recoupements sans une exception :**

| Contrôle | Résultat |
|---|---|
| cartes déclarant un `foilEffect` qui ont aussi `imageUR` | **48 / 48** |
| cartes à `imageUR` parmi Commune, Peu Commune, Rare, Terrain | **0 / 720** |

Et les `holoMasks` **sont** bien des calques de brillance, vérifié en les
ouvrant : bandes diagonales, pluie de paillettes, masque isolant les éléments
imprimés en métal, décomposition d'un reflet en trois bandes (`opw_edges`,
`opw_band_mid`, `opw_highfreq`). On n'écrit pas ça pour une illustration
alternative. La source nomme d'ailleurs le patron : `holo`, `dot`, `diag`.

**Ce qui est prouvé, et ce qui est extrapolé — la distinction compte.**

| | Cartes | État |
|---|---|---|
| Ultra rare holo 1 · 2, Légendaire Bronze / Argent / Or, Edition Gold, DUO | **184** | **prouvé** : chacune de ces sept raretés a au moins une carte dont la source nomme l'effet, layers à l'appui |
| Starter Packs, Édition Spéciale, PGW 2025, Noël 2023, Gemmes Pack | **16** | extrapolé : `imageUR` présent, aucun effet nommé dans le lot |
| Gagnant Ticket Or | 19 | **non brillante** — ni `imageUR` ni effet, malgré son nom |
| Commune, Peu Commune, Rare, Terrain | 720 | non brillantes |

La brillance n'est donc jamais déduite d'un lot voisin : elle est établie **dans
le lot même** pour 184 cartes sur 200. Les 16 restantes viennent de
sous-collections Hors Série où `imageUR` est **partiel** — 2 sur 7, 2 sur 6, 2
sur 4 — ce qui est précisément ce qui montre que le signal est une propriété de
la carte et non du lot.

**Et la liste ne porte jamais les deux valeurs.** Chez Wankul il n'existe pas de
« Mort-Vivant ordinaire » et de « Mort-Vivant brillant » : une carte est brillante
ou elle ne l'est pas. Riftbound et Pokémon, à l'inverse, en déclarent couramment
deux.

### Ce qui reste dû

- une **carte de papier**. Le format 63 × 88 est présumé, non vérifié sur
  carton : c'est la seule entrée de `CARD_ASPECTS` dans ce cas. Elle trancherait
  aussi les 16 cartes dont la brillance est extrapolée ;
- un **regard sur l'appareil**. Tout ce qui précède a été vérifié en composant
  des pages depuis les images réellement servies, ce qui a livré deux défauts —
  mais aucune capture n'a encore été prise sur le téléphone.

---

## 10. Star Wars Unlimited — la mesure, avant toute ingestion

**Rien de SWU n'est en base, et ce n'est pas le but de ce chantier.** Comme #28
pour Pokémon, il s'agit d'abord de savoir ce que les sources publient vraiment,
et à quel prix. Tout ce qui suit est relevé par quatre bancs —
`api/app/measure/swu_taxonomy`, `swu_decks`, `swu_art_window`, et les deux
sondes `swu_probe` / `swumetastats_probe` — et non repris d'une documentation.

### La source officielle est ouverte techniquement, et fermée contractuellement

L'API qui alimente le site de l'éditeur (`admin.starwarsunlimited.com`, un
Strapi) ne demande aucune clé, son `robots.txt` n'interdit rien, et elle sert
**le français** — « Ami Fidèle » pour *Faithful Friend* — ainsi que deux champs
que les jeux précédents ont payé cher : `artFrontHorizontal`, qui déclare
l'orientation, et `hasFoil`, qui déclare la finition.

Ses conditions la ferment. Verbatim, dans les *Terms of Use* d'Asmodee North
America / Fantasy Flight Games :

> You will not transmit any bugs, viruses, trojan horses, **bots, scrapers**, or
> any like or related programming through or to the Website.

C'est le cas EDHREC du garde-fou §IV.1 — accessible, interdit — et le cas
Wankul avant l'accord : la porte existe, elle se demande à un humain. Tant
qu'elle n'est pas ouverte, **le français est hors d'atteinte pour ce jeu**, qui
rejoint donc Riftbound : l'illustration prime sur le nom, un nom lu sur un
carton français ne correspondant à rien dans un catalogue anglais.

### Les deux sources retenues, et sous quelles conditions

| Pilier | Source | Statut |
|---|---|---|
| Catalogue | `api.swu-db.com` | Aucune condition publiée — `/terms` et `/about` rendent 404, le domaine n'a pas de `robots.txt`, et la page `/api` documente publiquement l'API. **§IV.9** : on lui applique celles de Scryfall |
| Decks | `swumetastats.com/api` | « a public read-only REST API […] require no authentication », `robots.txt` permissif, pas de `/terms`. **§IV.9** également, plus le respect de son 429 |
| Prix | TCGCSV catégorie **79** | Déjà couvert par les connecteurs existants |

**Trois autres portes ont été essayées et refermées**, ce qui vaut d'être écrit
pour ne pas les rouvrir : **TopDeck.gg** — la source de Magic, Riftbound et
Yu-Gi-Oh — *connaît* le jeu, 36 tournois en `Premier` et 6 en `Twin Suns` sur un
an, mais **aucun ne porte de decklist** ; **Limitless**, la source de Pokémon,
ne couvre pas SWU (ses jeux, relevés sur 500 tournois : `PTCG`, `VGC`, `POCKET`,
`OP`, `DCG`, `GUNDAM`) ; **SWU Stats** publie une API Melee sans clé, mais ses
« decks » portent le leader, la base et le résultat, jamais la liste des cartes
— c'est un corpus d'archétypes.

### Le catalogue — 8 424 impressions, et quatre pièges déjoués avant l'écriture

38 extensions publiées, dont deux vides (`SOROPJ`, `SS2J`) et **une
injoignable** : `TASH` rend un 502 **déterministe**, mesuré trois fois de suite
en une demi-seconde quand `TSOR` répond 200. Une extension injoignable n'est pas
une extension vide, et les confondre ferait passer un trou de mesure pour un
fait du catalogue — le banc les compte séparément, et la sonde met l'échec en
cache pour ne pas repayer 31 secondes de reprise à chaque lancement.

**L'identité est le titre imprimé, et rien d'autre.** 8 424 impressions pour
**2 180 titres** (nom + sous-titre), dont 320 réimprimés d'une extension à
l'autre par les promos OP. Un seul titre est porté par deux cartes réellement
différentes — « Snapshot Reflexes », qui est un Event et un Upgrade — là où
Riftbound en comptait 80.

**`cid` ressemble à une clé de carte et n'en est pas une**, même piège que le
`riftbound_id` de #29 : 1 770 titres en portent deux, 249 en portent trois, et
**5 446 impressions n'en portent aucun**. Le couple (extension, numéro), lui,
désigne une impression unique — zéro doublon sur tout le catalogue.

**Les jetons se lisent sur le type, pas sur le nom d'extension.** Six cartes
portent un `Type` commençant par `Token`, et elles se répartissent entre `TSOR`
— dont le nom porte « Tokens » — et **`GG` (Gamegenic), dont le nom ne dit
rien**. Un type est un vocabulaire, un nom d'extension un libellé d'affichage
que rien n'oblige à rester exact.

**`VariantType` porte deux choses à la fois**, et les confondre gonflerait
`card_prints` de moitié. Ses 61 valeurs mêlent un *traitement d'impression*
(`Normal`, `Hyperspace`, `Showcase`, `Prestige`, `OP Promo`…) et une *finition*
(le suffixe ` Foil`). La preuve que ce sont bien deux finitions d'une même
impression est dans les identifiants TCGplayer : sur 880 partagés, **436 sont
`Foil` + `Normal` et 433 `Hyperspace` + `Hyperspace Foil`** — TCGplayer n'y voit
qu'un seul produit. Une fois la finition retirée, **878 de ces 880 ne recouvrent
qu'un seul traitement** ; les deux qui restent sont des anomalies de la source,
un identifiant portant deux impressions réellement distinctes.

**Et la source rompt sa propre règle de suffixe** : la version brillante de
`Normal` ne s'appelle pas « Normal Foil » mais `Foil` tout court. Lire un
suffixe et rien d'autre classe **1 148 impressions** parmi les ordinaires, et le
rapport annonce « aucune brillante en traitement standard » avec l'assurance
d'une mesure. C'est un test qui l'a attrapé, pas une relecture.

Une fois les deux notions séparées, les 61 valeurs se ramènent à **57
traitements**, dont quatre déclarent une brillante :

| Traitement | ordinaires | brillantes |
|---|---|---|
| `Normal` | 2 277 | **1 148** |
| `Hyperspace` | 2 044 | **1 628** |
| `Prestige` | 211 | **211** |
| `OP Promo` | 161 | **100** |
| les 53 autres | — | 0 |

**Par carte : 1 605 existent dans les deux finitions, 575 en ordinaire
seulement, et aucune en brillante seulement.** Quatre entrées brillantes n'ont
pourtant pas de jumelle ordinaire — les Bases Gamegenic `GG-1` à `GG-4`, qui
n'existent qu'en `Hyperspace Foil` : c'est la figure des 704 impressions
Riftbound cotées en brillante seulement, à une échelle négligeable.

**Le chaînage vers les prix est presque complet** : `tcgplayerId` sur
**8 366 / 8 424 (99,3 %)**. Les manques sont concentrés — `ASHOP` entière (40),
`ASH` (16 sur 925) — et non répartis : c'est un retard de la source, pas un trou
de couverture, la même figure que les 227 `VEN` de Riftbound.

### L'orientation ne se lit ni sur un champ, ni sur un échantillon

SWU imprime en travers ses **Leaders** — 445 impressions, toutes double-face —
et ses **Bases**. C'est la configuration Riftbound, qui vaut à ce jeu le
bénéfice du travail déjà fait sur les deux orientations.

Mais le type ne suffit pas à prédire l'orientation, et **un échantillon ne peut
pas établir qu'un groupe est homogène**. Cinq rendus tirés parmi les 85 Bases
`Hyperspace` sont tous tombés couchés ; la passe exhaustive en trouve **cinq
imprimées debout**. Une fenêtre mesurée sur un lot qu'on croit homogène et qui
ne l'est pas décrit une carte qui n'existe pas. Le banc vérifie donc
exhaustivement les seuls groupes où un rendu couché apparaît — la masse du
catalogue (Unit, Event, Upgrade : debout sans exception) n'est pas
retéléchargée.

Ce que la passe rend, sur les 620 impressions concernées :

| Groupe | Couchées | Debout |
|---|---|---|
| Leader — les six traitements | **445** | 0 |
| Base / `Normal` | 91 | 0 |
| Base / `Hyperspace` | 80 | **5** |
| Base / `GC VIP Promo` | 4 | 0 |

**Un seul groupe est donc hétérogène**, et ses cinq exceptions sont nommées :
*Security Complex* (Scarif), *Droid Manufactory* et *Petranaki Arena*
(Geonosis), *KCM Mining Facility* (Mustafar), *Pau City* (Utapau). Aucune règle
tirée du type, du traitement ni de l'extension ne les isole — elles se lisent
sur l'image, et c'est déjà la règle du projet : `CardImage.uprightInCell`
redresse une carte couchée d'après son rendu, jamais d'après un champ.

**Les rendus n'ont pas non plus une taille constante**, contrairement à Pokémon
et ses 600 × 825 partout : treize formats, de 1117 × 1560 (39 %) à 418 × 300.
La normalisation est donc obligatoire ici, là où Pokémon pouvait empiler sans
rééchantillonner. Ce qu'elle ne casse pas : les **rapports** sont stables à
0,4 % près (0,7154–0,7186 debout, 1,3929–1,3978 couché), et le banc ne rend que
des fractions. Les vignettes sont écartées plutôt qu'agrandies — les agrandir
inventerait des arêtes que l'original n'a pas.

### Le corpus de decks — 11 744 listes, et deux pièges de pagination

`swumetastats.com/api/decklists` déclare **11 744 decklists sur 120 jours**,
avec les quatre zones du jeu : `Leader`, `Base`, `MainDeck`, `Sideboard`.

**Deux pièges silencieux, mesurés.** `limit` est **ignoré** — la page fait vingt
entrées qu'on en demande trois ou vingt-cinq ; `page` et `offset` le sont
aussi, et rendent la première page sans broncher. Seul **`skip`** déplace la
fenêtre. Les trois auraient produit une ingestion qui tourne, qui n'échoue
jamais, et qui réécrit vingt decks en boucle — c'est la leçon Pokémon, où un
compteur d'écritures passait pour un compteur de résultats et masquait 5 533
decks manquants. La sonde s'arrête donc dès qu'une page ne rapporte aucune
entrée nouvelle.

**Le débit est un résultat, pas une statistique d'agrément** : une page de vingt
pèse un quart de mégaoctet et met environ 80 secondes à venir. Couvrir les
11 744 listes demanderait **une douzaine d'heures**. C'est ce chiffre qui
décidera de la fenêtre retenue à l'ingestion.

**Un seul format porte le corpus**, et il fallait le mesurer plutôt que le
déduire d'un nom : sur les tournois relevés, **`Premier` en couvre 19 sur 20**
— tous officiels — et le vingtième n'en déclare aucun. `decks.format`
n'accueillera donc que `premier`. Yu-Gi-Oh a payé la déduction inverse :
`Advanced` y avait été déclaré parce qu'il porte le nom du format courant du
jeu, et il ne comptait que 3 decklists sur 168 tournois — un onglet vide, sur un
écran qui a l'air en panne alors qu'il dit vrai.

### Le gabarit d'un deck

Mesuré sur 220 listes (`python -m app.measure.swu_decks`) :

| | Valeur |
|---|---|
| Deck principal | médiane **51**, écart interquartile **2**, étendue 50–64 |
| Modes | **50 cartes** (100 listes) et **60** (26) |
| Leader, Base | exactement 1 chacun, dans 220/220 listes |
| Réserve | médiane 10, présente dans 213/220 |
| Unit | **81,0 %** (écart 10,3) |
| Event | **12,0 %** (écart 8,0) |
| Upgrade | **5,0 %** (écart 4,3, présent dans 181/220) |
| Exemplaires | 1 (536 entrées), 2 (1 538), 3 (2 648) — **et une seule à 15** |

Toutes les zones sauf la réserve comptent dans la complétion : on ne pose pas un
deck sans sa base. La médiane à viser est donc **53 cartes**, non 51.

La règle des trois exemplaires tient sur 4 722 entrées et **cède une fois** :
une liste en déclare 15. C'est le même signal que le deck HAT à six exemplaires
relevé chez Yu-Gi-Oh — une liste mal saisie à la source plutôt qu'une
infraction —, et il est écrit ici parce qu'un seuil de contrôle posé sur « trois
au maximum » écarterait ce deck sans le dire.

**Une limite de l'échantillon, à ne pas taire** : la source rend les listes les
plus récentes d'abord, si bien que ces 220 couvrent **deux jours** et sept
tournois, pas 120 jours. Le gabarit est net, sa représentativité dans le temps
reste à établir.

### La résolution des citations — de 7,35 % de perte à 0,26 %

Les listes citent un **nom**, pas un code d'impression — contrairement à
Riftbound et Pokémon. Une lecture littérale perd 7,35 % des citations et touche
**220 decks sur 220**, ce qui est le symptôme d'un défaut de méthode et non
d'une source pauvre. Trois causes, séparées par la mesure :

| Cause | Exemple |
|---|---|
| La **casse** | la liste écrit « Hold **f**or Questioning », le catalogue « Hold **F**or Questioning » |
| Le **sous-titre omis** | la liste cite « Data Vault » quand le catalogue publie le nom « Data Vault » et le sous-titre « Scarif » — c'est le cas des Bases |
| La **ponctuation typographique** | « Benthic **“**Two Tubes**”** » et « Mesa Propose**…** » contre des guillemets droits et pas d'ellipse |

D'où une résolution en trois temps, et **le repli n'est pas inconditionnel** :
« Black One » désigne deux cartes réellement différentes, et un repli aveugle en
choisirait une au hasard — le faux couple, que nul écran ne détrompe.

| Temps | Effet mesuré |
|---|---|
| Le **titre entier** décide, casse et ponctuation repliées | 96,32 % des citations |
| Le **nom seul** tranche, *et seulement s'il ne désigne qu'une carte* | 3,41 % |
| Le reste est **refusé** plutôt que deviné | 0,26 % |

Toute normalisation de noms produit des faux couples autant qu'elle comble des
manques — c'est ce que les extensions Pokémon ont coûté, où réduire « Base
Set » à une clé vide appariait 1999 avec 2017. Le banc vérifie donc qu'aucune
paire de titres distincts ne se rejoint, et distingue les réunions **bénignes**
(la source écrit « Prepare **F**or Takeoff » et « Prepare **f**or Takeoff »)
des vraies.

Les 17 citations qui restent ne sont pas des défauts du banc : deux cartes
manquent au catalogue, et une est une **coquille de la source** — « Poe
Dameron | One Hell of **a a** Pilot ».

### Les aspects contraignent réellement, contrairement à l'Attribut de Yu-Gi-Oh

La question n'était pas rhétorique : SWU **pénalise** le hors-aspect de deux
ressources sans l'interdire, et Yu-Gi-Oh a montré qu'un champ ressemblant à une
identité de couleur peut n'imposer aucune contrainte — l'y avoir supposée
écartait 32 % de son catalogue sur une règle inexistante.

Mesuré sur 220 decks : **79,1 % sont entièrement dans les aspects de leur leader
et de leur base**, la part hors aspect a une médiane de **0,0 %** et un écart
interquartile de **0,0 point**. Le filtrage du pool par aspect est donc
légitime pour ce jeu — avec une nuance qui doit survivre au résumé : un deck sur
cinq joue hors aspect, jusqu'à **22 %** de ses cartes. Le filtre doit être une
préférence, pas un mur.

### La fenêtre d'illustration — la méthode Pokémon cède, et l'image dit pourquoi

Reprise telle quelle, la méthode qui a abouti pour Pokémon — empiler des cartes
alignées, lire la plage calme du gradient de l'image moyenne — **ne converge
pas** sur SWU. Trois symptômes, sur les 21 groupes assez fournis pour être
empilés :

- des **dérives énormes** entre deux tirages disjoints : 520 px pour
  `Leader/Normal`, 309 px pour `Unit/Prestige`, 181 px pour `Leader/Showcase`.
  Chez Pokémon, la dérive allait de 0 à 12 px ;
- le **contrôle de luminance en échec sur neuf groupes**, l'« illustration »
  ressortant plus claire que ce qui la suit — l'inverse de ce qu'une
  illustration fait ;
- des **séparations trop basses** là où la fenêtre était fausse :
  `Event/Normal` à 16,5 bits de moyenne, avec une paire à **3 bits**, très en
  deçà du seuil de confiance de 12.

**Aucun de ces trois symptômes ne nomme la cause**, et deux d'entre eux
pointaient vers l'alignement — le suspect naturel, ce jeu publiant treize
formats de rendu qu'il faut normaliser. C'est l'image moyenne, *regardée*, qui a
tranché : le cadre y est parfaitement net, les 154 Leaders sont alignés au
pixel. L'alignement n'était pas en cause.

Ce que la même image montre, en revanche : **sur une carte couchée,
l'illustration occupe la moitié gauche et le pavé de texte la moitié droite**.
Or `derive` sonde les colonnes **en partant du centre de la carte** — ce qui va
de soi chez Pokémon, dont les illustrations y sont, et qui tombe en plein texte
ici. Le banc rendait donc le pavé de texte comme « fenêtre », avec une assurance
parfaite : fenêtre (0,485 · 0,220 · 0,911 · 0,682), luminance 204 contre 147.

Le point de sondage horizontal est devenu une propriété de l'orientation
(`PROBE_X_LAID = 0.25`). L'effet, sur `Leader/Normal` :

| | avant | après |
|---|---|---|
| Fenêtre | (0,485 … 0,911) — le texte | **(0,032 · 0,088 · 0,451 · 0,808)** — l'illustration |
| Séparation moyenne | 18,7 bits | **31,1 bits** |
| Paire la plus serrée | 8 bits — **sous le seuil** | **21 bits** |
| Dérive entre tirages disjoints | 520 px | **53 px** |

**La leçon de méthode est là** : un banc doit pouvoir *se regarder*, pas
seulement se lire. Trois indicateurs chiffrés criaient qu'une chose n'allait
pas, aucun ne disait laquelle, et deux accusaient le mauvais coupable. C'est à
cela que sert `--dump`, qui écrit l'image moyenne et son gradient.

### La même erreur, une seconde fois, sur l'autre axe

Le correctif horizontal réparait les cartes couchées et laissait les **Events**
dans un état plus troublant encore : une fenêtre **stable à 1 px près entre deux
tirages disjoints**, et pourtant fausse — 16,5 bits de séparation contre 31
partout ailleurs, avec une paire à **3 bits**, très en deçà du seuil de
confiance de 12. *Une fenêtre reproductible n'est pas une fenêtre juste*, et
c'est précisément le piège que la séparation existe pour attraper : la dérive,
seule, aurait signé un excellent résultat.

L'image moyenne, à nouveau, a nommé la cause en un regard : **sur une carte
Event, l'illustration est en bas et le pavé de texte en haut** — l'inverse de
l'Unit. La bande de sondage verticale (0,20–0,40) y tombait en plein texte.

La maquette suit donc le **type**, et rien d'autre ne la prédit — c'est le
constat de `category` chez Pokémon, où la fenêtre d'un Pokémon s'arrête quarante
pixels avant celle d'un Dresseur :

| Type | Illustration | Sondage |
|---|---|---|
| `Unit`, `Upgrade` | en haut | (0,20–0,40), au centre |
| `Event` | **en bas** | (0,60–0,80), au centre |
| `Leader`, `Base` | à gauche, carte couchée | (0,35–0,60), à 0,25 |

Un type inconnu emprunte le repli des cartes debout, et **le banc le dit** :
une maquette non prévue, mesurée sous une bande empruntée, rendrait un rectangle
sans qu'on sache qu'il est emprunté.

### Où en est la mesure, groupe par groupe

Deux critères se lisent ensemble : la **séparation en bits** — une fenêtre qui
embarque du cadre gèle des bits identiques sur toutes les cartes et la distance
s'effondre — et la **dérive entre deux tirages disjoints**, qui dit si la
fenêtre décrit le gabarit ou l'échantillon.

Après les deux correctifs, **les 21 groupes tiennent entre 30,1 et 32,1 bits** :

| Groupe | Séparation | Paire | Dérive |
|---|---|---|---|
| `Event/Normal` | 16,5 → **31,2** | 3 → **15** | 15 px |
| `Event/Hyperspace` | 18,3 → **31,7** | 9 → **19** | 2 px |
| `Leader/Normal` | 18,7 → **31,1** | 8 → **21** | 53 px |
| `Base/Normal` | 32,1 | 19 | 3 px |
| `Unit/Normal` | 31,5 | 19 | 66 px |
| `Upgrade/Normal` | 31,1 | 19 | 58 px |

Ce qui reste s'explique, et deux motifs se lisent d'un coup :

- **les arêtes qui touchent le bord du rendu** appartiennent presque toutes à
  des traitements `Hyperspace`, dont l'illustration va **bord à bord**. L'arête
  butée y est la bonne réponse et non un échec — c'est le cas des
  `Special illustration rare` de Pokémon, où l'illustration *est* la carte. Les
  fortes dérives résiduelles (`Unit/Prestige` 309 px, `Leader/Showcase` 181)
  sont le même phénomène : un bord de carte n'est pas un trait, sa position
  varie donc avec le tirage ;
- **les quatre paires à 0 bit** sont toutes des couples `P25` / `P26` — les
  promos 2025 et 2026, c'est-à-dire **la même carte rééditée d'une année sur
  l'autre avec la même illustration**. Ce n'est pas une confusion de l'index
  mais une question d'identité, que le titre imprimé règle déjà : ce sont deux
  impressions d'une seule carte. Le précédent existe des deux côtés — les 17
  cartes Riftbound recollées par `propagate_shared_art`, et le
  *Professor Turo's Scenario* de Pokémon, à 0 bit pour la même raison.

### Cinq gabarits, un par type — et c'est la mesure qui le dit

La question « un gabarit ou plusieurs » se tranche **en bits, pas en pixels** :
c'est ainsi que Pokémon a conclu que ses quatre époques étaient
interchangeables. `--compare` éprouve donc chaque groupe sous la fenêtre de ses
voisins de même type.

Le résultat est franc, et identique dans les cinq types : **la fenêtre du
traitement `Normal` est la meilleure ou l'égale de toutes les autres.**

| Cartes | Sous leur propre fenêtre | Sous la fenêtre `Normal` |
|---|---|---|
| `Base/Hyperspace` | 31,9 / 18 | 31,7 / **20** |
| `Leader/Hyperspace` | 31,6 / 18 | 31,1 / **19** |
| `Unit/Prestige` | 31,1 / 17 | 32,0 / **20** |
| `Unit/OP Promo` | 31,0 / 16 | 31,2 / **19** |
| `Event/OP Promo` | 31,9 / 21 | 31,1 / 20 |
| `Event/Hyperspace` | 31,7 / 19 | 31,6 / 19 |

L'inverse est faux partout : `Base/Normal` tombe à **25,2 / 13** sous la fenêtre
`Hyperspace`, `Upgrade/Normal` à 26,8 / 13, et la fenêtre `Showcase` est
ruineuse sur les autres Leaders — **13,8 / 6** et 15,4 / 7, très en deçà du
seuil de confiance.

La raison est celle que Pokémon avait déjà relevée : la fenêtre étroite **tient
entièrement dans l'illustration** des cartes bord à bord, où elle capte donc de
l'illustration pure ; la fenêtre large, elle, embarque du cadre sur une carte
standard et lui coûte sa marge. *Un seul gabarit, le plus étroit.*

Les cinq retenus, mesurés sur le traitement `Normal` de chaque type :

| Type | Gabarit | Orientation |
|---|---|---|
| `Unit` | (0,1495 · 0,1397 · 0,9042 · 0,6269) | debout |
| `Upgrade` | (0,0976 · 0,1212 · 0,9069 · 0,5622) | debout |
| `Event` | (0,1038 · **0,5212** · 0,8979 · **0,9103**) | debout, illustration basse |
| `Leader` | (0,0321 · 0,0877 · **0,4513** · 0,8084) | couchée, illustration à gauche |
| `Base` | (0,0712 · 0,1692 · 0,9263 · 0,6267) | couchée |

Un gabarit de moins est un gabarit de moins à essayer sur chaque photo : cinq,
et non les vingt-et-un couples (type, traitement) que le catalogue distingue.

### Le contrôle de luminance n'est pas transposable, et on ne l'ajustera pas

Chez Pokémon, l'illustration doit ressortir plus sombre que le pavé de texte qui
la suit, et ce contrôle croisé a du sens parce que le texte y suit toujours
l'illustration vers le bas. Sur SWU il échoue **partout**, y compris là où la
fenêtre est manifestement juste : pour `Base/Normal`, la zone au-delà de la
fenêtre n'est pas le pavé de texte mais le **bord noir de la carte**, à une
luminance de 32 contre 114 pour l'illustration.

Le corriger une deuxième fois — après l'avoir déjà réorienté vers la droite
pour les cartes couchées — reviendrait à l'ajuster jusqu'à ce qu'il approuve, ce
qui n'est plus un contrôle. Il est donc **conservé et affiché, mais il ne vaut
pas pour ce jeu** ; la séparation et la dérive portent seules le jugement. Le
dire est préférable à le faire taire.

### Le catalogue est en base — 2 181 cartes, 5 282 impressions

`api/app/ingestion/swu_ingest.py`, migration `20260817110000_swu.sql`.

**L'écart entre 8 424 entrées et 5 282 impressions est le résultat principal du
connecteur** : une entrée brillante n'est pas une impression de plus. Les
compter séparément aurait gonflé `card_prints` de moitié et fait apparaître deux
lignes de collection pour un seul exemplaire — le défaut que Riftbound a payé
sur ses 243 variantes suffixées. Une impression est donc identifiée par le
triplet (extension, traitement, carte), et l'entrée brillante n'y ajoute que sa
case ; l'entrée ordinaire fournit le numéro imprimé et le rendu, celui de la
brillante répondant 403.

| En base | |
|---|---|
| Cartes | **2 181** — les 2 180 titres, plus « Snapshot Reflexes » qui en fait deux |
| Impressions | **5 282**, dont 4 qui n'existent qu'en brillante |
| Noms de recherche | **3 070** — le titre entier et le nom seul |
| `tcgplayer_id` | 5 244 sur 5 282 (99,3 %) |
| Déclarent la brillante | **3 087** |
| Sans aucune finition | **0** — le contrôle du § 6, vérifié avec l'expression exacte de `card_editions` |
| Par type | Unit 1 369 · Event 414 · Leader 154 · Upgrade 154 · Base 90 |

**Deux formes de nom sont indexées par carte**, et c'est mesuré sur le corpus de
decks : les listes citent les unités sous leur titre entier et les bases sous
leur seul nom. Sans la seconde, `Data Vault` serait introuvable à la saisie
alors que le catalogue la porte sous « Data Vault | Scarif ».

Ce que le schéma impose et qu'il faut dire : `cards.cmc` étant
`NOT NULL DEFAULT 0`, une Base — qui n'a pas de coût, on ne la joue pas, on la
pose — s'y voit attribuer un zéro qui se lira « gratuite ». La perte est bornée :
90 cartes, jamais plus d'une par deck, et le constructeur les traite par leur
type.

**Vérifié sous le rôle qui subira les règles.** Dans une transaction annulée,
sous `authenticated` : `search_cards('boba fett', 'swu')` rend 13 cartes,
`search_cards('data vault', 'swu')` en rend une — la Base retrouvée par son seul
nom —, et la même requête en `magic` n'en rend aucune. Aucun `oracle_id` n'est
partagé entre SWU et un autre jeu.

**`TASH` reste injoignable** (502 déterministe), et le connecteur le dit à
chaque course au lieu de compter son contenu pour vide.

### Les prix — 95,7 %, et une décision renversée par son propre contrôle

`api/app/ingestion/tcgcsv_swu_prices.py`, catégorie TCGCSV **79**.

Le rapprochement est le plus simple des cinq jeux cotés : SWU-DB sert un
`tcgplayerId` sur 99,3 % de ses entrées, si bien qu'il s'agit d'un identifiant
et non d'une ressemblance. Riftbound doit composer avec 227 impressions non
chaînées ; Yu-Gi-Oh et Pokémon avec un rapprochement par extension et numéro qui
a coûté deux tables d'alias et un veto par date. **5 053 impressions sur 5 282
sont cotées, soit 95,7 %** — 4 603 en ordinaire, 1 781 en brillante.

**Le connecteur devait ne pas écrire les finitions, et c'est son contrôle qui
l'a détrompé.** Le raisonnement de départ semblait solide : le catalogue les
déclare pour 100 % des impressions quand TCGCSV n'en chaîne que 99,3 %, donc la
source la plus complète fait autorité. Le contrôle de concordance, ajouté « au
cas où », a rendu **1 981 accords sur 5 154**.

| Écart | Catalogue | TCGCSV |
|---|---|---|
| 2 165 | ordinaire + brillante | ordinaire seule |
| **517** `Showcase` | **ordinaire seule** | **brillante seule** |
| 465 `OP Promo` | ordinaire seule | les deux |
| 26 `Hyperspace` | les deux | brillante seule |

Les 517 `Showcase` tranchent : elles n'existent qu'en brillante, le catalogue
les déclarait ordinaires, et une *Ahsoka Tano | Trust in the Force* à **290,51 €
en brillante** aurait été valorisée à zéro — sa colonne ordinaire étant vide —
tout en proposant à la saisie une case que le carton n'a jamais eue.

*Couvrir n'est pas avoir raison.* `VariantType` ne publie une entrée brillante
que lorsque la source l'a saisie ; `subTypeName` décrit ce qui se vend, et c'est
lui qui répond à la question posée. TCGCSV fait donc autorité, comme pour
Riftbound et Pokémon, et le catalogue n'est plus qu'un repli — `COALESCE` dans
les deux sens protège chacun du travail de l'autre.

Contrôle final : **aucune impression n'offre plus zéro finition**, vérifié avec
l'expression exacte de `card_editions`, `etched` compris.

**Deux limites d'exécution, mesurées en produisant l'erreur.** À 7 916 produits,
un `UPDATE` par ligne vers une base distante *fait tomber la connexion* —
« server closed the connection unexpectedly » en pleine course ; c'est le seuil
qu'avait rencontré Yu-Gi-Oh à 44 139 impressions, et `executemany` le règle. Et
trente et une requêtes suffisent à faire lâcher le réseau de ce poste une fois
sur deux : le connecteur reprend désormais avec une attente croissante, ce dont
celui de Riftbound n'a pas besoin avec ses vingt et une.

### L'index d'empreintes — 5 282 sur 5 282, et aucune carte sans

Les cinq gabarits sont entrés dans `art_box.py` et son jumeau Dart, dont un
test relit les valeurs. `card_geometry` déclare le format du carton : 63 × 88,
et **le rendu s'y aligne** — mesuré sur les 1 428 rendus mis en cache par les
bancs, 0,7154 à 0,7186 debout et 1,3929 à 1,3978 couché, l'inverse exact.

L'index couvre **toutes** les impressions et **toutes** les cartes. SWU rejoint
`GAMES_WITH_LANDSCAPE` pour ses 599 cartes couchées — 445 Leaders et 154 Bases,
un quart du catalogue, la plus forte proportion des trois jeux concernés.

**Une faute d'orchestration a coûté un redémarrage**, et elle mérite d'être
écrite : l'index tournait quand une correction d'identité a été appliquée au
catalogue, si bien qu'une empreinte s'est calculée pour une impression que la
purge venait de supprimer — `ForeignKeyViolation`, à 4 618 empreintes sur
5 282. Le module est reprenable par conception et n'a rien perdu ; mais *on ne
change pas la règle d'identité pendant qu'un index se construit dessus*.

### Le corpus de decks — et trois défauts que seule la base a révélés

`api/app/ingestion/swumetastats_ingest.py`, format `premier`.

Les zones suivent le précédent Riftbound : **Leader, Base et MainDeck comptent
dans la complétion**, la réserve non — on ne pose pas un deck sans sa base. Le
Leader est en outre retenu à part pour occuper `decks.commander_oracle_id`,
comme la Légende : c'est par lui qu'on choisit un deck.

Trois défauts se sont succédé, et **aucun ne se voyait depuis le connecteur** :

1. **Le nom seul écrasait silencieusement les homonymes.** `load_name_index`
   construit un dictionnaire nom → carte où une collision remplace la
   précédente : « Boba Fett » aurait désigné l'une de ses cartes selon l'ordre
   des lignes rendues par la base. Le connecteur charge donc un index **dont
   les noms ambigus sont retirés** — 163 noms de personnages réutilisés —, et
   une citation ambiguë est refusée plutôt que résolue au hasard.
2. **Une même carte comptait pour deux.** Le catalogue portait « Prepare For
   Takeoff » et « Prepare for Takeoff », deux écritures de la source pour une
   seule carte, donc deux `oracle_id` — et un nom devenu ambigu, donc écarté.
   L'ingestion canonicalise désormais les titres avant d'en dériver l'identité.
   La canonicalisation est **ciblée** : dériver l'identité du titre *normalisé*
   serait plus direct et changerait toutes les clés du catalogue, invalidant
   l'index entier pour corriger une carte.
3. **La purge manquait.** Changer la règle d'identité laisse des lignes
   derrière : le connecteur produisait 2 180 cartes et 5 282 impressions quand
   la base en portait 2 181 et 5 284. L'écart ne se voyait pas depuis le
   connecteur, qui compte ce qu'il écrit. `prune` retire d'abord les impressions
   que la source ne publie plus, **puis** les cartes qu'aucune impression ne
   porte — l'ordre inverse ne trouverait rien, l'ancienne carte gardant ses
   anciennes impressions. Rien de cité par une collection ou un deck n'est
   supprimé.

Effet mesuré sur vingt listes : **17 decks enregistrés sur 20 avant, 20 sur 20
après**, et les citations non résolues tombent de quatre à une — « Poe
Dameron | One Hell of **a a** Pilot », une coquille du catalogue que rien de
notre côté ne peut réparer.

**Et un quatrième, le plus silencieux de tous** : `store_deck` n'engage rien,
`Session.run` documentant que l'unité doit commiter ce qu'elle veut garder.
Sans ce commit, vingt decks annoncés « enregistrés » repartaient avec la
connexion et la base restait **vide** — le connecteur comptait ce qu'il croyait
écrire. C'est exactement la leçon des 5 533 decks Pokémon manquants : *un
compteur d'écritures n'est pas un compteur de résultats*, et seul le décompte
en base les sépare.

### Le constructeur — le premier jeu qui a tout ce qu'il faut du premier coup

Les quatre jeux précédents ont chacun buté quelque part : Riftbound n'a
toujours pas de gabarit faute d'avoir mesuré ses notions ; Yu-Gi-Oh a demandé de
**refaire le constructeur sur ses axes** ; Pokémon n'a ni terrain ni courbe,
`cmc` y portant les points de vie ; Wankul connaît ses règles publiées et manque
des champs pour les vérifier. SWU a les trois choses d'un coup — des familles
**imprimées dans le type**, une taille qui est un plancher réglementaire, et un
coût qui est un vrai coût de mise en jeu.

| Gabarit `premier` | Mesuré sur 220 listes |
|---|---|
| Taille | **50** — le mode (100 listes sur 220) *et* le minimum légal |
| Exemplaires | 3, confirmé sur 4 722 entrées |
| Leader | exigé, à la place du commandant |
| Terrains | **`null`**, pas zéro : on ne joue pas de carte-ressource dans ce jeu |
| Unités | 81,0 % (écart 10,3) |
| Événements | 12,0 % (écart 8,0) |
| Améliorations | 5,0 % (écart 4,3) |
| Courbe | coût 1 : 2,0 % · 2 : 25,0 % · 3 : 25,5 % · 4 : 15,7 % · 5 : 11,8 % · **6+ : 19,6 %** (écart 17,4) |

**La taille vise le plancher et non la médiane** : viser 51 produirait un deck
légal mais une carte au-dessus du minimum, là où viser 50 produit le deck le
plus accessible — ce qui est la question que ce produit pose.

**`usesColorIdentity` vaut vrai, et c'est l'inverse exact de Yu-Gi-Oh.** Là-bas,
un champ qui ressemblait à une identité de couleur n'imposait aucune contrainte,
et y filtrer écartait 32 % du catalogue. Ici la contrainte existe et se mesure :
79,1 % des decks tiennent entièrement dans les aspects de leur leader et de leur
base. La réserve à connaître : un deck sur cinq joue hors aspect, jusqu'à 22 %
de ses cartes — le filtre est donc un peu plus strict que le méta réel, dans le
sens sûr, puisqu'il propose des decks jouables sans surcoût.

**Le coût 0 n'existe pas** dans le deck principal — 0,0 % avec un écart nul — et
le palier 6+ est le plus dispersé, à 17,4 points : c'est là que les archétypes
divergent.

### Vérifié de bout en bout, sous le rôle qui subira les règles

Sous `authenticated`, dans une transaction annulée :
`deck_suggestions(p_format => 'premier', p_game => 'swu')` rend des decks avec
leur attribution SWU Meta Stats. **Aucune carte d'un autre jeu n'est entrée dans
un deck SWU** — vérifié par jointure, zéro ligne — et les decks importés portent
tous leur leader.

### Ce qui reste dû

- **éprouver les gabarits sur des photos**, et non sur des rendus : c'est le
  dernier verrou, celui que Riftbound a franchi avec huit cartes de papier ;
- **les quatre promos à 0 bit** : leurs paires `P25` / `P26` sont des
  rééditions à illustration identique, ce que le titre imprimé réunit déjà —
  reste à vérifier que l'ingestion les traite comme deux impressions d'une
  carte, et non comme deux cartes ;
- **l'ingestion elle-même** — migration, catalogue, prix, index d'empreintes,
  decks, constructeur, application ;
- **une carte de papier**. Le format 63 × 88 est présumé pour ce jeu comme il
  l'était pour Wankul ; et le précédent Riftbound rappelle qu'un gabarit mesuré
  sur des rendus doit encore rencontrer une photo.

---

## 11. One Piece — la mesure, avant toute ingestion

**Rien de One Piece n'est en base.** Comme pour Pokémon (#28) et SWU (§ 10), ce
chantier commence par mesurer ce que les sources publient vraiment.

### Trois catalogues, et deux se ferment d'eux-mêmes

| Source | Ce que ses règles publiées disent |
|---|---|
| **apitcg.com** | `Disallow: /api/` — l'API qui servirait est nommément interdite. C'est le motif exact qui avait écarté piltoverarchive |
| **onepiece-cardgame.dev** | répond à toute requête par une page Cloudflare « Just a moment… ». C'est une **détection de robot**, non une absence — et on ne contourne pas une protection |
| **optcgapi.com** | ni `robots.txt` ni conditions (404 sur les deux), API documentée publiquement → **§IV.9**, conditions de Scryfall |

La distinction du deuxième cas mérite d'être tenue : Cardmarket avait rendu 403
sur une requête simple alors qu'il fallait conclure « ce jeu n'y est pas », et
ici il faut conclure « cette porte est fermée ». Les deux erreurs sont
symétriques, et toutes deux se règlent en regardant *ce que le site dit*, pas
seulement ce qu'il répond.

### Le catalogue se lit par deux portes, et l'oublier en couperait un huitième

Les 21 extensions viennent de `/api/allSets/` ; les **29 decks de démarrage**
ont leur propre chemin, `/api/allDecks/`, et `/api/sets/ST-01/` répond « Card
was not found! ».

| | Entrées | |
|---|---|---|
| Extensions | 3 485 | |
| Decks de démarrage | **507** | dont **286 codes que rien d'autre n'apporte** |
| Total | **3 992** | 2 541 cartes |

Ce n'est pas un supplément : les decklists de tournoi citent ces cartes
couramment — `ST32` apparaît dès le premier deck relevé chez Limitless. Sans le
second parcours, ces citations seraient restées introuvables sans que rien ne
dise pourquoi.

### L'identité est le code, et il a fallu deux corrections pour le voir

`card_set_id` (`OP01-077`) désigne la carte ; `card_image_id` (`OP01-077_p1`)
désigne l'impression. Mais la source suffixe aussi les **noms**, et c'est là que
le banc s'est trompé deux fois :

| Règle de retrait | Codes qui semblaient réunir deux cartes |
|---|---|
| un seul suffixe parenthésé | **316** |
| tous les suffixes parenthésés | 79 |
| plus le code accolé par tiret (« Buggy **- OP03-008** ») | **4** |

Les quatre qui restent sont des **fautes de la source**, non de la règle : une
entrée « Buggy » rangée sous le code de Zoro-Juurou, un tiret sans espace
(« Jewelry Bonney **-**PRB02-004 »), un suffixe qui est un nom d'extension, et
une coquille — « Sakazuk » pour « Sakazuki ». Les absorber demanderait de
normaliser jusqu'à ce que tout concorde, ce qui produit des faux couples.

**Ce sont les espaces autour du tiret qui protègent les noms**, et ce n'est pas
cosmétique : « Zoro-Juurou » en porte un. Un motif plus lâche l'amputerait, et
deux cartes deviendraient une.

**Le nom ne dit pas la variante, le rendu si.** Les deux marques ne concordent
que sur 3 225 entrées sur 3 992 : « Donquixote Doflamingo (073) » porte un
suffixe qui est le **numéro**, pas un tirage. C'est `card_image_id` qui tranche.

### Le résultat qui décide de la reconnaissance : 361 homonymes

| | |
|---|---|
| Cartes | 2 541 |
| Noms de base distincts | **1 127** |
| Noms portés par plusieurs cartes | **361** |
| Séparables par type, couleur et coût | 247 sur 361 |

« Monkey.D.Luffy » désigne **62 cartes**, « Trafalgar Law », « Sanji »,
« Roronoa Zoro » et « Jinbe » vingt-huit chacun. C'est bien au-delà des 80
homonymes de Riftbound, qui avaient suffi à faire primer l'illustration sur le
nom pour ce jeu.

Et **114 groupes ne se séparent ni par le type, ni par la couleur, ni par le
coût** : seule l'illustration les distingue. Deux conséquences à porter dans la
suite du chantier — la reconnaissance devra s'appuyer sur l'empreinte, et la
saisie devra montrer les vignettes, comme elle le fait déjà pour Riftbound.

### Quatre types, et les Leaders n'ont pas de coût

Character 3 094 · Event 548 · Leader 285 · Stage 65. Les **285 Leaders** sont
sans coût — ils portent une vie —, ce qui est le même piège que `cmc` chez
Pokémon : le champ existe, la grandeur n'est pas celle qu'on croit.

### Ce qui reste dû

- **les fenêtres d'illustration**, une par maquette ;
- **le chaînage des prix** : cette source ne publie aucun identifiant
  TCGplayer, contrairement à Riftcodex et SWU-DB. Le rapprochement passera par
  extension et numéro, comme pour Yu-Gi-Oh — dont le catalogue écrit `LOB-EN005`
  là où TCGplayer écrit `LOB-005`, si bien que sans normalisation **aucune**
  carte n'aurait été cotée, et l'échec aurait été muet. 52 codes promo de forme
  `P-055` sortent du vocabulaire attendu et demanderont leur propre règle ;
- **le corpus de decks**, chez Limitless (`game=OP`) : le connecteur de Pokémon
  y mène, et les listes y sont structurées par code d'impression — ~7 300
  decklists relevées sur six mois.
