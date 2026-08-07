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
