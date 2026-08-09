# Architecture — DeckHand

Annexe technique du [`CLAUDE.md`](../CLAUDE.md). Décrit le pipeline de reconnaissance, le modèle de données, les connecteurs de sources et le moteur de suggestion.

---

## 1. Vue d'ensemble

```
   Flutter (mobile + web)  ── app/
      │  saisie texte · voix · photo · scan multi-cartes
      │  reconnaissance embarquée (empreintes + index local)
      ▼
   Jobs Python  ── api/   (exécutés à la demande, pas un serveur)
      │  construction de l'index d'empreintes
      │  ingestion multi-sources (un connecteur par source)
      ▼
   Supabase — Postgres · Auth · Storage
      ▲
      │  jobs d'ingestion planifiés
   Scryfall · TopDeck.gg · MTGJSON
```

**Aucun serveur intermédiaire.** L'application interroge Supabase directement ; le
moteur de matching vit dans la base, sous forme de fonctions SQL. `api/` n'expose
rien : ce sont des jobs lancés à la main ou par planification.

**Répartition des rôles.** La reconnaissance *à l'exécution* est embarquée dans l'app ; la *construction de l'index* est un travail serveur. Python parcourt le catalogue Scryfall, télécharge chaque illustration, calcule son empreinte et la jette. L'app télécharge le résultat compact et travaille hors ligne.

---

## 2. Pipeline de reconnaissance

### Principe

**On ne stocke jamais les images, seulement leurs empreintes perceptuelles.** Une empreinte de 64 bits par illustration : l'index complet du périmètre Commander + Modern pèse quelques centaines de kilo-octets au lieu de plusieurs gigaoctets.

### Chaîne à l'exécution

**Une carte à la fois (jalon 2) — pas de détection nécessaire.** L'utilisateur
cadre la carte dans un guide affiché à l'écran : sa position est donc connue, et
les étapes de détection et de redressement disparaissent. C'est ce qui rend le
jalon 2 nettement plus simple que le jalon 3.

1. **Découpe** — extraction de la zone d'illustration, à position fixe dans le cadre de visée.
2. **Empreinte** — calcul du hash perceptuel de cette zone.
3. **Recherche** — plus proche voisin par distance de Hamming dans l'index local. Une recherche linéaire sur quelques dizaines de milliers d'entrées reste instantanée ; aucune structure d'index sophistiquée n'est justifiée à cette échelle.
4. **Confirmation** — l'utilisateur valide les cartes reconnues avant écriture en collection (garde-fou §IV.8).

**Étalement multi-cartes (jalon 3)** — là seulement s'ajoutent le repérage des
quadrilatères et la correction de perspective. Plusieurs approches ont été
prototypées et mesurées sans qu'aucune n'atteigne un rappel exploitable ; le
détail et les impasses sont consignés dans
[`spread-detection.md`](./spread-detection.md), pour éviter de refaire ce chemin.

### Où se trouve l'illustration — mesuré, pas estimé

La zone d'illustration a été localisée en cherchant, dans le rendu complet de la
carte, la fenêtre qui reproduit l'illustration publiée par Scryfall.

| Cadre | gauche | haut | droite | bas |
|---|---|---|---|---|
| **moderne** (depuis 2003) | 0,080 | 0,120 | 0,920 | 0,550 |
| **ancien** (avant 2003) | 0,114 | 0,100 | 0,890 | 0,538 |

Magic a changé de cadre en 2003 et l'illustration n'y occupe pas la même zone —
un détail loin d'être anecdotique, le Pauper puisant dans toute l'histoire du
jeu. Sur 50 cartes tirées au hasard, le gabarit moderne seul situe correctement
l'illustration dans **42 cas**, contre **47** en essayant les deux et en retenant
la meilleure correspondance. Le coût est négligeable : deux empreintes, deux
recherches de quelques millisecondes. Un mauvais gabarit découpe de travers et
produit une empreinte éloignée de tout : il ne peut pas l'emporter par hasard.

Les mises en page spéciales — `saga` (illustration verticale), `transform`,
cartes pleine page — échappent aux deux gabarits. Elles relèveront de l'OCR du
nom, prévu en appoint.

### Choix de l'algorithme — dHash 64 bits

**dHash plutôt que pHash** parce que l'algorithme devra être réimplémenté à
l'identique en Dart : dHash tient en une vingtaine de lignes sans transformée ni
dépendance numérique, là où pHash exigerait une DCT.

**64 bits plutôt que 256, et c'est mesuré.** Une grille 16×16 a été comparée à la
grille 8×8 sur des illustrations réelles dégradées comme le ferait une photo
médiocre (recadrage, flou, sous-exposition, JPEG qualité 35) :

| | 64 bits | 256 bits |
|---|---|---|
| distance au plus proche voisin (médiane) | 21 | 104 |
| distance après forte dégradation | 3–12 | 31–72 |
| **rapport de séparation** (médiane) | **3,5×** | 1,9× |

Une grille plus fine capture des détails que le flou et la compression
détruisent en premier ; la dégradation touche donc proportionnellement plus de
bits. Augmenter la résolution de l'empreinte **dégrade** la reconnaissance.
Inutile de retenter.

Reconnaissance mesurée sur échantillon : 12/12 quel que soit le niveau de
dégradation, avec une marge au second candidat de 14 à 21 bits en conditions
normales, et de 6 à 16 bits en conditions rudes.

### Parité serveur ↔ application

L'index est calculé en Python, la reconnaissance s'exécute en Dart. Les deux
implémentations doivent produire les mêmes bits, faute de quoi la reconnaissance
échouerait **en silence**.

**Le redimensionnement est fait à la main des deux côtés.** Une première version
confiait la réduction aux bibliothèques (Lanczos côté Pillow,
interpolation cubique côté Dart) : les empreintes divergeaient sur 3 images de
test sur 5. La réduction passe désormais par un filtre de moyenne à bornes et
divisions entières, et la conversion en niveaux de gris par une formule entière
explicite. Cinq vecteurs de référence, générés depuis Python et rejoués par les
tests Dart, verrouillent cette parité au bit près.

**La parité stricte est en revanche impossible sur des JPEG**, et ce n'est pas un
défaut à corriger : deux décodeurs JPEG ne reconstituent pas exactement les mêmes
pixels, la norme le tolère. Mesuré sur 30 illustrations réelles, l'écart imputable
au décodeur vaut **0 bit en médiane, 0,7 en moyenne, 5 au maximum** — petit devant
la quinzaine de bits qui sépare deux cartes. `app/tool/verify_parity.dart` mesure
cet écart et n'alerte qu'au-delà de 8 bits, seuil au-delà duquel la cause ne
serait plus le décodeur mais l'algorithme.

### Mesures sur l'index complet — 31 634 illustrations

**Densité.** Aucune collision : les 31 634 empreintes sont toutes distinctes. Mais
la séparation se resserre avec la taille du catalogue — distance médiane au plus
proche voisin de **14 bits** contre 18 sur un échantillon de 400, et **18,7 %**
des cartes ont un voisin à moins de 12 bits, soit le seuil de confiance retenu.

**Reconnaissance de bout en bout**, sur 120 cartes tirées au hasard et dégradées
comme le ferait une photo :

| Régime | Bonne carte en tête | Dont avec assurance | **Fausse avec assurance** |
|---|---|---|---|
| Bonne photo | 120/120 (100 %) | 120 | **0** |
| Photo moyenne | 120/120 (100 %) | 120 | **0** |
| Mauvaise photo | 117/120 (98 %) | 93 | **0** |

**Aucun faux positif annoncé avec assurance**, dans les trois régimes. C'est le
seul résultat qui pouvait condamner l'approche.

La densité ne se traduit donc pas en erreurs, et c'est le design qui l'explique :
quand deux cartes sont serrées, la marge de confiance chute et le système
**hésite au lieu d'affirmer**. Sur une mauvaise photo, 24 cartes sur 120 sont
trouvées mais présentées avec réserve — l'utilisateur confirme, c'est du confort
en moins, jamais une erreur silencieuse. Les 3 cartes manquées le sont elles
aussi avec réserve.

**Conclusion : dHash 64 bits suffit au jalon 2 ; l'OCR n'est pas nécessaire.** Il
reste utile pour les mises en page hors gabarit (`saga`, `transform`, pleine
page), que l'empreinte ne sait pas cadrer.

### Pourquoi hacher l'illustration et non la carte entière

L'illustration est **identique en français et en anglais** ; seul le cadre de texte change. En hachant l'art, le mélange linguistique de la collection devient un non-sujet. Hacher la carte entière produirait deux empreintes distinctes pour la même carte.

### Limites structurelles connues

| Limite | Nature | Conséquence |
|---|---|---|
| Rééditions partageant la même illustration | Indiscernables par empreinte seule | L'édition se choisit à la main dans le sélecteur, la reconnaissance n'ayant pas à trancher. Valorisation par défaut tant qu'elle n'est pas précisée : impression la moins chère. |
| Cartes full-art, borderless, showcase | Géométrie non standard | Le découpage à position fixe échoue. Nécessite une détection de gabarit ou une empreinte de secours sur la carte entière. |
| Cartes empilées | Optique, non algorithmique | Seule la carte du dessus est visible. D'où les deux modes retenus : étalement et feuilletage. |

### OCR

Rôle **secondaire** : désambiguïsation quand plusieurs empreintes sont proches, et lecture du symbole d'extension. Doit gérer les noms français et anglais, résolus vers le nom oracle anglais (les decklists et les règles sont en anglais).

---

## 3. Sources de données

| Source | Rôle | Accès | Contraintes |
|---|---|---|---|
| **Scryfall** | Catalogue, noms localisés FR, identité couleur, légalités par format, prix EUR/USD | Public, sans clé | ≤ 10 req/s · `User-Agent` descriptif obligatoire · *bulk data* à privilégier · prix rafraîchis 1×/jour · attribution · interdiction de paywaller ou de simplement repackager |
| **TopDeck.gg** | Corpus méta — decklists de tournoi, formats 60 cartes | Clé gratuite au portail développeur | 100 req/min · **crédit visible + lien obligatoires** · ne couvre **pas** le Commander multijoueur |
| **EDHTop16** | Corpus Commander compétitif (cEDH) | GraphQL public sans clé, `https://edhtop16.com/api/graphql` | Conditions d'usage non formalisées — API publique et documentée, son auteur en encourage l'usage. À surveiller. |
| **MTGJSON** | Précons officiels (Commander, Challenger, starter) | Téléchargement libre | Licence MIT, redistribution libre |
| **Spicerack** | Corpus méta complémentaire, 24+ formats | Clé API | Conditions d'usage peu documentées — à confirmer avant dépendance |
| **Archidekt** | Decks communautaires budget / casual | API en lecture, non documentée | Tolérée et encouragée par l'équipe, mais susceptible d'être fermée. **Jamais en dépendance critique.** |
| **Moxfield** | — | Sur demande à `support@moxfield.com` | Scraping interdit par les conditions. Option à activer si le besoin se confirme. |
| **EDHREC** | — | **Interdit** | Les conditions prohibent explicitement les requêtes automatisées et la republication. |
| **Riftcodex** | Catalogue Riftbound — noms, types, domaines, raretés, extensions, illustrations | Public, sans clé, paginé à 100 | **Conditions non publiées.** Projet de fans non affilié à Riot. À défaut de règles explicites, on lui applique celles de Scryfall : `User-Agent` descriptif, débit bas, attribution visible. Les illustrations qu'il référence sont servies par le CDN officiel de Riot, jamais réhébergées. |
| **API Riot (Riftbound)** | Source officielle visée pour Riftbound | **Fermée** aux clés de développement | Mesuré : une clé valide obtient 403 sur les quatre routes régionales tout en répondant 200 ailleurs. L'ouverture demande une approbation nommée avec prototype. Attribution imposée, texte officiel obligatoire, pas d'assets externes. |

### Volumes et formats réellement disponibles

Mesures relevées sur les 90 derniers jours, API en main.

| Source | Format | Tournois | Decklists exploitables |
|---|---|---|---|
| TopDeck.gg | **Pauper** | 64 | **725** |
| TopDeck.gg | Modern | 41 | 113 |
| TopDeck.gg | Duel Commander | 24 | 63 |
| TopDeck.gg | Commander multijoueur | **0** | **0** |
| EDHTop16 | Commander (cEDH) | flux continu | decklists complètes, 99 cartes + commandant |

Trois enseignements structurants :

1. **TopDeck.gg n'expose aucun Commander multijoueur.** Aucun libellé de format n'y répond ; seul « Duel Commander » existe, qui est un format 1v1 aux bannissements distincts. Le Commander passe donc par EDHTop16 et MTGJSON.
2. **Pauper est six fois mieux servi que Modern** en volume de decklists, pour des decks d'un ordre de grandeur moins chers.
3. **Le cEDH est hors de portée par construction** : les decks relevés sur EDHTop16 valent 10 000 à 11 000 $. C'est un corpus de consultation, jamais de complétion.

### Résolution des cartes vers Scryfall

Les deux sources n'ont pas la même qualité d'identifiants, ce qui dicte deux chemins de résolution :

- **EDHTop16** fournit l'`oracleId` Scryfall sur chaque carte → résolution directe, sans ambiguïté.
- **TopDeck.gg** utilise des identifiants propriétaires qui ne sont **pas** des Scryfall IDs (vérifié) → résolution par nom, avec la tolérance aux variantes que cela impose.

### Le problème du corpus accessible

Les decklists de tournoi sont des decks **compétitifs, donc chers** : un Modern de haut niveau embarque une base de terrains à plusieurs centaines d'euros. Alimenter l'app uniquement en decks de tournoi rendrait la fonctionnalité « à quelques cartes près » inexploitable — elle répondrait systématiquement « il te manque 41 cartes pour 780 € ».

**Résolution retenue** : deux corpus distincts et explicitement étiquetés.
- **`accessible`** — précons officiels via MTGJSON, redistribution libre, pile dans la zone d'une collection ordinaire.
- **`competitive`** — méta de tournoi via TopDeck.gg, affiché comme objectif long terme.

L'étiquetage n'est pas cosmétique : il conditionne la crédibilité de la promesse produit, et l'interface le rend visible sur chaque deck.

### Corpus effectivement importé

| Source | Format | Decks | Étiquette |
|---|---|---|---|
| TopDeck.gg | Pauper | 725 | `competitive` |
| TopDeck.gg | Modern | 113 | `competitive` |
| MTGJSON | Commander | 190 | `accessible` |

Les précons font exactement 100 cartes, commandant inclus — MTGJSON le livre dans un champ séparé, mais il compte dans le total du deck et doit donc être réintégré au calcul de complétion.

**Qualité de résolution** : MTGJSON fournit l'`oracleId` Scryfall, la résolution est donc directe ; seules deux cartes sur l'ensemble des précons sont absentes du catalogue, parce qu'elles ne sont légales dans aucun format couvert. TopDeck.gg impose au contraire une résolution par nom, d'où le comptage des échecs et le seuil de rejet décrits plus bas.

---

## 4. Modèle de données

**Deux jeux, une seule base.** `cards.game` (`magic` ou `riftbound`) cloisonne
les catalogues : tout ce qui fait la valeur du produit — collection, impressions,
empreintes, complétion — est identique d'un jeu à l'autre, seul le catalogue
diffère. `search_cards` prend un paramètre de jeu, `magic` par défaut pour que
les appels antérieurs gardent leur comportement. Détail et arbitrages :
[`multi-game.md`](./multi-game.md).

| Table | Rôle |
|---|---|
| `cards` | Miroir du catalogue Scryfall — nom oracle, identité couleur, légalités |
| `card_prints` | Impressions : édition, langue, prix, illustration — 162 000 lignes |
| `art_hashes` | Index d'empreintes, servi à l'app |
| `users` | Comptes Supabase Auth |
| `collections` / `collection_items` | Possessions, par utilisateur |
| `decks` / `deck_cards` | Corpus normalisé, toutes sources confondues |
| `deck_sources` | Provenance et mentions d'attribution |

**`deck_sources` porte l'attribution.** TopDeck.gg impose un crédit visible ; l'exigence doit voyager avec la donnée pour que l'interface ne puisse pas l'oublier.

**Granularité de collection retenue** : nom + édition. L'état (NM/played) et le caractère *foil* sont ignorés — pure saisie manuelle, sans apport pour le deckbuilding.

### Deux voies de reconnaissance, dans l'ordre

Depuis le test terrain, la carte est identifiée **par son nom d'abord**, par son illustration ensuite.

1. **Lecture du nom** — ML Kit reconnaît le texte, embarqué et hors ligne (aucune image ne quitte l'appareil). Les lignes situées dans le tiers supérieur sont retenues, débarrassées du bloc d'identification en marge (« C 0679 », « MSC★FR »), du coût en mana, de la force/endurance et du copyright. Les trois premières partent ensemble vers `search_cards`, dont la tolérance aux fautes absorbe les erreurs de lecture.
2. **Empreinte d'illustration** — inchangée, elle sert désormais de recours (texte illisible, fort reflet, web où ML Kit n'existe pas) et de **confirmation** : quand les deux voies désignent la même carte, le doute est levé quelle que soit la distance.

Le nom est le seul repère stable : il figure en première ligne sur toutes les éditions depuis 1993, reste lisible de travers, et ne dépend pas de l'illustration — donc pas de l'édition. L'empreinte garde en revanche un rôle que le nom ne peut pas tenir : distinguer deux impressions d'une même carte.

`ScanMethod` remonte la voie employée jusqu'à l'écran, qui annonce « nom lu », « illustration » ou « nom et illustration ». Dire d'où vient une proposition permet à l'utilisateur de juger s'il peut la croire.

**Coût :** +30 Mo d'APK (53,6 → 83,8 Mo), le modèle latin étant empaqueté. Les modules chinois, japonais, coréen et devanagari sont écartés par `android/app/proguard-rules.pro` — sans quoi R8 refuse de compiler, le plugin les référençant sans qu'ils soient présents.

### Ce que le premier test terrain a montré (2026-08-07)

Deux cartes scannées, deux échecs, **deux causes distinctes** — mesurées, pas supposées.

**1. L'index d'empreintes est trop mince.** Il ne contient qu'une illustration par carte. Sur Farseek (55 impressions), l'illustration indexée est celle de Ravnica 2005 ; l'exemplaire tenu venait de *Marvel Super Heroes Commander* (2026), à une distance de 32 — hors de portée du seuil de confiance de 12. Sur un échantillon de 11 impressions de cette carte, 8 partagent la même illustration et 3 en ont une radicalement différente (distances 18, 33, 36). L'affirmation « une carte rééditée garde le plus souvent son illustration » est donc vraie aux trois quarts, et fausse pour le quart restant — assez pour faire échouer un scan sur quatre.

**2. Le pipeline exige un cadrage irréaliste.** Sur Big Wheel, l'illustration *était* indexée (distance 0) et le gabarit la découpe correctement (distance 1) : le scan aurait dû réussir. Il a échoué sur le cadrage. Tolérance mesurée en simulant une marge de table autour de la carte :

| Marge autour de la carte | Distance | Verdict |
|---|---|---|
| 0 % | 1 | reconnue |
| 2 % | 7 | reconnue |
| 5 % | 15 | incertaine |
| 10 % | 24 | perdue |

Un décalage latéral de 2 % suffit également à franchir le seuil. **Le pipeline tolère 2 à 3 % d'écart** — soit 2,6 mm sur la hauteur d'une carte. Aucun cadrage à main levée n'atteint cette précision.

Cette exigence n'était pas visible dans les mesures antérieures (100 % de reconnaissance, 0 faux positif) parce qu'elles partaient des `art_crop` de Scryfall, c'est-à-dire d'illustrations déjà découpées au pixel près. **Le protocole validait le comparateur d'empreintes, jamais la chaîne photo → illustration.**

Conséquence doctrinale : le cadrage guidé ne remplace pas la détection des bords de la carte. La note « la détection de contours ne devient nécessaire qu'au jalon 3 » est invalidée — elle l'est dès le jalon 2.

### Étalement : distinguer un nom d'un texte de règles

Sur une photo d'étalement, toutes les lignes lues sont candidates — les noms
comme les règles. Or les règles **citent** des noms de cartes, et une ligne
citant une carte en fabrique une qui n'était pas sur la table. Le tri se fait
sur la taille du texte, le nom étant imprimé plus gros que le corps.

**La hauteur se mesure sur les quatre coins de la ligne, jamais sur sa boîte
englobante.** Celle-ci est alignée sur les axes de l'image alors que la ligne
est inclinée dès que la carte n'est pas parallèle au capteur : sa hauteur vaut
alors *hauteur des caractères + longueur × sinus de l'angle*, et le second terme
écrase le premier. Mesuré sur un étalement réel, la hauteur de boîte corrèle à
**0,965** avec le nombre de caractères — elle ne mesurait pas la taille du
texte, mais sa longueur. Le filtre retenait donc les lignes longues, c'est-à-dire
les règles, et écartait les noms : « Agent d'Atlas » (13 caractères) tombait à
0,82 fois la médiane quand une ligne de règles de 38 caractères montait à 2,47.
Les coins suivent l'inclinaison ; la corrélation retombe à **0,408**.

**Le filtre de taille est désactivé, et c'est une conclusion.** Il devait
empêcher les textes de règles de fabriquer des cartes fantômes ; quatre mesures
successives l'ont démonté :

1. Il ne mesurait pas la taille du texte mais sa **longueur** — la hauteur venait
   d'une boîte alignée sur les axes, qui grandit avec la ligne dès que la carte
   penche. Corrélation de **0,965** avec le nombre de caractères.
2. Corrigé (hauteur prise sur les coins du quadrilatère), il ne séparait plus
   rien : sur des cartes entières, le rapport entre la plus grande ligne et la
   médiane tombe à **1,20**. Il n'y a pas deux populations à départager.
3. Il **masquait le vrai goulot** : plus il laissait passer de lignes, plus le
   plafond de candidats coupait tôt dans la photo. Le désactiver *dégradait* donc
   le résultat, ce qui entretenait l'illusion qu'il servait.
4. Le plafond relevé, la mesure est sans appel :

| photo | avec filtre | sans filtre |
|---|---|---|
| dix-sept cartes à plat | 65 % rappel, 92 % précision | **88 % / 94 %** |
| dix-neuf cartes en éventail | 84 % / 94 % | **84 % / 94 %** |

Ce qui écarte réellement les fausses cartes est ailleurs, et se cumule : le
**seuil de score**, la **règle de longueur relative** (un fragment ne couvre que
0,21 du nom qu'il trouve), le **nettoyage des parasites** de bordure et le
**filtre des lignes de type**. C'est ce quatuor qui fait le travail.

Le mécanisme reste dans le code, à zéro : `app/tool/sweep_spread_threshold.dart`
le rejoue sur des lignes réellement lues, et une photo future pourrait rouvrir la
question.

**Une longueur minimale de nom n'apporte rien non plus.** Balayée de 3 à 10
caractères, elle ne change pas le résultat : les fragments sont déjà écartés par
la longueur relative. À 8 caractères elle gagnerait une fausse carte, au prix de
**662 cartes du catalogue** (2,1 % — *Shimmer*, *Abolish*, *Revive*) rendues
invisibles au scan. Elle reste donc à 3.

**Le plafond de candidats a longtemps été le vrai goulot.** Chaque ligne retenue
coûte une requête au catalogue, d'où un plafond — mais il coupait **par
position**, de haut en bas. Sur une photo de dix-sept cartes entières, 141 lignes
sont lues, 85 passent le filtre de taille, et les quarante-cinq dernières
n'étaient jamais interrogées : les rangées du bas restaient invisibles.

Le symptôme trahissait la cause et l'a longtemps masquée : **désactiver le filtre
de taille dégradait le résultat** (35 % de rappel contre 47 %), parce que plus de
lignes passaient et que le plafond coupait d'autant plus tôt. À seuil constant,
le seul passage de 40 à 150 fait monter le rappel de **47 % à 65 %**, sans une
fausse carte de plus. Les requêtes partent désormais par lots de 25 : les
enchaîner rendrait l'attente insupportable, en lancer cent cinquante d'un coup
saturerait la connexion pour un gain nul.

**Plus la photo est soignée, plus le plafond mordait.** Dix-sept cartes entières
produisent 141 lignes ; un éventail qui masque les trois quarts de chaque carte
n'en donne que 93. Ranger ses cartes dégradait donc le résultat — exactement
l'inverse de ce que l'écran recommande.

### Une requête pour toute la photo, pas une par ligne

Le scan cherchait chaque ligne candidate par un appel séparé. Sur une photo de
dix-sept cartes — 141 lignes lues, 112 retenues — cela prenait **77 secondes**,
et les grouper par vagues de vingt-cinq n'y changeait rien.

**Le chiffre qui tranche : chaque vague durait quinze secondes, quelle que soit
la vague.** Vingt-cinq requêtes lancées de front mettent le même temps que
vingt-cinq requêtes enchaînées — 25 × 600 ms. Le serveur les traite l'une après
l'autre ; la concurrence côté client n'achète rien, et le total vaut
mécaniquement « nombre de lignes × 600 ms ». Régler la taille des vagues ne
pouvait donc rien donner : c'est le nombre d'allers-retours qu'il fallait
supprimer.

Pire, la connexion lâchait en route. Dix-huit requêtes sur cent douze mouraient
depuis un poste filaire ; depuis un téléphone tenant vingt-cinq connexions TLS
ouvertes un quart de minute, **toutes**. L'écran restait alors vide — et vide
d'une manière indiscernable d'un étalement illisible, puisque le code
convertissait chaque échec en « aucune carte trouvée ».

`search_cards_bulk` prend le tableau de noms d'un coup : un aller-retour, une
exécution, un plan de requête. Les mêmes 112 lignes reviennent en **3,3 s**, et
le nombre de cartes trouvées passe de 6 à 15. La latence n'est plus payée
qu'une fois.

Elle ne remplace pas `search_cards`, qui sert la recherche interactive — là,
l'utilisateur veut plusieurs propositions pour **un** nom ; ici c'est l'inverse,
un seul résultat pour **beaucoup** de noms.

**L'erreur ne doit jamais ressembler à un résultat.** Le `catch` qui rendait une
liste vide a coûté une session entière de diagnostic : le journal montrait 112
recherches sans résultat, ce qui accusait la reconnaissance alors que le réseau
était en cause. Il a fallu rejouer les requêtes depuis le poste pour le voir. La
panne remonte désormais jusqu'à l'écran.

### Compter les exemplaires

Deux exemplaires d'une même carte ne comptaient que pour un, et la perte était
silencieuse. La cause n'était ni le seuil ni la recherche : les candidats
étaient **dédoublonnés par leur texte**. Quatre exemplaires d'un même dinosaure
sont lus quatre fois, à l'identique, et trois lectures disparaissaient avant
même d'atteindre le catalogue.

Ce qui manquait pour trancher, c'est de distinguer deux cas que seul l'écart
sépare :

| cas | écart mesuré |
|---|---|
| un nom coupé en deux par la reconnaissance | 1 à 2 hauteurs de texte (lignes consécutives) |
| deux exemplaires posés sur la table | **8,3 hauteurs au plus serré**, 47 et 80 sur les noms de carte |

Le seuil se pose à 4 hauteurs, au large dans ce fossé. **L'unité fait tout** :
en pixels, il casserait dès qu'on s'éloigne de la table — la hauteur du texte,
elle, suit l'échelle de la photo.

Le regroupement final se fait à l'**identité de carte**, pas à la ligne lue :
deux exemplaires sont rarement lus à l'identique (« Dinosaure de la Terre
sauvage » et « ...sauyage »), et un exemplaire anglais rejoint son homologue
français sur le même `oracle_id`.

Vérifié contre une vérité terrain de onze cartes — quatre dinosaures (deux
anglais, deux français) et deux Mister Hyde : le décompte rend **×4 et ×2**. Sur
la photo de dix-sept cartes toutes différentes, il n'invente aucun exemplaire.

La quantité proposée reste une proposition : l'écran la présente, l'utilisateur
l'ajuste (garde-fou §IV.8).

### Les bords servent de garde-fou, jamais de source

Les rectangles de cartes sont calculés et **branchés au scan** — mais comme
filtre, jamais comme source de vérité. Le scan continue de trouver les cartes
par leurs noms ; la délimitation ne fait qu'écarter les citations.

Trois précautions rendent l'ajout incapable de dégrader ce qui marche :

1. **Seuls les rectangles d'une carte isolée comptent.** Un bloc de cartes
   soudées peut avoir le rapport d'une carte — mesuré, un groupe couvrant 49 %
   de la surface encrée affichait 1,44. C'est la surface, comparée aux autres
   rectangles, qui le démasque ; il est alors ignoré.
2. **Le nom et la citation sont aux deux bouts, et il faut savoir lequel est
   lequel.** Mesuré sur un même rectangle : le nom à 9 %, la citation à 93 %.
   Prendre la distance au bord *le plus proche* les ramène toutes deux sous
   10 % et les rend indiscernables — c'est ce qui a fait échouer la première
   version. Il faut une position orientée.
3. **Le sens se lit dans la photo, il ne se suppose pas.** Les cartes d'une même
   photo sont posées dans le même sens, mais ce sens change d'une photo à
   l'autre : noms à 6-14 % ici, à 93-103 % là. Les rectangles ne portant qu'une
   correspondance la désignent sans ambiguïté — c'est un nom —, et la majorité
   tranche pour les autres.
4. **Le bout, pas le milieu.** Sur des rectangles imparfaits, la position d'un
   nom se décale : *Croisade de Murdock* tombait à 56 % et se faisait rejeter.
   Les vraies citations siègent à 86-93 % du bout des noms. Le seuil se pose à
   70 %.
5. **Une ligne hors du rectangle est le nom du voisin, pas une citation.** C'est
   ce qui sauve *Gorille mercenaire*, dont le nom débordait de trois pour cent
   sur la carte d'à côté.
6. **Toute panne rend le résultat non filtré.** Image absente, illisible,
   format inattendu : le scan rend ce qu'il rendait avant.

Mesuré sur les trois photos de référence :

| photo | avant | après |
|---|---|---|
| quinze cartes espacées | 9 vraies, 1 fausse | 9 vraies, **0 fausse** |
| onze cartes espacées | 8 vraies, 2 fausses | 8 vraies, **1 fausse** |
| dix-sept cartes jointives | 17 vraies, 0 fausse | inchangé — rien rejeté |

Jamais pire, parfois mieux. Ce qui reste — « Sacrificz » trouvant *Sacrifice* —
n'est pas une citation mais un mot de règles capitalisé, qu'aucun rectangle ne
distingue.

### Deux fausses cartes que ni le score ni la longueur ne voient

Une ligne peut porter **exactement** le nom d'une carte sans qu'aucune carte de
ce nom soit sur la table. Le score vaut alors 1,00, la longueur est parfaite, et
tous les garde-fous numériques passent à côté. Deux causes, mesurées sur photo
réelle.

**Le texte d'ambiance signe son auteur.** En bas d'une carte, un personnage
parle : « —Ka-Zar of the Savage Land ». Ce personnage porte le nom d'une vraie
carte. Le tiret d'ouverture est le seul indice — et il suffit : **aucun des
63 220 noms indexés ne commence par un tiret**. Sur trois photos, les huit
lignes ainsi ouvertes étaient toutes des attributions, et aucun vrai nom n'en
portait. Les trois formes de tiret (union, demi-cadratin, cadratin) comptent :
la reconnaissance rend l'une ou l'autre selon la police et la netteté.

**Un nom de carte est capitalisé, un fragment de règles ne l'est pas.** Les
lignes « down. » et « of turn. », arrachées à un texte de règles anglais,
trouvaient *Down* et *Turn* — deux cartes qui existent. Coût mesuré d'écarter
les lignes ouvertes par une minuscule : **5 noms sur 63 220** (0,008 %), tous
des faces secondaires dont la face principale reste trouvable. Sur trois photos
et trente-deux cartes réelles, aucune n'a été lue en commençant par une
minuscule.

Ces deux règles réduisent aussi le travail : les candidates d'une photo passent
de 127 à 68, la majorité du texte de règles commençant par une minuscule.

Ce qu'elles ne couvrent pas : « Sacrificz », mot de règles capitalisé en début
de phrase, trouve toujours *Sacrifice*. Le distinguer demanderait de savoir à
quelle carte appartient la ligne — c'est-à-dire de détecter les bords, chantier
ouvert.

### Le seuil de score : 0,60, et pourquoi pas 0,72

Ce que le seuil élevé écartait n'était pas du hasard, mais des lectures
mutilées. L'appareil confond des lettres sur les noms courts en capitales :
« Agents du S.H.LE.LD. » (I lu L) marquait 0,60 et « Alennifer Walters » (J lu
Al) 0,67 — deux correspondances parfaitement justes, refusées par un seuil à
0,72.

Mesuré sur les deux photos, filtres appliqués :

| photo | à 0,72 | à 0,60 |
|---|---|---|
| dix-sept cartes à plat | 15 justes, 0 fausse | **17 justes, 0 fausse** |
| dix-neuf cartes en éventail | 16 justes, 1 fausse | 18 justes, 2 fausses |

Quatre cartes gagnées contre une fausse — « derniers mots », fragment de texte
français qui tombe sur la carte anglaise *Last Word*.

**La borne inférieure est mesurée, pas supposée** : à 0,53, « Vieilance » — le
mot-clé *vigilance* mal lu — trouve la carte *Vigilance*, qui existe. Le seuil
retenu est le dernier cran qui la refuse.

**L'échange renverse un arbitrage, assumé.** La règle antérieure disait l'inverse
— mieux vaut manquer une carte que d'en inventer une. Ce qui la renverse est la
forme de l'écran : l'étalement propose une **liste à cocher**, jamais un ajout
direct. Une fausse carte y est visible et se décoche ; une carte manquante est
silencieuse, et il faut la retaper. Le coût est asymétrique dans l'autre sens
que ne le supposait le seuil.

Deux pièges de méthode rencontrés en réglant ceci, à ne pas refaire :

1. **Mesurer sans les filtres Dart gonfle les fausses.** Une première mesure
   interrogeait la base directement et comptait « Éphémere → Ephemerate » parmi
   les erreurs : le filtre des lignes de type l'écarte pourtant bien avant la
   recherche. `tool/dump_fan_candidates.dart` imprime les candidats tels que
   l'application les produit.
2. **Une seule photo ne suffit pas.** À plat, descendre le seuil ne coûte
   aucune fausse ; en éventail, il en coûte une. Tout réglage tiré d'une photo
   se vérifie sur l'autre.

**Validé sur un étalement de dix-neuf cartes en éventail** : 16 reconnues,
**aucune fausse**. Les trois manquantes échappent au réglage pour trois raisons
distinctes — un nom non lu par l'appareil, un nom lu trop mal pour atteindre le
seuil de score (« A lennifer Walters », 0,64), et un nom masqué correctement
refusé parce que tronqué. Avant correction du seuil et de la longueur, la même
photo donnait 13 cartes dont une fausse.

**Une ligne de capacités n'est pas un nom.** Toute carte imprime ses mots-clés
sur une ligne — « Vol, vigilance » — courte, bien formée, sans parasite : le
score y répond *Vigilance*, qui existe vraiment, et ni la longueur ni le filtre
des lignes de type ne peuvent s'en apercevoir. Une ligne est donc écartée dès
qu'elle contient **deux** mots-clés ou plus.

Deux, et non un : cinq cartes s'appellent exactement comme un mot-clé — *Flight*
(« Vol »), *Lifelink*, *Persist*, *Threaten* (« Menace »), *Vigilance* — et la
règle naïve les rendrait invisibles au scan. Vérifié sur les 62 959 noms
indexés : **aucun** n'en contient deux, un nom de carte n'énumérant pas des
capacités. Le pluriel sépare exactement les deux, et la règle ne coûte rien.

Seuls les mots-clés permanents figurent dans la liste : ce sont ceux qu'on
croise partout, donc ceux qui produisent des faux positifs. Ceux propres à une
extension sont trop rares pour valoir la charge d'entretien.

**Un fragment de nom ne vaut pas correspondance.** Une carte à demi recouverte
ne livre qu'un début de nom, et ce début est souvent le préfixe exact d'une autre
carte : « Origine de » a trouvé « Origine de Thor » avec un score de 0,94 quand
la carte posée était « Origine des Vengeurs ». Le score ne peut pas s'en
apercevoir. La longueur, si : sur trois étalements réels, toute correspondance
juste couvre de 0,94 à 1,12 fois la longueur du nom trouvé — le texte lu peut
dépasser, la lecture ajoutant des parasites — quand le seul faux tombe à 0,67. Le
texte lu doit donc couvrir au moins **0,80** du nom trouvé.

**La comparaison locale a été essayée et écartée, sur mesure.** L'idée
paraissait fondée : comparer chaque ligne à ses voisines plutôt qu'à toute la
photo devait annuler l'effet de la distance. Rejouée sur les lignes réelles de
l'éventail, elle fait **pire** que la médiane globale — 12 noms retenus sur 17
contre 17 sur 17, quelle que soit la largeur de bande essayée. La raison tient à
la disposition : un étalement en éventail forme un arc, si bien qu'une bande
horizontale rassemble une carte du fond et une carte du premier plan. Le
voisinage géométrique ne recouvre pas « la même carte », et le regroupement en
blocs de ML Kit reposerait sur le même pari.

À 1,00, le filtre ne perd d'ailleurs plus aucun nom lu : **17 sur 17**. Le rappel
n'est plus limité par le tri mais par la lecture — deux noms sur dix-neuf n'ont
pas été lus du tout.

### Reconstruire la géométrie d'une carte depuis son nom — écarté sur mesure

L'idée : la ligne du nom occupe une place connue du gabarit, donc sa position et
sa taille devraient permettre de retrouver les bords de la carte, puis de
découper l'illustration — ce qui rendrait à l'étalement les deux atouts du scan
d'une carte, la confirmation croisée et le choix de l'édition.

**Elle demande une précision qu'on ne sait pas atteindre.** Mesuré sur un
étalement réel, la hauteur du texte des noms varie de ±13 % alors que les cartes
sont à distance comparable et que la police est la même : c'est du bruit de
mesure, pas de la perspective. La largeur par caractère ne fait pas mieux (±10 %).

Ce que cette précision permettrait, mesuré en dégradant volontairement le
découpage et en cherchant **parmi les seules éditions d'une carte déjà
identifiée** — cas bien plus tolérant que le catalogue entier :

| erreur de découpage | bonne édition en tête |
|---|---|
| 0 % | 100 % |
| **5 %** | **100 %** |
| 10 % | 78 % |
| 15 % | 59 % |

Il faudrait donc rester sous 5 % ; on sait faire 13 %. À ce niveau, une carte sur
trois recevrait une **mauvaise** édition — pire que pas d'édition du tout, car la
valorisation deviendrait fausse sous une apparence de précision, là où l'absence
d'édition est un plancher assumé.

Combler l'écart supposerait de détecter les bords réels de la carte, c'est-à-dire
la segmentation d'image écartée par [`spread-detection.md`](./spread-detection.md).
Le même bénéfice s'obtient sans rien deviner : **le sélecteur d'édition est
offert sur l'écran d'étalement**, sous chaque carte repérée. Facultatif — imposer
un choix par carte annulerait le gain de saisir vingt cartes d'un geste — et sans
lui la valorisation reste au prix plancher. Un geste juste vaut mieux qu'un
calcul faux.

Deux échecs restent hors de portée de ce réglage : une carte dont le nom n'est
pas lu du tout (reflet, angle) ne peut être rattrapée par aucun seuil, et deux
exemplaires identiques côte à côte comptent pour un — la quantité s'ajuste à la
main.

**Maintenir une ligne en affiche l'illustration**, sur l'étalement comme sur la
dictée. Ces deux écrans valident **en bloc** : c'est là que le garde-fou §IV.8
pèse le plus, et un nom seul ne suffit pas toujours à décider — deux cartes
portent des titres voisins, une lecture approximative en propose une troisième.
L'illustration est ce que l'œil reconnaît avant même de lire. Le geste est celui
du sélecteur d'édition, pour qu'il n'y en ait qu'un à apprendre ; l'image se
charge à la demande, jamais d'avance.

### Dictée continue : le répit avant de relancer

L'écoute se relance seule après chaque phrase, le moteur Android ne tenant pas
une session ouverte. **Le délai de relance décide si la phrase est gardée ou
perdue**, et c'est le seul paramètre qui compte ici.

Le moteur clôt parfois sa session sans conclure : la phrase est transcrite, elle
s'affiche à l'écran, mais aucun résultat *final* n'est livré — or c'est le final,
et lui seul, qui déclenche la recherche au catalogue. `speech_to_text` rattrape
ce cas : à l'arrêt, il arme un délai de deux secondes au terme duquel la dernière
transcription partielle est promue en résultat final. Mais `listen()` **annule ce
rattrapage** dès son premier geste. Relancer au bout de 400 ms le détruisait donc
1,6 s avant qu'il ne serve, et la carte dictée disparaissait sans un mot.

Mesuré sur l'appareil : une carte prononcée, neuf transcriptions partielles,
aucun final, relance à +401 ms — rien n'était jamais cherché. Ce n'était pas un
essoufflement progressif : **la première phrase était déjà perdue** dès que le
moteur ne concluait pas de lui-même, ce qui devient fréquent après plusieurs
sessions consécutives (`error_speech_timeout` à répétition).

La relance attend donc **2,2 s tant qu'aucun final n'est venu**, et 400 ms
sinon. Le cas courant garde sa réactivité ; le cas dégradé récupère sa phrase, et
la promotion émet à son tour un « done » qui ramène le délai à 400 ms — le coût
n'est payé que lorsqu'il n'y a rien à récupérer. La règle vaut aussi pour
`onError`, qui suit la fin de session de quelques dizaines de millisecondes et
écraserait sinon la relance longue par une courte.

Le seuil de test est ancré sur `SpeechToText.defaultFinalTimeout` plutôt que sur
une constante recopiée : si le paquet change son rattrapage, le test le signale
au lieu de laisser la dictée redevenir muette en silence.

### Éditions

`card_prints` conserve **toutes les impressions anglaises et françaises** des cartes du périmètre : 162 000 lignes, ~55 Mo, mesurés en parcourant l'export `all_cards` avant d'ingérer. Les autres langues tripleraient le volume sans servir une collection franco-anglaise.

Aucun plafond par carte, bien que la médiane soit de 3 impressions et le maximum de 1 269 (les terrains de base). Ne garder que les N moins chères ferait disparaître exactement l'édition qu'on cherche quand elle est ancienne et cotée — or c'est précisément celle-là qu'on veut désigner. C'est au sélecteur de rendre mille éditions navigables (recherche par extension, possédées en tête), pas à l'ingestion de les amputer.

`collection_items.print_id` est **nullable, et le rester est un état de plein droit** : on saisit vite, on précise plus tard. La contrainte `UNIQUE NULLS NOT DISTINCT (collection_id, oracle_id, print_id)` fait cohabiter « trois Foudre non précisées » et « une Foudre de MH2 » sur deux lignes distinctes. La valorisation suit : prix de l'édition quand elle est connue, prix le moins cher connu sinon — un plancher, jamais une invention.

**L'index d'empreintes ne suit pas ce volume.** `pending_prints` ne retient qu'une impression de référence par carte *sans aucune empreinte* : le filtre porte sur la carte, pas sur l'impression. Sans cela, l'ingestion des éditions réclamerait 130 000 téléchargements d'images et quintuplerait l'index que l'application télécharge — pour peu de gain, une carte rééditée gardant le plus souvent son illustration. Le départage privilégie l'anglais puis la sortie la plus ancienne, jamais le prix : un critère fondé sur la cote désignerait une impression différente au gré des fluctuations et ferait recalculer des empreintes déjà connues.

(Indexer *toutes* les illustrations reconnaîtrait les rééditions à l'art changé — piste réelle, non prise ici, qui se paierait en poids d'index côté application.)

---

## 5. Recherche de cartes

Le champ de saisie de collection interroge la fonction `search_cards(q, max_results)`
via l'API REST, avec la clé publique — la recherche ne demande aucune authentification.
Elle existe parce que l'opérateur de similarité trigram n'est pas exposable directement
à un client : sans elle, la saisie échouerait sur la moindre faute de frappe.

Barème de classement, du plus fort au plus faible : égalité stricte, puis correspondance
sur un mot entier, puis fragment initial, puis proximité trigram. Les deux premiers
paliers sont ce qui fait remonter « Sol Ring » avant « Soliton » quand on tape « sol ».

**Performance mesurée** : 64 ms de médiane depuis un client, dont 45 ms de latence
réseau vers la région Londres. Le premier appel après une période d'inactivité coûte
plusieurs centaines de millisecondes — c'est un démarrage à froid, pas la requête.

Un index de préfixe (`text_pattern_ops`) a été essayé puis **retiré** : il n'apportait
aucun gain. Le motif de recherche provient d'un sous-select, il est donc inconnu au
moment de la planification, et aucun index de préfixe ne peut être mobilisé. Inutile de
retenter.

## 6. Moteur de suggestion

Matching contre des decklists réelles, pas de génération algorithmique.

Pour chaque deck du corpus, dans le format demandé :
1. Intersection avec la collection de l'utilisateur, en respectant les règles du format — singleton et identité couleur en Commander, 4 exemplaires maximum et liste de bannissements en Modern. **Scryfall fournit les légalités et l'identité couleur** ; aucune liste de bannissements n'est maintenue à la main.
2. Calcul du taux de complétion et de la liste des cartes manquantes.
3. Valorisation du reste manquant au prix de l'impression la moins chère.
4. Classement : constructibles immédiatement, puis par coût de complétion croissant.

À l'échelle visée (2 000 cartes × quelques milliers de decks), ce calcul est trivial. **Aucune contrainte de performance ne pèse sur la conception.**

### Justesse du décompte — vérifiée par recalcul

« Il te manque 3 cartes pour 4,20 € » engage l'argent de l'utilisateur : ce
chiffre doit être juste, et le regarder à l'écran ne prouve rien faute de savoir
ce qu'il *devrait* afficher. `api/app/measure/deck_math.py` construit une
collection dont il connaît le contenu, interroge `deck_suggestions` **comme le
fait l'application** — en REST, authentifié, pour que `auth.uid()` soit celui du
compte — puis recompte de son côté depuis `deck_cards` et `collection_items`.
Deux chemins indépendants vers le même nombre.

**Résultat : aucun écart sur 100 decks Pauper**, ni sur le nombre de cartes
possédées, ni sur les manquantes, ni sur le coût. La collection est volontairement
*partielle* — 60 % des exemplaires de chaque carte — parce que posséder tout ou
rien court-circuiterait le calcul `needed - owned`, précisément là où un moteur
de complétion se trompe.

Deux garanties tiennent ce script : il ne supprime que les lignes qu'il a
lui-même créées (le compte de test porte de vraies cartes), et sa capacité à
détecter une erreur a été vérifiée en faussant volontairement le recalcul. Sa
limite : `deck_suggestions` plafonne à 100 résultats, donc 100 decks confrontés
par exécution.

---

## 7. Parcours de livraison

| Jalon | Contenu |
|---|---|
| **1** | Collection par saisie texte avec autocomplétion, valorisation, matching et suggestions — **en Pauper**. Boucle de valeur complète, sans vision. |
| **1b** | Extension à Commander (précons MTGJSON) et Modern. Le moteur ne change pas : seules les légalités diffèrent, et Scryfall les fournit. |
| **2** | Reconnaissance d'une carte à la fois : photo et caméra. |
| **3** | Étalement multi-cartes. |
| **4** | Saisie vocale, feuilletage temps réel. |

Le jalon 1 prouve la valeur du produit avant tout investissement dans la vision, qui concentre le risque et la charge de travail.
