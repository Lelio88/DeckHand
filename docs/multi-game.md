# Multi-jeu — accueil de Riftbound

Annexe de [`architecture.md`](./architecture.md). Riftbound, le jeu de cartes
physique League of Legends de Riot, partage la base de DeckHand avec Magic.

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

**Le second gabarit ne peut pas encore servir sur une photo.** `findCard` ne
retient un quadrilatère que si son rapport approche celui d'une carte verticale
à 0,30 près ; un champ de bataille, en paysage, s'en écarte de 0,68 et est
rejeté. La reconnaissance retombe alors sur le cadrage centré, qui découpe un
rectangle vertical — de travers sur une carte couchée. Les 64 champs de bataille
sont donc hors de portée du scan tant que la détection ne connaît pas les deux
orientations. L'index, lui, est correct : `art_box.py` hache bien ces cartes au
gabarit paysage d'après `cards.layout`.

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
| `decks.format CHECK (… IN ('pauper','modern','commander'))` | **Non touchée** : les formats Riftbound ne sont pas connus, et une contrainte inventée d'avance vaut moins qu'une contrainte ajoutée quand la donnée existera |
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
