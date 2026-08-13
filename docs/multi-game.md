# Multi-jeu — accueil des jeux qui ne sont pas Magic

Annexe de [`architecture.md`](./architecture.md). Trois jeux partagent
aujourd'hui la base de DeckHand : **Magic**, **Riftbound** (le TCG League of
Legends de Riot) et **Yu-Gi-Oh**. Ce document dit ce que chacun a demandé, et ce
que le modèle a absorbé sans se déformer.

Un quatrième, **Pokémon**, a été *mesuré* sans être ingéré : la
[§ 8](#8-pokémon--ce-que-la-mesure-a-rendu-avant-toute-ingestion) dit ce qu'il
coûterait, et rien de lui n'est en base.

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

### Le gabarit de deck : mesuré, et pourtant toujours nul

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

**Et pourtant `DeckBlueprint.of` rend toujours `null`.** Ce n'est plus faute de
mesure : c'est que le constructeur est bâti sur des notions que ce jeu n'a pas,
et la mesure le chiffre.

| Ce que le constructeur demande | Ce que Yu-Gi-Oh en offre |
|---|---|
| `isCreature` — cherche « Creature » | **aucune** carte sur 13 866 |
| `isLand` | **aucune** |
| `playableIn` — identité de couleur | le champ porte l'**Attribut**, qui n'impose aucune contrainte de construction |
| `cmc` — coût de mana | le champ porte le **Niveau** |

Deux quotas sur cinq seraient donc introuvables, et le filtrage par « couleur »
écarterait **32 % du catalogue** sur une règle qui n'existe pas — rien n'interdit
de mêler DARK et LIGHT. `cmc` et `color_identity` sont des analogues de forme,
pas de sens : l'ingestion y range le Niveau et l'Attribut faute de champs
dédiés, et s'en servir comme le fait Magic produirait un deck faux avec
l'assurance d'un deck mesuré.

Ce que ces nombres attendent n'est donc pas un réglage mais **un constructeur
dont les axes soient ceux du jeu** : Monstre / Magie / Piège plutôt que
créature / terrain, paliers de Niveau plutôt que courbe de mana, et deux zones à
remplir plutôt qu'une. Le gabarit reste `null` jusque-là, et c'est désormais un
choix mesuré et non une lacune.

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
proportions de deck sont mesurés ; il manque **une carte de papier**. Aucune carte Yu-Gi-Oh n'a encore été
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

### Ce qu'il resterait à faire, si un quatrième jeu se décidait

Le chantier de mesure est clos ; l'ingestion ne l'est pas et n'a pas été
commencée. Resteraient :

- le **catalogue, les prix et les decks** — accessibles et documentés. TCGdex
  publie d'ailleurs les cotes Cardmarket en euros et TCGplayer en dollars, ce
  qui éviterait peut-être le détour par TCGCSV et la conversion BCE : à mesurer,
  la leçon Yu-Gi-Oh étant qu'un prix servi par un catalogue peut n'être qu'un
  plancher ;
- une **carte de papier** — aucune n'a été photographiée, et c'est le carton qui
  a livré les deux derniers défauts de Riftbound ;
- le gabarit de deck (`DeckBlueprint`), qui se mesure sur un corpus et ne se
  déclare pas d'avance ;
- le sort des cartes que la règle du numéro ne sait pas lire.
