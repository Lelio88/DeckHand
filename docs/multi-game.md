# Multi-jeu — accueil de Riftbound

Annexe de [`architecture.md`](./architecture.md). Riftbound, le jeu de cartes
physique League of Legends de Riot, partage la base de DeckHand avec Magic.

**Ce qui est en place** : le catalogue est ingéré — 1 234 cartes distinctes,
1 451 impressions, 1 234 noms indexés — et cloisonné par `cards.game`. La
recherche ne mêle jamais les deux jeux.

**Les gabarits d'illustration sont mesurés** : (0,065 · 0,047 · 0,934 · 0,517)
pour les cartes verticales, (0,041 · 0,199 · 0,962 · 0,777) pour les 71 champs
de bataille horizontaux. Deux méthodes fondées sur la variance ont échoué avant
qu'une troisième, fondée sur la luminosité de l'image moyenne, n'aboutisse : le
cadre y est sombre, l'illustration en tons moyens, les pavés de texte quasi
blancs. Les
gabarits sont cloisonnés par jeu — essayer un cadre Magic sur une carte
Riftbound doublerait le calcul et le risque de correspondance fortuite.

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
publiée le 31 juillet 2026 : trop récente pour être cotée, pas un trou de
couverture réparti.

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

**Les homonymes se distinguent par leur illustration.** Quatre-vingts noms
Riftbound sont portés par plusieurs cartes réellement différentes, et leur ligne
de type est identique dans tous les cas — mesuré, 0 sur 80. Leurs illustrations
diffèrent en revanche toutes : `search_cards` rend désormais une URL, et une
vignette précède chaque résultat.

**Ce qui manque encore**, et qu'aucune formulation optimiste ne doit masquer :
les prix, le corpus de decks, et la confrontation de la reconnaissance à une
vraie carte papier. La boucle de valeur du produit — saisir, valoriser, proposer
des decks — n'est donc pas bouclée pour Riftbound. Les deux premiers manques
sont **des blocages de source, pas de code** : personne ne sert de prix
Riftbound par lot, et aucun agrégateur de decklists n'expose d'API.

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
| Prix | fournis par Scryfall | **non fournis par Riot** — API tierces, payantes pour un usage commercial |
| Corpus de decks | TopDeck.gg + MTGJSON | sites communautaires abondants, conditions non vérifiées |

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

- **Les prix.** Aucun pilier du produit n'y survit sans eux : valorisation de la
  collection et coût de complétion en dépendent tous deux. Le chaînage est en
  place — `card_prints.tcgplayer_id` est renseigné pour 84,4 % des impressions —
  mais il ne manque plus qu'une source qui accepte de coter **par lot**. Les API
  relevées plafonnent autour de 100 requêtes par jour en gratuit : à ce rythme,
  un seul passage sur 1 451 impressions demanderait une quinzaine de jours,
  quand les prix se rafraîchissent tous les jours. Le palier gratuit ne permet
  donc même pas un cycle. Ce qui rend l'ingestion Magic soutenable est le *bulk
  data* de Scryfall — une requête pour tout le catalogue ; c'est un équivalent
  Riftbound qu'il faut chercher, pas un quota plus élevé.
- **Le corpus de decks.** Plusieurs sites annoncent des dizaines de milliers de
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

## 5. Ce qui n'est pas fait, et pourquoi

Aucune migration, aucun code. Le modèle de données ne se dessine pas sur des
suppositions : c'est la règle qui a produit les décisions tenables de ce projet —
la zone d'illustration, la taille d'empreinte, le seuil de taille de texte ont
tous été mesurés avant d'être fixés, et plusieurs hypothèses de départ y ont été
démenties. Concevoir un schéma multi-jeu avant de connaître les champs réels
reproduirait exactement l'erreur que ce projet évite.
