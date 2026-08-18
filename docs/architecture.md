# Architecture — DeckHand

Annexe technique du [`CLAUDE.md`](../CLAUDE.md), et **index des annexes**. Décrit
le pipeline de reconnaissance, le modèle de données, les connecteurs de sources
et le moteur de suggestion.

| Annexe | Ce qu'elle couvre |
|---|---|
| [`collection-architecture.md`](./collection-architecture.md) | Classeurs, journal des mouvements, lecture publique et hébergement |
| [`multi-game.md`](./multi-game.md) | Ce que chaque jeu autre que Magic a demandé : catalogues, prix, corpus de decks, gabarits |
| [`spread-detection.md`](./spread-detection.md) | Détection multi-cartes sur une photo, et les impasses mesurées |

---

## 0. Où vit quoi

```
┌──────────────────────────────── app/ (Flutter) ────────────────────────────────┐
│  features/…/presentation   écrans, gestes, mise en forme                        │
│  features/…/data           dépôts : un point de passage par domaine vers la base│
│  features/…/domain         types purs, testables sans réseau ni Flutter          │
│  common/ · config/         images en cache, délais de requête, jeu sélectionné   │
└────────────────────────────────────────┬───────────────────────────────────────┘
                                         │  PostgREST (RPC) + Auth
┌────────────────────────────────────────▼───────────────────────────────────────┐
│                        Supabase — Postgres · Auth · Storage                     │
│  fonctions SQL : search_cards · my_collection_* · my_binder_* · deck_suggestions │
│  RLS : chaque lecture est bornée par une politique, jamais par l'appelant        │
└────────────────────────────────────────▲───────────────────────────────────────┘
                                         │  écritures d'ingestion (rôle propriétaire)
┌────────────────────────────────────────┴───────────────────────────────────────┐
│  api/ (Python, jobs à la demande — pas un serveur)                              │
│  ingestion/  un connecteur isolé par source        vision/   empreintes          │
│  measure/    bancs de mesure : rien ne se règle à vue                            │
└─────────────────────────────────────────────────────────────────────────────────┘
        ▲
        │  Scryfall · TopDeck.gg · MTGJSON · Riftcodex · TCGCSV · BCE
```

**Le calcul vit dans la base.** Confronter une collection à des centaines de
decklists est une jointure, pas un travail de client. L'application appelle des
fonctions ; elle ne rapatrie jamais le corpus pour le comparer localement.

**Ce qui traverse toutes les couches** :

| Élément | Rôle |
|---|---|
| `config/selected_game.dart` | Un seul jeu à la fois, retenu d'une session à l'autre, propagé jusqu'aux appels |
| `config/request_timeout.dart` | Aucune requête n'attend sans fin ; distingue l'injoignable du muet |
| `common/card_image.dart` | Un seul point de passage pour toute image de carte : cache disque, vignette d'abord |
| `common/state_message.dart` | Panne, vide, chargement : la même forme partout, avec un bouton Réessayer |

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

**Les autres jeux ont les leurs**, mesurés de la même façon et cloisonnés par
`CardFrame.game` — essayer le cadre d'un autre jeu coûterait deux fois, le calcul
et le risque de correspondance fortuite. Le détail de chaque mesure est dans
[`multi-game.md`](./multi-game.md) ; en bref :

| Jeu | Cadre | gauche | haut | droite | bas |
|---|---|---|---|---|---|
| Riftbound | vertical | 0,065 | 0,047 | 0,934 | 0,517 |
| Riftbound | couché (64 champs de bataille) | 0,041 | 0,199 | 0,962 | 0,777 |
| Yu-Gi-Oh | ordinaire | 0,1181 | 0,1823 | 0,8807 | 0,7055 |
| Yu-Gi-Oh | Pendulum (390 cartes) | 0,0615 | 0,1789 | 0,9360 | 0,6238 |

Yu-Gi-Oh se mesure comme Magic — par recoupement, la source publiant carte
entière et illustration détourée — et le résultat est plus net encore : la même
fenêtre à 0,001 près sur vingt cartes de dix familles de cadre. Riftbound, dont
la source ne publie aucun recadrage, a demandé trois méthodes dont deux ont
échoué.

**La parité de ces gabarits avec le Python est verrouillée mécaniquement** :
`api/tests/test_art_box.py` relit `art_box.dart` et compare les deux jeux de
valeurs, plutôt que d'en garder une copie qui divergerait avec ce qu'elle
surveille.

#### L'orientation est une hypothèse, au même titre que le cadre

Un cadre couché cherché dans un quadrilatère **droit** est lu tourné, dans les
deux sens — jamais tel quel. Une carte couchée glissée dans une pochette
verticale se laisse en effet détecter comme une carte debout : ce sont les bords
de la pochette que la détection trouve, et son rapport est celui d'une carte
(0,727 mesuré, pour 0,716 attendu). Le gabarit couché s'appliquait alors à une
zone parcourue de travers.

Mesuré sur du carton — un champ de bataille photographié sous pochette :

| | Rang de la bonne carte | Distance | Verdict |
|---|---|---|---|
| Sans rotation | 492 / 1 035 | 32 bits | rejetée |
| Quart de tour, mauvais sens | 197 / 1 035 | 26 bits | rejetée |
| **Quart de tour, bon sens** | **1 / 1 035** | **8 bits**, marge 9 | **annoncée avec assurance** |

Les deux sens sont donc essayés : une empreinte ne survit pas au demi-tour, et
rien dans la photo ne dit de quel côté la carte a été glissée.

**La réciproque n'est pas faite, et c'est un choix mesuré.** Un cadre droit
cherché dans un quadrilatère couché reste lu tel quel. Une carte debout ne se
présente pas couchée : un quadrilatère couché autour d'une carte debout signifie
que la détection s'est trompée, et on n'échafaude pas d'hypothèse sur une
détection fausse. Essayée, cette réciproque annonçait « Mirror Image » à 12 bits
avec la marge requise sur une photo au masque faux — une carte inventée, sur le
seul résultat que ce pipeline protège.

Le prix est **un tirage de plus** dans l'index pour toute carte droite d'un jeu
qui a des cartes couchées (trois hypothèses au lieu de deux, Riftbound seul
concerné). Mesuré sur les quatorze reconnaissances du lot carton : aucun faux
positif introduit, une carte gagnée, et un classement dégradé sur une carte déjà
rejetée — la bonne carte y perd sa place en tête sans changer de verdict.

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

**La leçon du redimensionnement n'avait pas franchi la porte d'à côté.** Elle
était appliquée à l'empreinte, jamais à la réduction qui amène la photo à la
taille d'analyse de la détection de bords : celle-ci interpolait entre les quatre
voisins immédiats côté Dart, quand Pillow, côté Python, élargit le support de son
filtre à mesure que le facteur grandit. À faible facteur les deux coïncident ; à
partir de **3**, le Dart sous-échantillonne — une texture fine ne s'éteint pas,
elle replie en un bruit à l'échelle du pixel d'analyse, que le seuillage local
lit comme du carton. Sur une carte photographiée sur un tissu, le Dart tenait
**82,5 % de l'image** pour du carton et rendait un quadrilatère couvrant 81 % de
l'aire, là où le Python rendait la carte. Les deux réduisent désormais par le
même filtre de moyenne à bornes entières, et les coins coïncident au pixel près.

**Rien ne pouvait le signaler, et c'est la vraie leçon.** Les tests unitaires
travaillent sur des figures de 300 px, sous la taille d'analyse : elles ne sont
jamais réduites. Le banc de cadrage compose des photos de 650 à 1100 px, soit des
facteurs de 1,6 à **2,7** — il s'arrête un cran avant le défaut. Une photo de
téléphone, elle, se réduit d'un facteur 10. Ce qui a révélé la panne est d'avoir
joué **la même photo** dans les deux implémentations et comparé les coins ; c'est
le seul contrôle qui l'aurait vue, et il ne coûte rien.

### Bâtir l'index sans télécharger une image

`index_builder` télécharge chaque illustration. **Une source peut le refuser**, et
Wankul le fait : son CDN rend `403 Hotlinking not allowed` sans `Referer`, avec
un `Referer` étranger, et jusqu'avec celui de son propre site. Ce n'est pas un
en-tête à contourner mais une politique, et le garde-fou §IV.10 interdit de la
forcer.

`app.vision.local_index` est la seconde voie : il lit un dossier de rendus déjà
présents sur le disque, calcule les empreintes et écrit les mêmes lignes.
**Aucun pas de la chaîne de calcul n'y est réimplémenté** — `box_for`, `crop` et
`dhash` sont ceux du constructeur ordinaire — sans quoi les empreintes locales et
téléchargées ne se compareraient plus, alors qu'elles cohabitent dans la même
table.

Ce qu'un dossier a de plus qu'un téléchargement, et qu'il faut traiter :

- des **calques qui ne sont pas des illustrations** (masques holographiques :
  308 fichiers sur 1 268 chez Wankul). Ce sont des images valides — un masque
  s'ouvre, se hache, et produit une entrée d'index fausse dont rien ne dit
  qu'elle l'est. Le filtre porte sur le suffixe de nom, pas sur l'extension ;
- des **marges transparentes** possibles, qui fausseraient les proportions de la
  valeur exacte de la marge ;
- une **orientation de stockage** propre à la source : un Terrain Wankul est une
  carte couchée dont le rendu principal la montre debout, tournée d'un quart de
  tour. Tout ce qui est propre à une source vit dans une seule fonction
  (`local_index.refine`), qui redresse l'image et précise sa maquette avant que
  `box_for` ne choisisse la fenêtre.

Le lien fichier ↔ impression passe par `card_prints.illustration_id`, et **non**
par `art_crop_url` : cette dernière porte l'URL d'affichage, qui n'est pas
toujours celle du rendu que le dossier contient. Détail et chiffres :
[`multi-game.md` §9](./multi-game.md#9-wankul--un-catalogue-sans-prix-sans-decks-et-sans-images).

### Le dépôt d'images — une exception, et une seule

Le catalogue ne stocke qu'une **adresse** par impression, jamais l'image : c'est
ce qui permet de couvrir 165 000 impressions Magic sans rien héberger, et c'est
la contrepartie de l'usage gratuit qu'on fait de Scryfall (§IV.3).

Wankul est la seule exception. Son CDN refuse de servir ses images à qui que ce
soit, et l'accord nominatif de son éditeur couvre l'hébergement au même titre que
la collecte. Les rendus sont donc versés dans le bucket **`card-art`**, créé par
migration, public en lecture, et rangés sous un **préfixe de jeu** : ce bucket
n'est pas un cache où l'on déverserait les autres sources au premier ennui de
réseau, et le préfixe est là pour que la question se pose à chaque fois.

Le chemin imite celui de Scryfall — `/normal/<id>.jpg` et `/small/<id>.jpg` —
parce que l'application sait déjà passer de l'un à l'autre pour afficher une
vignette légère avant la grande. Ce choix a évité d'ajouter un cas particulier
dans `scryfall_image.dart`, que les cinq jeux partagent.

L'URL est **dérivée d'`illustration_id`**, donc recalculée à chaque ingestion
sans rien demander au bucket. Le point délicat est là : une URL relevée plutôt
que dérivée aurait été réécrite par la course suivante vers le CDN bloqué, et le
classeur serait redevenu muet sans qu'aucune erreur ne le dise.

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

### Ce que l'index annonce quand il ne devrait rien dire — quatre jeux, 83 452 empreintes

#### Deux axes d'identité, et le chiffre se lit de travers si on les confond

**Le même banc a rendu 7,36 % pour Pokémon et 1,51 % pour Magic, et la différence n'était pas dans la reconnaissance.** Elle était dans le mot « carte ». Chez Magic, `art_hashes.oracle_id` porte l'identité *oracle* : elle réunit toutes les éditions, si bien que deux tirages de la même carte qui se ressemblent ne comptent pas comme une confusion. Chez Pokémon, l'identité publiée par TCGdex est l'**impression** — chaque réédition est une carte distincte, et l'`illustration_id` est dérivé de sa clé. Deux tirages de la même illustration y sont donc hachés séparément, et leur ressemblance était comptée comme une fausse carte.

Vérifié plutôt que supposé : sur les **247 groupes d'empreintes identiques** de l'index Pokémon (503 cartes), **99,2 % portent le même nom**. Les deux seules exceptions apparentes sont *Professor Elm's Training Method* et *Professor Elm’s Training Method* — la même carte, avec deux apostrophes différentes chez la source.

Le banc compte désormais les deux axes, et seul le second est comparable d'un jeu à l'autre :

| Jeu | annoncées à tort, par carte | **par nom** |
|---|---|---|
| Magic | 1,51 % | **1,54 %** |
| Pokémon | 7,36 % | **1,49 %** |
| Riftbound | 1,76 % | **1,76 %** |
| Yu-Gi-Oh | 1,32 % | **1,32 %** |

Les quatre jeux tiennent dans la bande 1,3–1,8 %. Et se tromper d'édition n'est pas annoncer une autre carte : le garde-fou §IV.8 le prévoit déjà — la carte se confirme, l'édition se déduit quand rien ne reste à choisir.

La mesure ci-dessus interroge l'index avec des cartes **qui s'y trouvent**. Elle
ne dit donc rien du cas que l'utilisateur rencontrera pourtant : une carte
**absente** — un jeton, une carte abîmée, une carte hors catalogue, ou
simplement une carte d'un autre jeu photographiée sans avoir changé de
sélecteur. Toute réponse y est fausse par construction, et la seule bonne
conduite est le silence. `api/app/measure/art_collisions.py` mesure ce que les
deux garde-fous laissent passer.

**La densité s'est aggravée comme annoncé.** L'index Magic est passé de 31 634 à
49 067 empreintes, et la part des cartes ayant une **autre carte** sous le seuil
de 12 bits a doublé — de 18,7 % à 36,4 %.

| Jeu | Empreintes | Une autre carte sous le seuil | Annoncée à tort **avec assurance** |
|---|---|---|---|
| Magic | 49 067 | 17 850 (36,4 %) | **740 (1,51 %)** |
| Yu-Gi-Oh | 13 866 | 1 790 (12,9 %) | **183 (1,32 %)** |
| Riftbound | 1 193 | 117 (9,8 %) | **75 (6,29 %)** |

**La marge de confiance encaisse le choc.** Un tiers du catalogue Magic est
confondable, mais 1,5 % seulement franchit les deux garde-fous : quand deux
cartes sont serrées, la marge chute et le système hésite au lieu d'affirmer.
C'est le design qui tient, pas la chance.

**Riftbound faisait exception, et ce n'était pas la reconnaissance qui était en
cause.** Ses 6,29 % venaient de cartes **enregistrées deux fois** par le
catalogue, sous deux orthographes du nom ou deux rédactions du texte de règles —
« Ambessa - Matriarch of War » et « Matriarch of War », « Lux - Crownguard » et
« Lux, Crownguard ». Aucune empreinte ne peut départager ce qu'un catalogue a
dédoublé : la limite était en amont, dans l'identité dérivée par
`riftcodex_ingest`. Elle l'est toujours, mais le dédoublement est corrigé — 87
identités en réunissaient 192, et le catalogue est passé de 1 035 à 929 cartes.
Voir [`multi-game.md`](./multi-game.md), « Une identité ne se dérive pas d'un
champ d'affichage ».

**Les intrusions**, mesurées en interrogeant l'index d'un jeu avec les empreintes
d'un autre — toutes absentes, donc toute réponse est fausse :

| Empreintes | Index interrogé | Sous le seuil | **Annoncées avec assurance** | Plus proche |
|---|---|---|---|---|
| Riftbound | Magic | 379 / 1 193 | 16 (1,34 %) | 5 bits |
| Yu-Gi-Oh | Magic | 774 / 3 000 | 29 (0,97 %) | 2 bits |
| Magic | Yu-Gi-Oh | 471 / 3 000 | 46 (1,53 %) | 3 bits |
| Riftbound | Yu-Gi-Oh | 114 / 1 193 | 17 (1,42 %) | 6 bits |
| Magic | Riftbound | 85 / 3 000 | 22 (0,73 %) | 7 bits |
| Yu-Gi-Oh | Riftbound | 59 / 3 000 | 12 (0,40 %) | 8 bits |

**Environ une carte étrangère sur cent est annoncée avec assurance**, et la plus
proche descend à 2 bits — soit moins que le bruit d'un décodeur JPEG. Le
cloisonnement de l'index par jeu, décidé sur les 379 empreintes de la première
ligne, supprime le mélange des catalogues mais **pas le choix du mauvais jeu par
l'utilisateur** : celui-là reste à sa main. C'est le prix connu de la
reconnaissance par empreinte seule, et il se paie en confirmations demandées, non
en refonte.

Le banc est à rejouer à chaque nouveau jeu : la densité ne se devine pas, elle se
mesure — et elle empire à mesure que le catalogue grossit.

### Le coût d'une image, mesuré sur l'appareil

Mesuré sur le téléphone de test, 1280 × 720, index de 32 000 entrées, 60 images
après rodage (`--dart-define=DECKHAND_BENCH=true`, résultat dans
`adb logcat | grep DHDIAG`). Un banc jumeau tourne au poste de travail
(`app/tool/frame_bench.dart`) : il ne donne pas les mêmes durées — cœur plus
rapide, JIT contre AOT — mais les mêmes rapports.

| Étape | p50 | p90 |
|---|---|---|
| **Lecture + empreinte, chemin direct** | **0,70 ms** | 0,78 ms |
| Lecture seule via `img.Image` | 2,75 ms | 3,67 ms |
| Empreinte depuis un `img.Image` | 12,45 ms | 14,89 ms |
| Conversion RGB de la fenêtre | 6,85 ms | 6,97 ms |
| Conversion RGB de l'image entière | 18,84 ms | 19,15 ms |
| Recherche dans l'index | 1,03 ms | 1,08 ms |
| **Total capteur → identifiant** | **1,73 ms** | — |

**Une image coûte 1,7 ms. Le temps réel n'a donc pas de problème de budget** —
c'était la question qui pouvait condamner l'approche, et elle est tranchée.

Trois décisions y mènent, chacune mesurée :

**La conversion YUV→RGB n'a pas lieu d'être.** Le plan `Y` d'une image de caméra
*est* la luminance, et `computeArtHash` commence par y ramener chaque pixel. Sur
une image dont les trois canaux valent `Y`, son calcul rend exactement `Y` :
`(Y·299 + Y·587 + Y·114) ÷ 1000 = Y`.

**Découper avant de convertir change l'ordre de grandeur.** L'empreinte ne porte
que sur l'illustration ; lire ses seuls octets rend le coût proportionnel à
elle. Convertir toute l'image d'abord coûte 11 fois plus cher pour jeter ensuite
les deux tiers des pixels.

#### Le flux libre coûte vingt fois le flux à caméra fixe

Les chiffres ci-dessus décrivent le mode à **caméra fixe** : la fenêtre
d'illustration est découpée à une position convenue, donc la carte est supposée
toujours au même endroit. Un flux **libre**, où l'on promène l'appareil, doit
d'abord la retrouver. Mesuré sur le même téléphone, cinq tirages à froid
cohérents à 3 % près :

| Poste | 1280 × 720 | 720 × 480 |
|---|---|---|
| Matérialiser l'image entière | 10,4 ms | **3,9 ms** |
| **Détection des bords (`findCard`)** | **26,9 ms** | **29,8 ms** |
| Empreinte depuis l'`img.Image` découpé | 13,1 ms | 4,9 ms |
| Recherche | 1,5 ms | 1,5 ms |
| **Total capteur → identifiant** | **52 ms** | **40 ms** |
| Rappel : caméra fixe | 2,5 ms | 1,9 ms |

**Le flux libre ne tient pas dans les 33 ms d'un flux à 30 images par seconde.**
Il en tient 19, et 25 à résolution réduite.

**Baisser la résolution ne sauve pas la détection**, et c'est le résultat qui
oriente la suite. Diviser l'aire du capteur par 2,7 divise bien tout ce qui lit
les pixels source — l'image entière passe de 10,4 à 3,9 ms —, mais `findCard` ne
bouge pas. Son coût n'est donc pas dans la lecture de l'entrée : il est payé à la
**taille d'analyse**, fixe à 400 px de large, où le masque, le bouchage des trous
et la recherche de composantes parcourent chacun les mêmes 90 000 pixels quelle
que soit la photo d'origine.

Trente millisecondes pour 90 000 pixels font 330 ns par pixel, ce qui est
beaucoup.

**Une piste suivie, et son rendement mesuré.** Le masque et la forme retenue
étaient des `List<bool>` — un tableau de pointeurs vers les deux objets
canoniques `true` et `false`, donc huit octets et un déréférencement par pixel —
quand tous les autres tampons du même fichier étaient déjà typés. Passés en
`Uint8List`, à comportement rigoureusement identique (coins inchangés au pixel
près sur les trois photos de papier, parité Python intacte) :

| | `findCard`, appareil | poste de travail, 720p |
|---|---|---|
| `List<bool>` | 27,2 ms | 9,8 ms |
| **`Uint8List`** | **23,0 ms** | **9,2 ms** |

**−15 % sur l'appareil**, mesuré en alternant les deux APK sur trois tours de
deux tirages — les six mesures de référence tiennent dans 0,9 ms, ce qui valide
le protocole. Le gain est réel mais **ne change pas le verdict** : le flux libre
passe de 52,3 à 51,2 ms, toujours loin des 33 ms.

Un effet secondaire est resté inexpliqué : dans les exécutions au masque typé,
`computeArtHash` — que le changement ne touche pas — mesure 16,0 ms au lieu de
13,1, de façon reproductible sur les trois tours. L'explication la plus
plausible, non vérifiée, est que le banc s'auto-échauffe : une détection plus
rapide lui fait traiter plus d'images par seconde. Le chemin réellement employé
à caméra fixe, `artHashFromLuma`, ne bouge pas (0,98 ms dans les deux).

**Le vrai levier était de ne pas construire l'image.** `findCard` réclame un
`img.Image` ; une image de caméra n'en est pas un, et la bâtir coûte une écriture
de trois canaux par pixel pour un plan qui en porte déjà un seul, le bon.
`findCardInLuma` descend jusqu'à la taille d'analyse sans jamais matérialiser
l'image entière — le trajet qu'`artHashFromLuma` avait déjà emprunté pour
l'empreinte, où il faisait passer 12,4 ms à 0,7.

Mesuré **dans la même exécution**, les deux chemins côte à côte sur quatre
tirages, ce qui met l'échauffement hors de cause :

| | p50 |
|---|---|
| Image entière (10,3 ms) puis `findCard` (24,2 ms) | 34,5 ms |
| **`findCardInLuma`** | **23,0 ms** |
| Total capteur → identifiant | **52 → 40 ms** |

**Le flux libre passe de 19 à 25 images par seconde.** Les deux chemins
concluent identiquement — **60 quadrilatères sur 60**, à chaque tirage, sur des
images réelles et pas seulement sur la figure de test. C'est ce que garantit le
partage du corps de la détection : seule la mise à la taille d'analyse diffère,
et ses bornes sont les mêmes des deux côtés.

**Le même raccourci une fois de plus, et le budget est tenu.** L'empreinte
passait encore par un `img.Image` : `sampleArt` lit dans une image, donc il
fallait la bâtir — ce que la détection venait justement d'éviter.
`sampleArtFromLuma` échantillonne le quadrilatère directement dans le plan et
rend un tampon serré, qu'`artHashFromLuma` hache sans rien reconstruire.
L'empreinte est identique **bit à bit** aux deux chemins, ce qu'un test vérifie.

Chronométrée d'un bloc — détecter, découper l'illustration dans le
quadrilatère, hacher, chercher dans un index de 32 000 :

| | p50 | p90 |
|---|---|---|
| `findCardInLuma` seul | 22,9 ms | — |
| **Chaîne entière du flux libre** | **27,4 ms** | 29 à 34 ms |

**Le flux libre tient dans les 33 ms.** Il était à 52 ms avant ces trois
corrections ; 30 images par seconde est atteint au p50, et le p90 affleure le
budget.

Deux réserves, plutôt que de les taire. La chaîne n'est chronométrée que sur les
images où la détection trouve une carte — 43 images sur les quatre exécutions —,
donc sa médiane repose sur un échantillon plus mince que les autres postes. Et
les totaux notés plus haut, qui additionnent des postes mesurés séparément,
**surestiment** le flux libre : ils y comptent un hachage pris sur la fenêtre
fixe, 333 000 pixels, quand le quadrilatère n'en fait échantillonner que 48 640.

Restait alors un choix de conception, et non de performance : détecter à
chaque image, ou suivre le quadrilatère entre deux détections. Il est
tranché ci-dessous, et la mesure a renversé deux attentes.

**Deux goulots trouvés là où on ne les attendait pas.** La recherche linéaire
coûtait 8,4 ms sur l'appareil — non à cause du parcours, mais parce qu'elle
construisait trente-deux mille enregistrements pour les trier et en garder cinq.
Une sélection partielle à tampon fixe la ramène à **1,0 ms**. Puis l'empreinte
est devenue dominante à 12,4 ms — non à cause de son arithmétique, mais du
trajet : construire un `img.Image`, y écrire trois canaux par pixel, les relire
un par un. `artHashFromLuma` lit les octets là où ils sont et refait le **même
calcul**, ce qu'un test vérifie bit à bit contre `computeArtHash` ; 12,4 ms
deviennent 0,7 ms, lecture comprise. Le mode photo profite du premier gain
autant que le temps réel.

**Ce que la conversion RGB perd, et que le raccourci ne perd pas.** Sur des
triplets `(Y, U, V)` tirés au hasard, le passage en RGB puis le retour à la
luminance rend `Y` à une unité près — mais **écrête 77 % des pixels**, et
l'écart moyen monte alors à 14 valeurs, jusqu'à 78. Sur l'appareil, les deux
chemins s'écartent en conséquence de 3 bits en médiane et jusqu'à 14. Ce n'est
pas une erreur du raccourci : c'est celle du détour, dont la reconstruction
sature dès que la scène est colorée. Lire `Y` est exact ; le convertir ne l'est
pas.

**Ce qui reste à prouver, et que seule une carte de papier prouvera.** Ces
chiffres disent que l'empreinte du flux est celle qu'on croit *par rapport au
code du mode photo*. Ils ne disent pas qu'elle rencontre la bonne entrée de
l'index — le `Y` d'un capteur est en plage vidéo (16–235) là où l'index est
calculé sur du RGB pleine plage. Le passage est affine et croissant, donc il
préserve les comparaisons de voisins dont l'empreinte est faite ; vérifié en
test de synthèse, il reste à l'éprouver devant un booster réel, comme le
demande l'issue #8.

#### Suivre le quadrilatère plutôt que le refaire — et pourquoi il faut deux garde-fous

Le budget étant tenu, la question qui restait n'était plus une affaire de
performance : *une carte posée ne bouge pas de 33 ms en 33 ms*, faut-il pour
autant la redétecter à chaque image ? Mesuré par `app/tool/stream_bench.dart`,
qui compose une séquence — carte posée, échangée sur place, qui dérive, retirée
— et y rejoue onze stratégies.

**Le premier résultat n'était pas celui qu'on cherchait.** Sur une carte
immobile, l'empreinte bouge quand même, et pas pour la raison qu'on croit :

| Sur une carte immobile | écart d'une image à la suivante |
|---|---|
| quadrilatère redétecté à chaque image | médiane 0, **max 11 bits** |
| quadrilatère tenu (bruit du capteur seul) | médiane 0, **max 2 bits** |

C'est **la détection elle-même qui tremble**. Redétecter à chaque image ne
garantit donc pas la stabilité, elle la dégrade : le quadrilatère se replace
légèrement ailleurs, et l'empreinte suit. Tenir le quadrilatère n'est pas
seulement moins cher, c'est plus fidèle.

**Le fossé qui rend un seuil possible.** Ce qui fait bouger une empreinte à
quadrilatère tenu se compte en unités ; ce qui se produit quand la carte change
se compte en dizaines :

| Événement | écart médian | max |
|---|---|---|
| carte immobile | 0 | 2 bits |
| dérive, d'une image à la suivante | 1 | 4 bits |
| **échange de carte** | **35** | 44 bits |

Le plancher ne bouge pas avec le bruit du capteur — de ±1 à ±12 niveaux de gris,
il reste à 1 ou 2 bits, la grille d'empreinte moyennant de larges cellules. Un
seuil de saut peut donc se poser n'importe où dans un fossé large de trente
bits.

**Et pourtant un seuil de saut ne suffit pas.** L'échange, qu'on croyait le cas
dangereux, est vu **immédiatement** par toutes les stratégies — y compris celles
qui ne redétectent jamais. La raison est que la géométrie, elle, n'a pas changé :
l'empreinte prise à travers l'ancien quadrilatère est déjà celle de la nouvelle
carte, et l'index la reconnaît sans qu'aucune détection n'ait eu lieu.

Le vrai danger est la **dérive**, et il est structurel. Chaque image ne s'écarte
de la précédente que de 1 à 4 bits — jamais assez pour franchir un seuil — mais
les écarts s'accumulent : après une douzaine d'images, le quadrilatère tenu rend
une empreinte à **35 bits** de ce qu'une détection fraîche aurait donné. Aucun
seuil de saut, si bas soit-il, ne peut voir cela. D'où le second garde-fou, qui
n'est pas une précaution mais l'autre moitié de la règle : un **âge maximal**.

**Ce que la dérive coûte est un silence, pas une erreur.** Sur onze stratégies et
deux régimes de prise de vue, **aucune n'annonce jamais une carte fausse** : une
empreinte trop éloignée ne ressemble plus à rien, et l'index se tait — le
comportement voulu. Le réglage arbitre donc entre du calcul et des cartes
manquées, jamais entre du calcul et des cartes inventées.

| Stratégie | détections / 156 | coût par image | dérive max | reconnaissances perdues | annoncées à tort |
|---|---|---|---|---|---|
| détecter à chaque image | 156 | 27,4 ms | — | 0 | 0 |
| période 5 | 40 | 10,4 ms | 14 bits | 7 | 0 |
| période 15 | 16 | 6,8 ms | 29 bits | 22 | 0 |
| saut 12 seul | 31 | 9,1 ms | 35 bits | 25 | 0 |
| saut 2 seul | 67 | 14,3 ms | 8 bits | 0 | 0 |
| **saut 12 + âge 5** | **53** | **12,3 ms** | 13 bits | 3 | 0 |

Le coût par image est **composé**, non chronométré : le banc tourne sur un poste
de travail, dont les durées ne transfèrent pas. Ce qu'il mesure honnêtement est
le *nombre* de détections ; les 22,9 ms d'une détection et les 4,5 ms du reste
viennent de l'appareil.

**Le suivi rattrape aussi ce que la détection perd.** Sous un éclairage latéral
marqué — le régime qui met la détection en difficulté —, les stratégies de suivi
annoncent **17 cartes justes que la détection à chaque image ne trouve pas** :
un quadrilatère déjà établi continue de servir là où une nouvelle détection
échoue. L'argument en faveur du suivi n'est donc pas seulement le coût.

**La politique est dans `quad_tracker.dart`**, avec ses deux seuils, et le banc
mesure ce module plutôt qu'une réplique — mesurer une copie reviendrait à
chronométrer un code que personne n'exécutera, et à laisser les deux diverger en
silence.

**Le suivi tourne sur le flux réel**, dans le banc embarqué
(`--dart-define=DECKHAND_BENCH=true`), et dans la **même exécution** que la
chaîne qui redétecte tout : c'est la seule façon de les comparer sans que
l'échauffement de l'appareil s'en mêle. Le banc y exécute `QuadTracker` lui-même
plutôt qu'une réplique, et journalise `suivi_us` avec le nombre de détections
réellement déclenchées — ce qui remplacera le coût *composé* de 12,3 ms par un
coût mesuré. Aucun mode temps réel n'est écrit autour pour autant : l'app n'a
pas encore de chemin caméra en flux hors de ce banc.

**Ce que la mesure ne donne toujours pas.** Les valeurs par défaut — 12 bits et
5 images — sont tirées de séquences composées : elles disent qu'une fenêtre de
réglage existe et qu'elle est large, pas où se place l'optimum d'un vrai
capteur. Le booster réel que l'issue #8 réclame reste le seul juge.

### Pourquoi hacher l'illustration et non la carte entière

L'illustration est **identique en français et en anglais** ; seul le cadre de texte change. En hachant l'art, le mélange linguistique de la collection devient un non-sujet. Hacher la carte entière produirait deux empreintes distinctes pour la même carte.

### Limites structurelles connues

| Limite | Nature | Conséquence |
|---|---|---|
| Rééditions partageant la même illustration | Indiscernables par empreinte seule | L'édition se choisit à la main dans le sélecteur, la reconnaissance n'ayant pas à trancher. Valorisation par défaut tant qu'elle n'est pas précisée : impression la moins chère. |
| Cartes full-art, borderless, showcase | Géométrie non standard | Le découpage à position fixe échoue. Nécessite une détection de gabarit ou une empreinte de secours sur la carte entière. |
| Cartes empilées | Optique, non algorithmique | Seule la carte du dessus est visible. D'où les deux modes retenus : étalement et feuilletage. |
| Catalogue Riftbound anglais seulement | Contractuelle, non algorithmique | Une carte française n'est pas retrouvable par son nom, quel que soit le soin de la lecture. L'empreinte est la voie principale de ce jeu, et le mode étalement — qui ne lit que les noms — ne peut pas le servir. |
| Carte absente de l'index interrogé | Structurelle : tout point a un plus proche voisin | Environ **1 %** des cartes étrangères passent les deux garde-fous et sont annoncées avec assurance (mesuré, `art_collisions.py`). Le cloisonnement par jeu écarte le mélange des catalogues, pas le choix du mauvais jeu par l'utilisateur. |
| Masque de seuillage faux (fond clair, tissu) | Le quadrilatère englobe le décor | La tolérance d'aspect ne le rattrape pas, et c'est assumé — `aspectTolerance` est large pour encaisser la perspective. Mesuré sur carton : la carte reste introuvable, mais **aucune fausse carte n'est annoncée**, le meilleur candidat restant au-delà du seuil. |
| Un catalogue qui enregistre une carte deux fois | Catalogue, non algorithmique | Aucune empreinte ne peut départager ce qu'une source a dédoublé, et la collection compterait la carte deux fois. Rencontré sur Riftbound et **corrigé dans l'identité dérivée** par `riftcodex_ingest` — jamais dans la reconnaissance. La leçon vaut pour la prochaine source : une identité ne se dérive pas d'un champ d'affichage. |

### Ce qu'un échec doit dire

**Un message d'échec ne doit jamais affirmer une cause qu'il ne connaît pas.**
Trois causes se ressemblent à l'écran et appellent trois gestes opposés :

| Cause | Ce que l'utilisateur doit faire |
|---|---|
| Rien n'a pu être lu | Se rapprocher, éviter les reflets |
| Un nom a été lu, aucune carte ne le porte | Vérifier le jeu saisi ; en Riftbound, photographier la carte seule |
| Le catalogue n'a pas répondu | Vérifier la connexion — recadrer n'y changera rien |

Les trois se distinguent dans le **résultat de la reconnaissance**, pas dans
l'écran : `SpreadOutcome.readButUnmatched`, `ScanOutcome.readName` et
`ScanOutcome.catalogueUnreachable`. L'écran ne devine pas, il lit.

C'est une leçon payée deux fois. `recogniseSpread` a cessé d'avaler les pannes
réseau après qu'une coupure eut ressemblé trait pour trait à un étalement
illisible ; le scan à l'unité, lui, a gardé le défaut jusqu'à ce qu'une carte
Riftbound française se voie conseiller d'éviter les reflets sur ses
protège-cartes, alors que son nom venait d'être lu sans une faute.

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
| **YGOPRODeck** | Catalogue Yu-Gi-Oh — noms EN et FR, types, niveaux, attributs, impressions, illustrations | Public, sans clé, **catalogue entier en un appel** (21 Mo, 14 491 cartes) | **Pas de CGU publiées** ; le guide d'API fait foi et **demande** le stockage local (« please download and store all data locally »). Débit annoncé : 20 req/s — ce connecteur en fait deux en tout. Garde-fou §IV.9 : on lui applique les règles de Scryfall. Illustrations jamais réhébergées. |

### Ce qui protège une longue course

Une ingestion tient des minutes à des heures, et deux liens peuvent céder pendant : celui de la source, et celui de la base.

**Le lien HTTP** est gardé depuis le début : six tentatives, attente doublée (2, 4, 8, 16, 32 s), 404 terminal — insister ne fera pas apparaître une ressource absente. Un `Retry-After` est respecté mais borné à 120 s, une heure d'attente demandée par le serveur arrêtant l'import aussi sûrement qu'une exception.

**Le lien avec la base ne l'était pas**, et c'est lui qui a coûté le plus cher. Le 14 août à 00 h 10, Supabase a fermé les connexions ouvertes ; l'ingestion Pokémon en cours est morte à mi-fenêtre — vingt jours sur trente. Les vingt étaient acquis, les écritures commitées survivant à la coupure, mais la course était à refaire depuis le début : la pagination repart toujours du plus récent.

`app/db.py` répond à cela. `Session.run` joue une *unité de travail* ; si la connexion cède, elle est fermée, une neuve est ouverte, l'unité est rejouée. Trois propriétés font que cela marche, et aucune n'est facultative :

1. **L'unité est idempotente.** `store_deck` écrit en `ON CONFLICT DO UPDATE` : rejouer un tournoi remplace ses cartes au lieu de les dupliquer.
2. **L'unité commite ce qu'elle veut garder**, et la maille du commit est celle de la reprise — un tournoi. Commiter tous les dix, comme auparavant, ferait perdre neuf tournois à chaque coupure sans que la reprise puisse les retrouver.
3. **L'unité ne mute aucun compteur.** Elle *rend* ses totaux, que l'appelant additionne au retour. Un compteur incrémenté à l'intérieur compterait deux fois après un rejeu, et le rapport annoncerait des decks qui n'existent pas.

Le téléchargement reste **hors** de l'unité : une coupure de la base ne doit pas faire repayer des requêtes qui viennent d'aboutir. Un test le vérifie en refusant toute requête excédentaire.

Ce qui n'est **pas** rejoué est tout aussi délibéré : seules `OperationalError` et `InterfaceError` — « cette connexion n'existe plus » — déclenchent la reprise. Une `ProgrammingError` remonte au premier coup, sans quoi une faute de SQL serait répétée cinq fois puis maquillée en instabilité réseau.

Reste une imprécision assumée : le décompte des codes non résolus est cumulatif dans le résolveur, donc majoré des tournois rejoués. C'est un diagnostic et non une donnée du produit — le nombre de coupures est affiché à côté, pour qu'on sache le lire de travers.

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
| `profiles` | Préférences du compte — les jeux joués, dans leur ordre |
| `collections` / `collection_items` | Possessions, par utilisateur |
| `decks` / `deck_cards` | Corpus normalisé, toutes sources confondues |
| `deck_sources` | Provenance et mentions d'attribution |

**`deck_sources` porte l'attribution.** TopDeck.gg impose un crédit visible ; l'exigence doit voyager avec la donnée pour que l'interface ne puisse pas l'oublier.

### Le compte, et la route de retour du mot de passe

La confirmation par courriel est désactivée côté projet (`mailer_autoconfirm`) :
l'inscription ouvre immédiatement une session, choix assumé pour un cercle de
proches. **Ce choix rend la réinitialisation nécessaire plutôt que
confortable**, et trois manques se tenaient ensemble pour former une trappe :

| | |
|---|---|
| un mot de passe saisi **une seule fois**, à l'aveugle | une frappe de travers passe |
| une adresse que **rien ne vérifie** | une frappe de travers passe aussi |
| **aucune récupération** | et le compte est perdu, définitivement |

Ce que perd l'utilisateur n'est pas un accès : c'est une collection saisie carte
par carte, ce que ce produit demande des heures à constituer.

La route en place, calquée sur celle de DewDrop :

1. L'écran de connexion demande **deux fois** le mot de passe à l'inscription,
   une seule à la connexion — retaper un mot de passe qu'on connaît n'a pas
   besoin d'être confirmé. Un œil permet de relire ce qu'on tape : la
   confirmation seule ne rattrape que les fautes qu'on ne refait pas.
2. « Mot de passe oublié ? » demande l'adresse et déclenche
   `resetPasswordForEmail`. **La réponse ne dit jamais si un compte existe** —
   Supabase répond pareil dans les deux cas, et l'écran tient le même silence,
   sans quoi il deviendrait un test d'existence de compte ouvert à tous.
3. Le courriel porte un lien `deckhand://reset-password` qui **rouvre
   l'application**. Une adresse `https://` mènerait au navigateur, où la version
   hébergée ne sait rien faire d'un compte (`DECKHAND_PUBLIC_ONLY`).
4. `supabase_flutter` échange le code et ouvre une session temporaire, puis émet
   `AuthChangeEvent.passwordRecovery`.
5. `passwordRecoveryProvider` retient l'événement et l'aiguillage de `main.dart`
   affiche l'écran de nouveau mot de passe **avant** de regarder la session.

**Les points 4 et 5 sont les seuls non évidents.** Une session de récupération
est une session valide : rien ne la distingue d'une connexion ordinaire sinon
l'événement qui l'a créée, et sans ce détour l'application ouvrirait l'accueil,
le nouveau mot de passe n'étant jamais demandé. Le flux d'authentification ne
rejoue pas ce qui est passé, donc **l'abonnement doit précéder l'événement** :
c'est pourquoi l'aiguillage observe le drapeau dès son premier build. Un test
écrit dans l'autre ordre a échoué, et c'est ce qui a rendu la contrainte
visible.

### Les jeux joués, déclarés à l'inscription

Le sélecteur alignait les huit jeux dans l'ordre du code, le même pour tout le
monde. Quelqu'un qui ne joue qu'à Pokémon passait devant sept jeux qui ne le
concernent pas, à chaque fois qu'il ouvrait la page. `public.profiles` porte donc
la liste de ses jeux, **dans l'ordre où il les a cochés** — `games[1]` est celui
que l'application ouvre.

**Le compte, et non l'appareil.** Le jeu *courant* vit dans les préférences
locales (`selected_game.dart`) : il change plusieurs fois par séance et n'a
aucune raison de voyager. Les jeux *joués* sont une propriété de la personne, au
même titre que sa collection — ils suivent du téléphone au web et survivent à une
réinstallation.

**Trois états, pas deux.** C'est la **présence de la ligne** qui vaut réponse :

| En base | Sens | Écran |
|---|---|---|
| pas de ligne | la question n'a jamais été posée | l'étape de choix s'ouvre |
| `games = '{}'` | la question a été posée et passée | les huit jeux, à plat |
| `games = {...}` | voici mes jeux, dans cet ordre | les siens devant, les autres repliés |

Sans le premier état, « Plus tard » ferait revenir l'étape à chaque lancement.
C'est aussi pourquoi le `DELETE` n'est pas accordé à `authenticated` : une
préférence se vide, elle ne s'efface pas.

**Aucune contrainte ne valide les identifiants**, et c'est délibéré : une liste
figée en SQL devrait être réécrite à chaque jeu ajouté, or une migration jouée ne
se modifie pas. La tolérance est côté application — `Game.tryFromId` écarte ce
qu'elle ne connaît pas, là où `Game.fromId` replierait sur Magic et ferait
déclarer au compte un jeu qu'il n'a jamais coché. Un jeu retiré du code laisse
alors une ligne inerte, jamais une erreur.

**Un réglage de confort ne bloque jamais la porte.** L'aiguillage de démarrage
n'ouvre l'étape que sur une réponse *connue* : tant que le profil charge, ou si
sa lecture échoue, c'est l'application qui s'affiche. L'inverse ferait attendre
une requête réseau à chaque lancement, et une panne de Supabase rendrait la
collection inaccessible. La contrepartie — un bref passage par l'accueil avant
que l'étape ne s'ouvre — ne concerne que les comptes qui n'ont jamais répondu.

La politique se vérifie sous le rôle qui la subit :
`api/app/measure/profiles_rls.py` joue les deux sens — écrire et relire son
profil, se voir refuser celui d'autrui et la suppression du sien — puis restaure
l'état initial.

### Ce qui vit hors du dépôt, et que rien dans le code ne signale

| Réglage | Où | Porté par |
|---|---|---|
| Schéma `deckhand` déclaré | `AndroidManifest.xml` | le dépôt |
| `deckhand://reset-password` autorisé | Supabase → URL Configuration | `push_auth_config.py` |
| Relais d'envoi (Brevo) | Supabase → Auth → SMTP | `push_auth_config.py` |
| Sujet et corps du courriel | Supabase → Auth → Templates | `supabase/templates/` |

**Le courriel part par Brevo, sur le compte de DewDrop.** Le relais de
démonstration de Supabase plafonnait à **deux courriels par heure** et n'écrivait
qu'aux membres du projet : un tiers n'aurait rien reçu, sans erreur visible côté
application. Le quota gratuit de Brevo est de 300 par jour, sans commune mesure
avec le besoin — une réinitialisation se compte en unités par mois.

**Partager le compte ne laisse aucune trace chez le destinataire.** Ce qu'il voit
— nom d'expéditeur, adresse, sujet, corps — est réglé **par projet Supabase** ;
l'identifiant de connexion au relais n'apparaît jamais dans le message. DeckHand
écrit donc sous `DeckHand <no-reply@heianenterprise.com>`, domaine déjà
authentifié pour DewDrop, ce qui évite en prime la mention « via
smtp-brevo.com » qu'ajoute Gmail quand la signature ne correspond pas.

Ce qui *est* partagé tient à l'administration : le quota, les journaux d'envoi
mêlés, et une révocation qui casserait les deux applications en silence. Une clé
dédiée sur le même compte lèverait ces trois points sans rien changer au
message ; le coffre le dit à l'endroit où la question se posera.

**Le gabarit est dans le dépôt** (`supabase/templates/recovery.html`) et non dans
la console : celle-ci ne garde aucun historique, et un texte qui parle au nom du
produit se relit en revue comme le reste. `{{ .ConfirmationURL }}` y est
obligatoire — `push_auth_config.py` refuse de pousser un gabarit qui ne le
contient pas, faute de quoi le courriel partirait sans mener nulle part.

**Le lien ouvre l'application, pas une page.** Relevé sur un ordinateur, il ne
donne rien : le gabarit le dit donc explicitement, plutôt que de le laisser
découvrir en cliquant.

**Granularité de collection retenue** : carte + édition + finition. La finition entre dans la clé d'unicité (`UNIQUE NULLS NOT DISTINCT (collection_id, oracle_id, print_id, is_foil)`) parce qu'un exemplaire brillant se vend couramment le double ou le triple de sa jumelle : les confondre fausse la valorisation dans les deux sens. L'écran de collection le signale par un fond irisé, lisible au défilement là où une mention en petits caractères demandait d'être cherchée. L'état (NM/played) reste ignoré — pure saisie manuelle, sans apport pour le deckbuilding.

**La collection compte des éditions, le deckbuilding compte des cartes.** `my_collection_summary.distinct_cards` dénombre les couples (extension, numéro) — une carte sans édition précisée en valant un. Compter les `oracle_id` annonçait « 180 cartes dont 179 références distinctes » à qui possède deux Plaines numérotées 277 et 278 : Scryfall donne un identifiant oracle unique à tous les terrains de base d'un même type, et la collection en connaît 871 éditions. Les deux lectures sont justes, mais pas au même endroit — deux illustrations occupent deux cases d'un classeur, quand `deck_suggestions` doit continuer de voir deux exemplaires de la même carte. Conséquences assumées de cette unité : la même édition en français et en anglais compte pour une, le brillant aussi, la finition n'étant pas un numéro.

**`add_to_collection` et `remove_from_collection` rendent le total de la carte**, toutes éditions et finitions confondues — le même nombre que `search_cards.owned`, et donc celui qu'affichent « Déjà N » et « vous en avez N ». Ils rendaient auparavant la quantité de la ligne touchée : les deux coïncidaient tant qu'on ne possédait qu'une version d'une carte, et divergeaient dès la seconde. Posséder un Marais sans édition, en choisir une, ajouter : la base créait une deuxième ligne à un exemplaire et renvoyait 1, si bien que l'écran affichait « Déjà 1 » avant comme après — pour deux Marais en collection. Le décompte par édition n'est pas perdu : le sélecteur le porte ligne par ligne, où il a du sens.

**Ce qui reste à préciser est atteignable.** `my_collection(p_unspecified_only)` restreint la page aux exemplaires sans édition, et l'écran expose le filtre dès qu'il en existe. Les compter sans donner le moyen de les rejoindre laissait un chantier visible et inaccessible : sur deux mille cartes, on ne les retrouve pas une à une dans la liste. Le filtre reste affiché tant qu'il est actif, même une fois le compte tombé à zéro — sinon le bouton disparaîtrait en laissant une liste filtrée et vide, sans moyen d'en sortir.

**Le numéro de collection départage tous les tris.** Trier par rareté rangeait ensuite par nom, si bien qu'à l'intérieur des communes l'ordre paraissait aléatoire à qui range une boîte, où les numéros se suivent. Le numéro est donc le second critère de chaque tri — y compris par valeur, où deux cartes au même prix se suivent désormais dans l'ordre du classeur. Le nom reste en dernier recours, sans quoi deux cartes de même numéro dans deux extensions pourraient changer de place d'une page à l'autre.

**Le tri se renverse en re-choisissant son critère.** Chaque critère porte son sens naturel — les cartes les plus chères d'abord, mais les noms de A à Z — et le re-sélectionner inverse la liste. Un second contrôle « croissant / décroissant » n'aurait eu de sens qu'accolé au premier, pour un geste qu'on fait de toute façon sans y penser. Côté base, `p_descending` pilote la direction ; le sens d'origine de chaque critère est décidé par l'application (`CollectionSort.startsDescending`), qui est aussi celle qui l'affiche.

**Une carte sans cote se range avec celles qui valent zéro.** Le tri par valeur les plaçait en queue de liste dans les deux sens : en ordre croissant, elles arrivaient donc *après* les plus chères. Personne ne cherche une carte sans prix à côté des plus précieuses. `COALESCE(prix, 0)` remplace `NULLS LAST` — la ligne continue d'afficher un tiret, seul l'ordre change, et il dit désormais la même chose que la valorisation, qui compte déjà ces cartes pour zéro. Le cas est massif : **82 549 impressions sur 166 998 n'ont pas de cote en euros**, Scryfall ne cotant que ce qui s'échange réellement sur les places de marché suivies — 1 590 des 3 209 impressions de jetons n'ont aucun prix, un jeton ne se vendant pratiquement jamais à l'unité.

**Trois filtres de rangement** : la finition (`p_finish`), la pleine illustration (`p_full_art`) et ce qui reste à préciser. `card_prints.full_art` vient de Scryfall — 7 786 impressions sur 163 456 — et décrit l'impression, pas la carte : la même carte existe dans les deux formes, et un collectionneur les range à part. La rareté s'ordonne par `rarity_rank`, qui réunit les deux jeux sur une même échelle : triée comme du texte, « common » précéderait « rare » qui précéderait « uncommon ».

**La collection se trie aussi par numéro de collection.** Les autres critères — nom, valeur, quantité, date d'entrée — répondent à des questions d'inventaire ; celui-ci répond à la seule qu'on se pose une carte à la main devant une boîte : où va-t-elle ? Le tri porte sur la partie chiffrée du numéro, `collector_number` étant un `text` qui accepte les suffixes (`43a`, `★43`) et rangerait sinon 100 avant 2. Les cartes sans édition précisée n'ont pas de numéro et ferment la marche, ce qui les désigne du même geste comme celles qui restent à préciser.

**Le tri « classeur » ajoute l'extension par-dessus le numéro**, parce que le numéro seul mêle les volumes : `mar #43` et `msh #43` se suivaient, alors qu'ils sont rangés dans deux classeurs différents. L'extension désigne le classeur, le numéro la case. Les extensions sont ordonnées **alphabétiquement par code** : par date de sortie serait plus proche d'une étagère réelle, mais deux extensions parues le même jour deviendraient arbitraires, et l'ordre changerait sous les yeux de l'utilisateur au gré des rééditions. Renverser ce tri renverse le couple entier — dernière extension, dernière page — n'en inverser qu'une moitié donnerait des classeurs à l'envers contenant des pages à l'endroit. Les deux tris coexistent : le numéro seul reste le moyen de retrouver une carte dont on ne sait plus de quelle extension elle vient.

### Le classeur : une vue dérivée, jamais une table

**Un classeur est une édition, une case est un numéro.** Il n'y a donc rien à stocker : la case est le couple `(set_code, collector_number)`, déjà porté par `card_prints`. Le classeur se dérive de la collection au lieu de s'y ajouter, et l'on ne peut pas l'en désynchroniser — il n'en est qu'une lecture. Deux fonctions suffisent : `my_binder_shelf` pour l'étagère, `my_binder_page` pour neuf cases.

**Une case n'est pas une impression.** Le catalogue porte l'anglais et le français ; le #412 anglais et le #412 français partagent la même case, la langue étant une propriété de ce qu'on y range. Chaque case élit donc une impression représentative pour son illustration et son nom — le français d'abord, l'illustration étant de toute façon identique. Le brillant ne dédouble pas non plus la case : deux cases pour un même numéro casseraient la grille physique, il est signalé sur celle qu'il occupe.

**Ce que le classeur montre et qu'une liste ne montre pas, ce sont les cases vides.** `my_binder_page` part du catalogue et non de la collection : une case non possédée existe, occupe sa place, et porte son numéro. C'est une vue de complétion d'édition — la liste dit ce qu'on a, le classeur dit ce qui manque.

**Une case vide dit désormais laquelle.** « #2 » nommait la case et non la carte : il fallait chercher ailleurs pour savoir quoi acheter. La fonction rendant déjà `art_crop_url` pour **toutes** les cases — elle part du catalogue —, l'illustration s'affiche en fantôme à 24 % d'opacité, sans requête supplémentaire. Assez pour reconnaître la carte, trop peu pour qu'une case vide se confonde avec une pleine ; le numéro reste, complété et non remplacé, avec une ombre qui lui rend ses contours sur l'image. L'appui long l'agrandit, puisqu'à trois par ligne et à un quart d'opacité on la reconnaît sans pouvoir la lire ; toucher la case, elle, n'ouvre toujours rien — il n'y a rien à ajouter ni à retirer d'une carte qu'on ne possède pas. Le réglage (`showMissingArtProvider`) **n'entre pas dans la clé des pages** : il ne change pas ce que le serveur rend, et l'y mettre ferait retélécharger le classeur à chaque bascule. Il ne s'offre que dans le régime de rangement, seul où des cases vides existent.

**L'entrée est une étagère, pas un classeur.** 695 éditions au catalogue : n'y figurent que celles où au moins une carte est rangée, les autres seraient 690 classeurs vides. Mesuré sur la collection réelle : `msh` 216/453 cases (47,7 %), `tmsh` 15/27, `msc` 12/866, `mar` 3/100, `tmsc` 1/32. La page est demandée au serveur et non découpée côté application — une édition compte jusqu'à 866 cases, soit 97 feuilles.

**Chaque classeur s'identifie comme un produit.** Une étagère de noms ne se distingue pas : cinq lignes de texte gris se ressemblent toutes, quand un classeur physique se reconnaît de loin. La tuile est donc une bannière — l'illustration de la **carte-vedette de l'extension**, coiffée du **symbole officiel** du set.

**Le bundle n'existe dans aucune source exploitable**, et c'est ce qui dicte la solution. La fiche complète d'une extension chez Scryfall ne porte qu'un seul visuel : `icon_svg_uri`. Ni boîte, ni display, ni illustration promotionnelle — ces photos appartiennent aux marchands ou à Wizards, n'ont pas d'API, et leur reprise automatisée contredirait les garde-fous du projet. Le symbole imprimé sur chaque carte est ce qui s'en approche le plus, et c'est le marqueur qu'un joueur reconnaît avant d'avoir lu le nom.

**La vedette est la plus chère du set entier, non de la collection.** Deux personnes qui possèdent la même extension la reconnaissent ainsi à la même image, comme deux exemplaires d'un même produit. Mesuré : `msh` → The Mind Stone (32,67 €), `msc` → Loki, Lord of Misrule (39,69 €), `mar` → Roaming Throne (32,36 €) — les mythiques emblématiques de chaque sortie. Le prix se lit sur `card_prints` sans repli linguistique, à dessein : la version anglaise porte la cote, la française porte la même illustration, et c'est l'illustration qu'on cherche. Une extension de jetons n'ayant aucune cote, sa première case fait une couverture stable là où l'ordre du moteur en changerait à chaque appel.

C'est l'**illustration recadrée** qui sert ici, et non la carte entière comme dans une case : une bannière est un paysage, une carte un portrait. Le texte tient dessus grâce à un voile sombre en dégradé plutôt qu'à un pari sur le contraste — on ne sait pas si l'illustration qui remontera sera claire ou foncée. C'est aussi pourquoi l'habillage (titre, pourcentage, barre, symbole) reste blanc : la couleur vient de l'image, pas du thème. Une édition sans illustration connue, ou un réseau absent, laissent voir un dégradé peint sous l'image — la tuile reste une tuile plutôt que de devenir un trou dans l'étagère.

#### `card_sets` : pourquoi une table là où le projet préfère déduire

L'URL du symbole ressemble à `svgs.scryfall.io/sets/<code>.svg`, ce qui invitait à la déduire du code d'extension comme `fullCardImage` déduit la carte de son illustration. **Mesuré sur les 1 047 extensions du catalogue Scryfall, la déduction est fausse deux fois sur trois** :

| Règle | Extensions couvertes |
|---|---|
| icône = `<code>.svg` | 342 (32,7 %) |
| + « `t` + code parent » (les jetons empruntent le symbole de leur extension mère, `tmsh` → `msh`) | 182 |
| **arbitraires** — `pl26` → `star`, `amsh` → `msh`, `ysos` → `y26` | **523** |

Sur la collection réelle, la déduction échouait sur deux classeurs sur cinq, les extensions de jetons y pesant lourd. `public.card_sets` porte donc les 1 047 extensions (code, nom, type, extension mère, date, nombre de cartes, symbole), alimentée par `app.ingestion.scryfall_sets`. C'est le seul endpoint paginé que DeckHand interroge — il n'existe pas d'export groupé pour les extensions, et quelques centaines de kilo-octets ne le justifieraient pas. Le job est ingéré **à chaque rafraîchissement**, hors du saut de version qui protège le catalogue de 390 Mo : le protéger de la même garde ferait qu'une table vide le resterait jusqu'à la prochaine republication de Scryfall.

**Le réseau ne renvoie pas toujours un SVG**, et `flutter_svg` n'y survit pas seul : `SvgNetworkLoader` ne regarde ni le code HTTP ni le type de contenu, et son `provideSvg` déréférence sans garde. Une URL morte — Scryfall répond alors 27 Ko de page HTML — fait lever « Invalid SVG data » au décodeur, dans un `compute`, hors de l'arbre, là où l'`errorBuilder` du widget ne la voit jamais : l'exception remonte à la zone et emporte l'écran pour un ornement. `SafeSvgLoader` (`lib/src/common/remote_svg.dart`) prend le remède à la source : échec réseau et contenu non-SVG rendent tous deux un SVG valide et vide.

#### Les symboles de Magic sont chargés, jamais embarqués

Les symboles de mana (`{W}`, `{U}`, …) comme les symboles d'extension sont **copyright Wizards of the Coast** — Scryfall l'écrit noir sur blanc — et servis au titre de la **Fan Content Policy**, « for the primary purpose of creating additional Magic software ». Les télécharger pour les commiter comme assets reviendrait à les **redistribuer** depuis un dépôt public, ce que le garde-fou 10 interdit pour toute donnée venue d'une source.

Rien ne l'impose d'ailleurs : Scryfall documente que « the direct file origins located at `*.scryfall.io` do not have rate limits ». Le chargement à l'exécution est donc la voie normale, et c'est celle retenue partout.

Contrairement aux symboles d'extension, l'URL d'un symbole de mana **se déduit** — `svgs.scryfall.io/card-symbols/<symbole>.svg`, vérifié sur les six symboles qui nous concernent via l'endpoint `symbology`. Pas de table, donc : `manaSymbolUrl` suffit.

**Le symbole n'est jamais retouché, ni retiré.** Le fichier porte le disque coloré complet, pictogramme compris : il remplace la pastille au lieu de se poser dessus, d'où un fond transparent sous lui — une pastille saturée derrière un symbole pastel ferait un liseré discordant. Les trois états se disent par l'opacité, qui laisse le symbole entier là où une teinte le dénaturerait : plein s'il est voulu, à 45 % s'il est indifférent, à 30 % **sous un interdit** s'il est banni. Le remplacer par l'interdit disait qu'une couleur était refusée sans dire laquelle — il ne restait que la position dans le pentagone pour la reconnaître. Barré, il dit les deux à la fois. Pendant le chargement, la pastille de couleur tient la place : la roue est utilisable avant même que le réseau ait répondu, et le reste s'il ne répond jamais.

Les cartes sans édition précisée n'ont **aucune case**, par construction. Elles ne sont pas perdues pour autant : `my_collection_summary` les compte, et le bandeau de l'onglet le rappelle.

**La case montre la carte entière, pas son illustration.** Une case de classeur contient une carte — son cadre, son nom, son coût, son numéro. N'en montrer que l'illustration donnait une planche-contact, jolie mais impossible à reconnaître comme sa propre collection. À trois par ligne le texte imprimé devient illisible, exactement comme dans un vrai classeur qu'on regarde de loin : c'est l'image qu'on reconnaît, pas le texte qu'on lit. L'URL de la carte entière est **déduite** de celle de l'illustration (`fullCardImage`), les tailles de Scryfall ne différant que par un segment de chemin — vérifié sur de vraies URL. La solution de rechange serait une colonne de plus sur 167 000 impressions et une réingestion complète ; elle redeviendra la bonne réponse si Scryfall change la forme de ses URL, ce qui casserait de toute façon `art_crop_url` du même coup.

**Le brillant se montre, il ne se dit pas.** Un symbole annonce qu'une carte est brillante ; un reflet le montre — et ce qu'on reconnaît d'un classeur ouvert, c'est justement une pochette qui accroche la lumière au milieu de cartes mates. `FoilSheen` pose un dégradé de diffraction **par-dessus** l'image, là où `foilDecoration` glisse le sien derrière une ligne de texte : sur une case pleine, un fond serait entièrement masqué.

### Ranger ou inventorier : deux régimes, une seule différence

**Le tri par numéro range, les autres inventorient**, et tout tient dans le sort des cases vides. Trié par **numéro**, le classeur montre les trous : la question posée est « que me manque-t-il ». Trié par **valeur**, par **exemplaires** ou par **nom**, la question devient « mes cartes, de la plus chère à la moins chère » — et une case vide n'a alors ni valeur, ni exemplaire, ni nom, ni place dans un ordre qui ignore les numéros. Elle disparaît, et c'est ce que la demande implique. `BinderSort.keepsEmptyCells` porte cette distinction, et `my_binder_page` l'applique côté serveur : hors du rangement, les cases non possédées ne sont pas rendues.

**« Qu'est-ce que je viens de saisir » est la question d'après.** Le tri par date d'entrée existait dans la liste et s'est perdu avec elle ; c'est pourtant le geste qui vérifie une saisie, retrouve le lot d'hier, reprend là où l'on s'était arrêté. Il inventorie comme les autres : une case vide n'a pas de date d'entrée.

`added_at` mesurait la **première acquisition**, ce qui rendait ce tri trompeur avant même qu'il existe. `add_to_collection` incrémente la quantité d'une ligne déjà présente sans toucher sa date : une carte possédée depuis une semaine dont on ajoutait un exemplaire restait datée de la semaine passée. Vécu sur la collection réelle — une carte complétée le lendemain n'apparaissait nulle part parmi les dernières entrées, et l'on cherchait en vain un ajout pourtant enregistré. La date porte désormais le **dernier ajout** : une carte dont on vient d'ajouter un exemplaire vient d'être ajoutée. Retirer un exemplaire, en revanche, ne la remonte pas — on ne range pas ce qu'on sort. Une case réunissant plusieurs lignes (deux langues, deux finitions) prend la plus récente d'entre elles.

**« Combien en ai-je » est une question de rangement.** Le compte des doublons figurait déjà au coin de chaque case, mais il fallait parcourir cinquante feuilles pour rassembler ce qu'on possède en nombre — alors que c'est la question posée avant de bâtir un deck : un playset se repère, il ne se cherche pas. Le tri par exemplaires la met en tête de classeur. **L'égalité y est la règle** et non l'exception, la plupart des cartes étant possédées une seule fois : l'ordre du rangement reprend alors la main, si bien que la queue du classeur reste feuilletable comme un classeur. Mesuré sur `msh` : six Forêts, puis cinq Plaines, Marais et Montagnes, puis les quatre exemplaires de « Brutes de Roxxon » — les terrains de base dominent, ce qui est précisément l'inventaire qu'on venait chercher.

**Le filtre de finition, lui, ne change pas de régime.** Restreindre au brillant ne sort pas du rangement : l'ordre reste le numéro, seule change la définition de « possédé ». Une case vide y signifie « je n'ai pas cette carte en brillant » — c'est la complétion d'un classeur de brillants, et les trous restent à dessein.

**Une page vide n'est pas une impasse.** Un filtre serré laisse des feuilles entièrement creuses : sur les 97 feuilles de `msc`, dont douze cases occupées, ouvrir à la première serait ouvrir sur du vide. `my_binder_first_page` dit où commencer — mesuré : page 42 pour `msc`, page 2 pour les brillants de `msh`. La question ne se pose que dans le régime de rangement ; ailleurs, la première page est pleine par construction.

**Le prix d'une case est celui de la plus chère de ses impressions.** L'impression représentative est choisie française pour son nom imprimé, or Scryfall ne cote pratiquement que l'anglais : trier par valeur ne triait rien, toutes les cases valant zéro. La case étant le même objet physique quelle que soit la langue, son prix se prend sur l'ensemble.

### Le journal des mouvements

**Une quantité et une date ne racontent pas une histoire.** `collection_items` porte « ×3 » et une seule estampille, qu'un ajout écrase : une ligne alimentée trois jours de suite n'en garde qu'un seul. « Quand ai-je acquis cette carte » n'avait donc aucune réponse — constaté sur une Cavalerie atlante possédée en trois exemplaires français, dont il était impossible de dire combien dataient de la veille. `collection_movements` garde chaque entrée et chaque sortie.

**Un trigger plutôt que trois fonctions réécrites.** `add_to_collection`, `remove_from_collection` et `set_collection_print` sont éprouvées ; les rouvrir pour y glisser une écriture risquait une régression sur les gestes les plus employés du produit. Le trigger consigne à leur place, et surtout **rien ne peut lui échapper** : une écriture directe, un script d'ingestion, une correction à la main laissent tous leur trace.

**Ce qu'on ne stocke pas, c'est l'intention.** Le trigger ne voit que des deltas. Préciser l'édition d'une carte déplace des exemplaires d'une impression à une autre — un retrait et un ajout, qui ne sont pourtant ni une perte ni une acquisition. Plutôt qu'une colonne « genre » que l'appelant devrait renseigner honnêtement, on retient l'**identifiant de transaction** et l'on reconnaît un déplacement à sa signature : **exactement deux mouvements, de somme nulle, sur la même carte**. La première version de cette règle demandait seulement à la transaction de porter les deux signes ; trois gestes joués ensemble y répondaient tous, et le journal les étiquetait tous « changement d'édition ». Passer par l'application ne pose pas la question — chaque appel RPC est sa propre transaction — mais la règle protège des scripts et des corrections à la main.

**Le journal ne réécrit pas le passé.** Il s'amorce sur un report d'ouverture, une ligne par entrée existante, datée de son `added_at`. C'est faux au détail près — ces ×3 sont peut-être trois gestes — et honnête à l'échelle : le solde du journal égale la collection dès le premier jour, et l'on sait que tout ce qui précède l'ouverture est une reprise en bloc. `is_opening` le dit à la lecture, et l'écran l'affiche « Déjà là » plutôt que « Ajoutée ».

**Inaltérable depuis le client.** Aucun droit d'écriture n'est accordé sur la table ; seul le trigger écrit, sous les droits du propriétaire (`SECURITY DEFINER`). L'application peut lire son journal, pas le maquiller.

### La pile à trier

**Une carte sans édition précisée n'a aucune case**, par construction — ni extension, ni numéro. Elle était donc invisible dès que la collection se regardait en classeur, ce qui est devenu grave le jour où le classeur est passé en vue par défaut. `my_unsorted_pile` la montre.

**C'est une pile, pas un classeur**, et la fonction le dit : aucun numéro, aucune case vide, aucun taux de complétion. Elle est ordonnée **par entrée, la plus récente d'abord** — une pile se prend par le dessus, et ce qu'on vient de saisir est ce qu'on a encore en main ; trier par nom aurait enfoui la dernière carte scannée au milieu de l'alphabet. Toucher une carte ouvre le sélecteur d'édition et appelle `set_collection_print` : la pile se vide à mesure qu'on range, et l'entrée disparaît de l'étagère quand il ne reste rien.

L'illustration y est celle d'une impression **représentative**, faute d'impression désignée. C'est faux au sens strict — ce n'est pas forcément l'exemplaire qu'on tient — et sans conséquence : cette vue sert à reconnaître une carte pour lui donner son édition.

### Chercher une carte, et agir sur une case

**Le champ de recherche repart de la requête en cours, pas de rien.** Ouvrir un classeur démonte l'étagère et emporte le contrôleur du champ ; en revenant, un nouveau naissait vide alors que la requête, elle, survivait dans son provider — l'écran montrait donc les résultats d'une recherche dont le champ paraissait effacé, et il fallait retaper puis vider pour retrouver ses classeurs. Le contrôleur s'initialise depuis le provider, et l'écoute qu'on lui pose fait enfin apparaître la croix d'effacement pendant la frappe plutôt qu'au prochain rebuild venu d'ailleurs.

**Chercher était la dernière chose qu'une liste faisait mieux qu'un classeur.** L'ordre des numéros ne répond pas à « où est ma Foudre ? » : il faudrait connaître l'extension et tourner les feuilles. `my_binder_find` rend donc la **page**, pas seulement la case, et le résultat y mène d'un geste. La recherche ne porte que sur les cartes possédées — chercher dans un classeur, c'est chercher parmi ses cartes ; proposer les 33 000 autres du catalogue ferait doublon avec la recherche de cartes, qui existe ailleurs.

**Toucher une case ouvre ce qu'on peut en faire** : ajouter un exemplaire, en retirer un, corriger l'édition. Ces gestes vivaient dans la liste, et le retrait n'existait nulle part ailleurs — les perdre en la supprimant aurait été une régression déguisée en simplification. Une case vide n'ouvre rien : il n'y a rien à retirer d'une carte qu'on ne possède pas.

### La liste triable a été supprimée

L'onglet Collection n'a plus qu'une vue. Chacun des services de la liste a trouvé un équivalent qui ne dénature pas le rangement :

| Ce que la liste faisait | Ce qui le fait |
|---|---|
| Trier par valeur, par quantité, par nom | Les régimes de lecture du classeur |
| Filtrer sur la finition | Le filtre du classeur, trous conservés |
| Atteindre les cartes sans édition | La pile « à trier » |
| Chercher une carte par son nom | La recherche de l'étagère, qui donne la page |
| Ajouter, retirer, corriger l'édition | Les actions d'une case |

Ce qu'on y gagne est ce qu'aucune liste ne montrait : **les cases vides**. Le bandeau de totaux subsiste — il porte sur la collection entière et vient d'un appel distinct, si bien qu'aucun filtre ne le fait varier. `my_collection` reste en base, désormais sans appelant : la fonction est juste, et la ressortir coûterait moins que la réécrire.

### Les feuilles se tournent

**Un vrai retournement, pas un fondu ni un glissement.** Ce qu'on reconnaît d'un classeur qu'on feuillette, c'est la feuille qui pivote sur sa reliure : elle se soulève, montre sa tranche, laisse voir la suivante par-dessous, puis retombe en présentant son dos. Un fondu enchaîné donnerait la même information sans donner la même chose à voir. `page_turn.dart` porte la mécanique.

**La reliure est à gauche**, comme un classeur à anneaux ouvert à plat : glisser vers la gauche avance, vers la droite on revient. Un seul mouvement est calculé — celui vers la gauche — et le retour en est l'image dans un miroir : une seule géométrie à écrire, donc une seule à régler. Le contenu est alors remis à l'endroit une seconde fois, sans quoi les cartes s'afficheraient inversées pendant tout le geste.

**Le geste ne pilote que l'avancement.** La feuille se courbe et se tourne de la même façon quel que soit l'endroit où on la prend : seule la distance parcourue compte, et la hauteur de la saisie n'entre pas dans la géométrie.

**Le dos d'une feuille ne montre pas la page suivante.** Il l'a d'abord fait, et l'effet était celui d'une feuille transparente : on voyait les cartes de la page découverte deux fois, dont une par-derrière. Ce qu'on voit en tournant une page de classeur, ce sont **les pochettes vides** — le plastique et ses logements, pas les cartes glissées de l'autre côté. Le verso n'y charge donc aucune image, ce qui évite au passage de doubler les neuf cartes d'une feuille en mouvement.

**La courbure se compose de proche en proche.** Un premier essai pivotait chaque lamelle verticale autour de son propre bord *de l'angle global* : les tranches se croisaient au lieu de rester jointes, et les cartes apparaissaient coupées en morceaux. Chaque lamelle repart désormais du bord où la précédente s'achève — on avance de `cos θ` et on s'enfonce de `sin θ`. Une deuxième erreur la dédoublait en escalier : le `Stack` des lamelles imposait la largeur totale à chacune d'elles ; des contraintes lâches ont suffi.

**Une troisième laissait passer le jour.** La lamelle était pivotée de l'angle pris en son *milieu*, mais le curseur avançait selon l'angle de son *bord droit* : deux angles pour une même facette, donc des bords qui ne se rejoignaient pas tout à fait. L'écart s'ouvrait avec la courbure, et de fines fentes verticales laissaient voir la page du dessous **à travers une feuille pourtant opaque**. Le symptôme trompe : on croit distinguer les cases les unes des autres et l'on cherche la cause dans la peinture du dos, alors qu'elle est dans la géométrie. `stripePlacements` n'emploie plus qu'un seul angle par lamelle, ce qui rend la continuité vraie par construction — et testée comme telle, tout au long du geste. Un demi-pixel de recouvrement ferme en plus la couture que l'arrondi de rastérisation rouvrirait de part et d'autre.

Trois choses donnent le relief et ne peuvent rien casser : un **reflet** qui balaie la feuille au rythme de sa rotation, une **ombre portée** sur la page qu'elle découvre, et une **arête sombre** le long de la reliure, là où une page réelle s'incurve toujours. Les trois s'annulent à plat et culminent à mi-course. Les trois réglages de la courbure — nombre de lamelles, amplitude, profil — sont isolés en tête de fichier : ils ne se jugent qu'à l'œil, sur un appareil.

**Le geste pilote l'animation, il ne la déclenche pas.** La feuille suit le doigt et l'on peut revenir en arrière en cours de route ; elle ne bascule qu'au-delà du tiers de la largeur, ou plus tôt si le geste est vif (600 px/s). Un frôlement pendant qu'on regarde ne tourne donc rien. La page ne change qu'une fois la feuille retombée : la changer à mi-course rechargerait la grille sous le doigt.

**La charge est tenue par le voisinage, pas par la taille des images.** L'issue prescrivait les vignettes ; la carte entière a été préférée — c'est elle qu'on range dans une case — et le coût est absorbé autrement : seules les feuilles **immédiatement voisines** sont préchargées, et hors mouvement une seule feuille est construite. Précharger plus loin rapatrierait un classeur entier pour en montrer un neuvième.

**La feuille entière tient à l'écran.** Un rapport figé à 0,716 — la proportion d'une carte — débordait en hauteur et coupait la troisième rangée. Une feuille de classeur ne défile pas, elle se tourne : c'est donc la grille qui s'adapte à la place disponible, quitte à laisser de l'air sur les côtés. Dans le même but, les six puces de tri et de finition ont laissé place à **deux menus** sur une seule ligne, et la glissière permanente a disparu — elle coûtait la hauteur d'une rangée pour un geste rare. Traverser les 51 feuilles reste possible en touchant « Page 3 sur 51 ».

**Le cadre de l'agrandissement épouse la carte, pas l'écran.** Sans rapport imposé, le reflet des brillantes couvrait toute la boîte de dialogue : la carte flottait au milieu d'un rectangle irisé. Le rapport d'une carte du jeu affiché borne le reflet à ce qu'il qualifie.

**L'appui long montre la carte en grand.** À trois par ligne, le texte imprimé est illisible — c'est assumé, on reconnaît l'image — mais lire une carte reste parfois nécessaire. Le reflet suit la carte agrandie : c'est le moment où l'on regarde vraiment l'exemplaire qu'on possède.

Ce qui reste à mesurer est la **fluidité sur un vrai téléphone** : neuf cartes entières par feuille, dix-huit pendant un retournement. C'est le point que l'issue #12 désigne comme le vrai risque, et il ne se juge pas au simulateur.

### Deux voies de reconnaissance, dans l'ordre

Depuis le test terrain, la carte est identifiée **par son nom d'abord**, par son illustration ensuite.

1. **Lecture du nom** — ML Kit reconnaît le texte, embarqué et hors ligne (aucune image ne quitte l'appareil). Les lignes situées dans le tiers supérieur sont retenues, débarrassées du bloc d'identification en marge (« C 0679 », « MSC★FR »), du coût en mana, de la force/endurance et du copyright. Les trois premières partent ensemble vers `search_cards`, dont la tolérance aux fautes absorbe les erreurs de lecture.
2. **Empreinte d'illustration** — inchangée, elle sert désormais de recours (texte illisible, fort reflet, web où ML Kit n'existe pas) et de **confirmation** : quand les deux voies désignent la même carte, le doute est levé quelle que soit la distance.

Le nom est le seul repère stable : il figure en première ligne sur toutes les éditions depuis 1993, reste lisible de travers, et ne dépend pas de l'illustration — donc pas de l'édition. L'empreinte garde en revanche un rôle que le nom ne peut pas tenir : distinguer deux impressions d'une même carte.

`ScanMethod` remonte la voie employée jusqu'à l'écran, qui annonce « nom lu », « illustration » ou « nom et illustration ». Dire d'où vient une proposition permet à l'utilisateur de juger s'il peut la croire.

**Coût :** +30 Mo d'APK (53,6 → 83,8 Mo), le modèle latin étant empaqueté. Les modules chinois, japonais, coréen et devanagari sont écartés par `android/app/proguard-rules.pro` — sans quoi R8 refuse de compiler, le plugin les référençant sans qu'ils soient présents.

### L'édition se lit par son code d'extension, jamais par son numéro

Une case de classeur est le couple `(set_code, collector_number)`, et le premier réflexe est de lire la ligne qui porte les deux : « 0412/0853 U • MSH • FR ». **Le numéro n'est pas lisible sur une photo à main levée.** Sur la seule lecture réelle figée (`test/src/features/scan/measured_spread.dart`, 36 lignes), il sort « C O0O5 » et « 02 » — il est imprimé deux fois plus petit que le nom, ce que la hauteur relative des caractères confirme : 0,006 à 0,008 de la hauteur de l'image contre 0,016. Le **code d'extension** de la même ligne, lui, sort juste deux fois sur deux : il est en capitales et plus large.

Or le code suffit presque toujours. Mesuré au catalogue par `api/app/measure/edition_from_set.py`, sur les 31 841 cartes Magic hors jetons :

| Lecture | Part |
|---|---|
| Couples (carte, extension) désignant **une seule case** | **83,1 %** (69 695 / 83 870) |
| Idem, restreint au français | 87,9 % (43 957 / 50 001) |
| Cartes n'existant que dans une seule extension | 46,5 % — déjà tranchées par `sole_editions` |
| Pondéré par les exemplaires du corpus de decks | 72 % en cas moyen, 40,6 % en pire cas |

La carte étant déjà identifiée par son nom, lire son extension précise donc son édition **sans caméra fixe et sans jamais lire le numéro**. Les deux lectures pondérées encadrent la réalité : le corpus ne dit pas de quelle extension vient l'exemplaire joué, le pire cas suppose qu'on possède toujours la réédition la plus alambiquée, le cas moyen qu'on en possède une au hasard.

**On ne cherche pas un code dans l'absolu.** `readSetCode` reçoit les extensions où la carte identifiée existe — de une à quelques dizaines sur les 695 du catalogue — et ne retient qu'un mot entier, en capitales, qui coïncide avec l'une d'elles. Un nom d'illustrateur ou un mot du texte de règles n'a donc aucune chance d'en désigner une par accident, et l'exigence de capitales écarte le « one » d'un texte anglais qui désignerait sinon l'extension ONE. Deux codes distincts lus sur la même photo rendent `null` : deviner lequel est le bon serait deviner tout court.

**Mesuré sur onze cartes photographiées une par une : dix codes lus, aucun faux.** Les deux échecs rencontrés ont des causes distinctes, et une seule était corrigeable. Sur Moonstone, la séparation avait disparu (`MSHEN`) — c'est le correctif décrit ci-dessous. Sur Hex Magic, le code lui-même était mutilé, `MSH` rendu `M54`, sur une ligne où le nom de l'illustrateur l'était tout autant (`KEYIN GLNT` pour Kevin Glint) : la photo était floue à cet endroit. Tolérer deux substitutions sur trois caractères reviendrait à accepter n'importe quel triplet ; l'échec reste donc un échec, et la carte conserve l'état de plein droit « je possède cette carte, je n'ai pas dit laquelle ». Une carte du lot existait dans l'extension `one` : le mot « one » n'a désigné aucune extension, l'exigence de capitales ayant tenu sur un cas réel et non seulement en test.

**Le code peut arriver collé à la langue.** Premier relevé terrain, sur trois cartes photographiées une par une (`test/src/features/scan/measured_set_codes.dart`) : deux codes lus, un perdu. L'échec n'était ni un défaut de netteté ni un mauvais cadrage — sur Moonstone, la ligne `MSH • EN • GRACE ZHU` est sortie `MSHEN GRACE ZH`, la puce séparatrice ayant disparu. Le code était parfaitement lisible et pourtant inexploitable. La règle décompose donc `code + langue`, mais **uniquement si le reste est exactement un code de langue** : accepter un simple préfixe ferait de `MARVEL` — imprimé au bas de ces mêmes cartes, et `mar` est une extension du catalogue — une désignation d'extension sur la carte qui l'affiche. `MARVEL` se décompose en `MAR` + `VEL`, qui n'est pas une langue.

**Le code lu tranche quand il ne laisse qu'une case, et seulement là.** Dans les 83 % de cas où le couple (carte, extension) désigne une case unique, le sélecteur se referme sur elle : faire désigner l'unique candidat n'apporte aucune information que la carte ne porte déjà, et le demander vingt fois de suite est précisément ce qui laissait les cartes « à trier » — mesuré sur la collection réelle, une carte rééditée treize fois y a atterri en double. C'est le raisonnement qui précise déjà d'office les cartes à édition unique lors d'un étalement ; seule change la chose qui restreint — là le catalogue, ici le code imprimé.

Pour les 17 % restants — la carte et sa version étendue partagent l'extension —, le sélecteur reste ouvert : l'extension lue **remonte en tête**, annoncée par « Extension lue sur la carte : MSH », et chaque édition portant le code lu est marquée plutôt que de laisser croire que la première est la bonne. Sur une carte rééditée quarante fois, cet ordre est déjà ce qui rend le geste tenable, et l'annoncer permet de comprendre une lecture fausse au lieu de subir un ordre inexplicable. Rouvrir le sélecteur pour **corriger** une édition laisse toujours choisir, quel qu'ait été le code lu : le refermer d'office rendrait la correction impossible.

### Ce que le premier test terrain a montré (2026-08-07)

Deux cartes scannées, deux échecs, **deux causes distinctes** — mesurées, pas supposées.

**1. L'index d'empreintes était trop mince** — corrigé depuis par la migration 021, voir « Éditions » plus bas. Il ne contenait alors qu'une illustration par carte. Sur Farseek (55 impressions), l'illustration indexée est celle de Ravnica 2005 ; l'exemplaire tenu venait de *Marvel Super Heroes Commander* (2026), à une distance de 32 — hors de portée du seuil de confiance de 12. Sur un échantillon de 11 impressions de cette carte, 8 partagent la même illustration et 3 en ont une radicalement différente (distances 18, 33, 36). L'affirmation « une carte rééditée garde le plus souvent son illustration » est donc vraie aux trois quarts, et fausse pour le quart restant — assez pour faire échouer un scan sur quatre.

**2. Le pipeline exige un cadrage irréaliste.** Sur Big Wheel, l'illustration *était* indexée (distance 0) et le gabarit la découpe correctement (distance 1) : le scan aurait dû réussir. Il a échoué sur le cadrage. Tolérance mesurée en simulant une marge de table autour de la carte :

| Marge autour de la carte | Distance | Verdict |
|---|---|---|
| 0 % | 1 | reconnue |
| 2 % | 7 | reconnue |
| 5 % | 15 | incertaine |
| 10 % | 24 | perdue |

Un décalage latéral de 2 % suffit également à franchir le seuil. **Le pipeline tolérait 2 à 3 % d'écart** — soit 2,6 mm sur la hauteur d'une carte. Aucun cadrage à main levée n'atteint cette précision. C'est ce constat qui a fait passer la lecture du nom devant l'empreinte, et c'est lui que la détection des bords lève (voir ci-dessous).

### La détection des bords, mesurée avant et après

`api/app/measure/framing_bench.py` compose des photos dont on connaît le défaut — marge de table, décalage, rotation — et mesure la distance de l'empreinte obtenue à celle de l'index. **Le tirage des cartes est reproductible** : un `ORDER BY random()` aurait rendu deux exécutions incomparables, et l'écart entre deux versions du code se serait confondu avec l'écart entre deux paquets de cartes.

Sur 40 cartes, seuil de confiance à 12 bits :

| Régime (marge · décalage · rotation) | Cadrage centré | Détection des bords |
|---|---|---|
| parfait — 0 % · 0 % · 0° | 1 bit · 39/40 | 3 bits · 39/40 |
| soigné — 3 % · 1 % · 0,5° | 12 · 23/40 | 4 · 33/40 |
| ordinaire — 8 % · 3 % · 2° | 22 · **0/40** | 3 · **37/40** |
| à la volée — 15 % · 6 % · 5° | 27 · **0/40** | 3 · **37/40** |
| négligent — 25 % · 10 % · 9° | 29 · **0/40** | 3 · **37/40** |

**La médiane ne bouge plus avec le soin apporté à la photo** : le cadrage a cessé d'être le facteur limitant. Cinq détections sur 200 ont renoncé et sont retombées sur le cadrage centré, c'est-à-dire sur le comportement antérieur.

**Pourquoi ce cas réussit là où l'étalement a échoué.** Les impasses de [`spread-detection.md`](./spread-detection.md) portent toutes sur une photo de plusieurs cartes, et ce qui y ruine la segmentation est le **contact** : deux voisines se soudent en une forme unique, de proche en proche. Sur une carte seule, il n'y a pas de voisine à toucher.

**Les quatre coins plutôt que la boîte englobante.** Une carte tournée de cinq degrés a une boîte nettement plus large qu'elle ; y découper une zone en proportions raterait l'illustration autant qu'avant. Les coins s'obtiennent par les extrêmes des sommes et des différences des coordonnées — exact pour un rectangle quelle que soit sa rotation, et insensible au bruit du contour.

**L'image n'est jamais redressée.** Redresser demanderait de résoudre une homographie puis de rééchantillonner toute la photo pour n'en garder qu'un huitième. La zone voulue est lue directement, en interpolant les quatre coins puis les quatre pixels voisins. Le plus proche voisin coûtait trois bits — mesuré — sur un seuil qui n'en compte que douze.

**Limites mesurées.** Le régime « soigné » est le moins bon des cinq (33/40) : à 3 % de marge, la carte frôle le bord de la photo, et l'inondation du fond depuis les bords a peu de prise pour la contourner. Et un fond parfaitement uniforme privait le seuil de table de toute matière — corrigé, mais c'est le genre de cas qu'une photo réelle ne produit jamais et qu'un test de synthèse révèle immédiatement.

### Ce que ce banc ne voyait pas : l'éclairage

Ces cinq régimes décrivent tous ce que la **main** fait de travers, jamais ce
que la **lumière** fait. Ils ont donc laissé passer un défaut que la première
carte de papier a révélé d'un coup : photographiée sur une table éclairée de
côté, une carte plaçait la bonne empreinte au rang 146 sur 1 035, à 28 bits —
du bruit — alors que les cinq régimes affichaient 37 sur 40.

Le mécanisme est celui du seuillage global : le coin de table le plus sombre
passait sous le seuil qui sépare le carton du décor, touchait la carte, et la
recherche de forme réunissait les deux. La boîte englobante devenait l'image
entière. Le garde-fou d'aspect ne pouvait rien y faire — une photo de téléphone
en portrait (0,750) et une carte (0,716) se ressemblent à 0,034 près, pour une
tolérance qui en accepte 0,30.

**Le banc a donc été porté en Dart** (`app/tool/framing_bench.dart`), puisque
c'est le code Dart qui tourne sur l'appareil, et augmenté de trois régimes où
l'éclairage latéral est marqué — une lampe de côté, rien d'exotique. Sur
40 cartes :

| Régime | Seuil global (avant) | Seuil local (après) |
|---|---|---|
| cinq régimes d'origine | 179/200 | **181/200** |
| soigné + lampe | 11/40 | **36/40** |
| ordinaire + lampe | **0/40** | **38/40** |
| négligent + lampe | 3/40 | **36/40** |

Le remède est un **seuillage local** : chaque pixel se compare à la moyenne de
son voisinage, calculée par image intégrale, au lieu d'une constante tirée de
l'image entière. Le seuil suit alors l'éclairage au lieu de le subir. Vérifié
sur la carte de papier qui avait servi à découvrir le défaut : rang 1 sur
1 035, à 8 bits, avec 9 bits de marge sur le suivant.

**Trois enseignements valent au-delà de ce cas.**

Un banc ne mesure que ce qu'il fabrique. Celui-ci décrivait cinq façons de mal
cadrer et aucune de mal éclairer ; il aurait donné son aval à n'importe quelle
correction sans jamais voir le défaut. **Le même angle mort s'est reproduit sur
ce même banc** : les photos qu'il compose font 650 à 1100 px de large, quand
un téléphone en produit 4000, et le défaut de réduction décrit en §2 n'apparaît
qu'au-delà d'un facteur 3. Ce qu'un banc ne fabrique pas, il l'absout.

Une photo ne suffit pas à départager des corrections. Quatre approches ont été
mesurées sur cette seule carte : celle qui y obtenait le **meilleur** score
n'améliore rien au banc (16/120 contre 14). Le classement s'inverse dès qu'on
élargit l'échantillon.

Un sommet nominal n'est pas un réglage. `cardCeiling` culmine à 0,88 sur un
tirage et s'effondre sur un autre au grain doublé ; 0,84 est le seul point haut
des deux, et c'est lui qui est retenu.

Cette exigence n'était pas visible dans les mesures antérieures (100 % de reconnaissance, 0 faux positif) parce qu'elles partaient des `art_crop` de Scryfall, c'est-à-dire d'illustrations déjà découpées au pixel près. **Le protocole validait le comparateur d'empreintes, jamais la chaîne photo → illustration.**

Conséquence doctrinale : le cadrage guidé ne remplace pas la détection des bords de la carte. La note « la détection de contours ne devient nécessaire qu'au jalon 3 » est invalidée — elle l'est dès le jalon 2.

### Le format d'une carte dépend du jeu

Ce rapport était écrit **en dur, neuf fois**, toujours à la même valeur : celle
d'une carte Magic, 63 × 88 mm. Rien ne le signalait, et rien ne pouvait le
signaler, puisque les deux jeux couverts impriment sur le même carton — Riftbound
compris, dont une carte debout mesure 744 × 1039 au catalogue, soit 0,7160 contre
0,7159 pour le carton. `card_geometry.dart` porte désormais la table, jumelée à
`api/app/vision/card_geometry.py`.

**Ce n'est pas le contrôle d'aspect qui était en danger.** `aspectTolerance` vaut
0,30 ; un jeu qui s'écarterait de 4 % passerait sans encombre. Le point sensible
est ailleurs, en deux endroits qui n'ont, eux, aucune tolérance :

- **le repli du scan.** `scan_service.dart` transmettait le jeu à `findCard` et à
  `artHashCandidates`, mais pas à `cropToCardFrame` — le découpage centré sur
  lequel on retombe quand la détection renonce, soit 14 photos sur 320 au banc.
  La photo aurait donc été découpée au format Magic, puis le gabarit
  d'illustration du bon jeu appliqué à ce découpage faux ;
- **le cadre imposé à l'utilisateur.** `photo_source.dart` verrouille le
  recadrage guidé aux proportions d'une carte, et c'est ce cadre que l'empreinte
  lit. Or [`multi-game.md`](./multi-game.md) fait de ce recadrage une obligation
  pour Riftbound, l'illustration y primant sur le nom.

Dans les deux cas l'échec ne s'annonce pas : l'empreinte reste plausible, et la
reconnaissance rend une mauvaise carte ou aucune sans que rien n'explique
pourquoi. C'est le mode de défaillance que tout ce chapitre existe pour éviter.

**La parité Dart ↔ Python est verrouillée mécaniquement**, et c'est nouveau.
`api/tests/test_card_geometry.py` **relit le fichier Dart** et compare les deux
tables, clé par clé et valeur par valeur. Un test qui recopierait les valeurs à
la main ne verrouillerait rien : il divergerait en même temps que le module qu'il
surveille. L'intention figurait de longue date dans `art_box.py` — « `test_art_box.py`
verrouille cette parité en relisant les valeurs du fichier Dart » — sans qu'aucun
fichier ne la porte.

**Ajouter un jeu sans ses proportions retombe sur celles de Magic**, et c'est
délibéré : refuser de scanner serait pire que scanner de travers. Ce sont deux
tests qui empêchent d'y arriver par accident — l'un vérifie que tout jeu déclaré
dans `Game` figure dans la table, l'autre que les deux tables se correspondent.

**Vérifié inchangé, au banc et non par raisonnement.** Après le chantier, les
mêmes 40 cartes × 8 régimes rendent exactement les chiffres publiés plus haut :
14 abandons, 181 reconnues sur les 200 photos sans lampe, 110 sur les 120 à
lampe. La valeur retenue étant la même expression littérale, l'invariance était
attendue — la mesurer coûte trois minutes et la transforme en fait.

**Le tirage couché n'a pas pu être rejoué, pour une raison étrangère au code.**
`_cardImage` télécharge via `HttpClient` de `dart:io`, qui ne pose **aucun délai
d'expiration** et n'implémente pas de bascule IPv4 : le CDN qui sert les
illustrations Riftbound publie des adresses IPv6 que ce poste ne route pas, et le
banc attend indéfiniment là où `curl` répond en une demi-seconde. Le tirage Magic
échappe au défaut parce que ses quarante images sont déjà en cache local. C'est
une dette à part — un banc qui pend sans rien dire est un banc qu'on cesse de
lancer.

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

**L'impression servie suit la langue lue, non celle qu'on possède déjà.** Scanner une carte anglaise l'enregistrait en français — vécu deux fois sur la collection réelle, un Robot d'assaut d'HYDRA et une Kree Sentinel anglais rangés sur l'impression française possédée depuis la veille. L'ordre de préférence de `card_editions` plaçait « l'impression déjà possédée » avant la langue du nom trouvé, pour ne pas effacer le « déjà 2 » sous les yeux de l'utilisateur en lui servant une autre impression de la même case. L'intention était juste, le remède visait la conséquence : ce compteur ne devait pas dépendre de l'impression choisie. `owned` porte donc sur la **case** — toutes langues et finitions confondues, ce qui est déjà la doctrine du reste du produit —, et le critère fautif disparaît, devenu inutile. Conséquence voulue : les deux langues d'une même case font deux lignes de collection distinctes, chacune dans sa langue, que le classeur continue de compter ensemble puisqu'il compte des cases.

**Une édition est un couple (extension, numéro de collection), pas une impression.** `card_editions(oracle_ids, lang)` n'en rend qu'une ligne, servie dans la langue demandée quand elle existe, en anglais sinon ; `card_printings` et `sole_editions` s'appuient toutes deux dessus. C'est ce couple qui désigne l'objet physique : la langue du texte imprimé n'en change ni l'identité ni le prix — d'où le repli de cote déjà pratiqué par `print_price` entre impressions jumelles.

Le filtre de langue exclusif qui précédait supprimait bien le doublon fr/en, mais **effaçait une édition dès que Scryfall n'avait pas publié sa fiche localisée**. Ce n'est pas un cas de bord : sur « Marvel Universe », seules les cartes 1 à 40 sur 100 ont une fiche française, si bien qu'une carte française bien réelle (MAR #43) se voyait remplacée dans le sélecteur par une autre extension six fois plus chère. La préférence remplace le filtre — le doublon disparaît toujours, plus aucune édition avec lui.

Effet recherché : le nombre d'éditions d'une carte ne dépend plus de la langue interrogée. « Cette carte n'a qu'une seule édition » devient une affirmation stable, et `sole_editions` la sert pour tout un lot en un aller-retour. **12 863 cartes du catalogue sur 32 669 sont dans ce cas** — quatre sur dix. L'écran d'étalement les précise donc d'office : il n'y a rien à deviner quand il n'y a rien à choisir, et faire ouvrir vingt fois une liste d'un seul élément était le geste le plus coûteux de l'écran. La finition, elle, reste un choix — réglable à même la ligne, puisque c'est le seul que le catalogue ne peut pas faire à notre place.

**L'index d'empreintes porte une empreinte par illustration, pas par carte.** `pending_prints` retient une impression par `illustration_id` encore dépourvu d'empreinte. C'est ce qui rend une réédition à l'art changé reconnaissable — un scan sur quatre échouait sans cela, mesuré sur Farseek.

L'`illustration_id` de Scryfall évite l'explosion redoutée : commun à toutes les impressions qui réutilisent la même œuvre, il ramène les 166 998 impressions à **49 484 illustrations réellement distinctes**, toutes couvertes par l'index. Hacher les impressions aurait demandé trois fois plus de téléchargements pour le même résultat. Les 867 impressions sans `illustration_id` sont écartées : sans lui, rien ne dit si leur image a déjà été hachée.

Le départage privilégie l'anglais puis la sortie la plus ancienne, jamais le prix : un critère fondé sur la cote désignerait une impression différente au gré des fluctuations et ferait recalculer des empreintes déjà connues.

Restent 147 cartes sans aucune empreinte, toutes des jetons : 110 n'ont pas d'`illustration_id` chez Scryfall — encarts, biographies, jetons recto-verso — et les autres n'ont pas d'illustration exploitable.

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

**Le filtre par type est servi par la même fonction** (`p_types`), et non appliqué à
la liste reçue : restreindre après coup ne garderait que les terrains des vingt
premiers résultats, soit souvent aucun. Le filtre porte sur des sous-chaînes anglaises
de `type_line` ; une carte cumulant ses types (« Artifact Creature ») répond aux deux,
ce qui est la lecture juste. Les libellés français et la liste par jeu vivent côté
application (Magic en compte huit d'usage courant, Riftbound six), ce qui évite de
toucher au serveur chaque fois qu'un catalogue gagne un type.

**Le commandant identifie un deck mieux que sa provenance.** `decks.commander_oracle_id` est rempli pour les 190 précons Commander ; `deck_suggestions` remonte son nom — français quand la traduction existe — et son identifiant, ce qui permet d'ouvrir la carte en grand. La ligne affiche donc le commandant à la place du couple provenance/qualité, qui décrivait d'où venait la liste sans rien dire de ce qu'on va jouer ; l'attribution reste portée par le bandeau de fin de liste, où elle satisfait l'obligation contractuelle. `p_commander` cherche par nom via `card_search_names`, donc en français comme en anglais et avec la même tolérance aux fautes de frappe que la saisie de collection.

**Les suggestions se classent sur la complétion**, c'est-à-dire sur le chiffre que la ligne affiche. Elles l'étaient sur le nombre de cartes manquantes : « Forged In Stone » à 0 % passait devant « Token Triumph » à 1 % parce qu'il lui manquait deux cartes de moins, sur un deck plus court. Les deux critères sont défendables ; les mélanger ne l'est pas. Le nombre de cartes manquantes reste en second, entre deux decks également complets, puis le coût, puis le nom — l'ordre doit être total, deux pages successives ne devant pas se recouvrir.

**Le détail d'un deck montre aussi ce qu'on possède.** `deck_missing_cards` écartait les cartes déjà en collection, si bien qu'un deck entièrement constructible ouvrait sur une liste vide et qu'on ne pouvait jamais vérifier ce qu'on avait. Elle rend désormais toutes les cartes du deck, `missing = 0` distinguant les acquises, et l'interface les regroupe derrière un séparateur.

**Les terrains de base sortent du compte.** On ne les achète pas, on les prend dans la boîte : les compter comme des cartes à acquérir donnait 30 % de complétion à toute collection possédant une trentaine de terrains, quel que soit le deck — même chiffre pour un deck dont on a le thème et un deck dont on n'a rien, si bien que le classement n'apprenait plus rien. Mesuré sur une collection Marvel de 326 cartes : les decks Marvel étaient donnés à 21-25 % et passaient *derrière* des decks LOTR à 30 %, dont la totalité des cartes possédées était en terrains. Terrains de base exclus, les decks Marvel remontent en tête et Wakanda Forever tombe de 25/100 à 1/76 — le vrai chiffre.

Le critère est `type_line LIKE 'Basic Land%'`, qui couvre les versions enneigées sans attraper les terrains légendaires ni les bicolores : une fetchland vaut vingt euros et se cherche vraiment. L'exclusion porte sur **tout** le calcul — attendues, possédées, manquantes, coût — et non sur le seul pourcentage, deux nombres qui ne compteraient pas la même chose se contredisant sur la même ligne. `basic_lands` est rendu à part pour que l'interface puisse annoncer ce qu'elle ignore. L'identité couleur, elle, continue de se lire sur le deck entier : un deck qui ne contient de rouge que dans ses Montagnes reste un deck rouge.

**Le commandant possédé passe devant.** `deck_suggestions` rend `commander_owned` et sait s'y restreindre (`p_owned_commander`) ; à manque égal, les decks dont on tient déjà le général remontent. C'est la carte qui décide si un deck est un projet ou une liste de courses : sans elle, les quatre-vingt-dix-neuf autres ne forment pas un deck, et c'est souvent la plus chère de la liste.

**Le corpus ne porte pas la distinction précon / tournoi.** Un filtre la proposait, jusqu'à ce que la mesure montre que `tier` est parfaitement corrélé au format : les 190 decks Commander viennent tous de MTGJSON, les 838 Pauper et Modern tous de TopDeck.gg. Le filtre ne changeait donc rien en Commander et vidait la liste en Pauper. `deck_suggestions.p_tier` reste offert par le serveur — la distinction redeviendra utile le jour où une source apportera des listes de tournoi Commander, ou des précons dans un autre format — mais l'application ne l'emploie plus.

**Les suggestions se filtrent par couleur** (`deck_suggestions.p_colors`). L'identité couleur d'un deck est l'union de celle de ses cartes — la règle du Commander, qui vaut comme description ailleurs. La sélection est un **tamis** : seuls les decks dont l'identité tient dans les couleurs choisies sont proposés. Demander « rouge » et recevoir un deck à cinq couleurs n'aiderait pas qui voulait justement du mono-rouge. Les decks incolores restent proposés quoi qu'on demande, l'ensemble vide étant contenu dans tout autre — et ils se jouent effectivement partout.

**Une carte entre au catalogue pour deux motifs, et deux seulement** (`should_ingest`) :
parce qu'elle se joue dans un format couvert, ou parce qu'elle se range dans une boîte.
Les jetons relèvent du second — ils ne sont légaux nulle part, mais occupent une case de
classeur comme les autres, et les exclure rendait une collection physique impossible à
saisir en entier. Leur absence de légalité les tient d'elle-même à l'écart des
suggestions : le moteur travaille sur `legal_pauper`, `legal_modern` et
`legal_commander`, toutes fausses pour eux, si bien qu'aucun garde-fou supplémentaire
n'est nécessaire. Le type se lit dans `layout` (`token`, `double_faced_token`, `emblem`)
et non dans `type_line`, dont la convention « Token Creature » n'est pas garantie.

**Les jetons n'existent qu'en anglais.** Scryfall ne publie aucune impression localisée pour eux : 3 209 impressions, toutes anglaises, aucune avec un nom imprimé. Un jeton se saisit donc au clavier sous son nom anglais (« Soldier », « Treasure »), et la recherche par nom français ne le trouve pas. La reconnaissance par photo prend le relais — les 1 618 illustrations de jetons sont entrées à l'index d'empreintes, qui joue ici son rôle de recours quand la lecture du nom ne mène à rien.

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

## 7. Constructeur de decks

Bâtit un deck Commander de cent cartes avec la seule collection, autour d'un général choisi ou proposé.

**C'est une vue de l'onglet Decks, pas un écran à part.** Consulter le corpus et construire depuis sa collection répondent à la même question — « que puis-je jouer ? » — par deux chemins ; un sélecteur en tête d'onglet le dit, là où le premier essai en faisait une action ouverte par un bouton glissé parmi les filtres, que rien ne distinguait d'un filtre de plus. Le format se choisit avant le chemin et vaut pour les deux.

Le calcul vit **dans l'application**, en Dart pur : c'est une optimisation itérative, ce que SQL fait mal, et le résultat n'a pas à quitter le téléphone.

**Ce qu'il promet.** Pas un deck optimal — cela ne se démontre pas, cela se joue — mais un deck légal (cent cartes, un seul exemplaire de chacune, identité couleur du général respectée), cohérent avec les proportions des decks réels, et entièrement fait des cartes possédées. Les trois se vérifient ; l'optimalité, non.

**Les proportions viennent du corpus.** `api/app/measure/deck_anatomy.py` a mesuré les 190 précons : 38 % de terrains (écart interquartile de 2 points seulement), 29 % de créatures, 12 % de pioche, 6 % de rampe, 6 % de retrait, et une courbe de mana en six paliers. La sagesse populaire dit trente-sept terrains ; les decks réels en comptent trente-huit.

**Les trois formats sont couverts, mais ne se valent pas.** Chacun porte son gabarit, mesuré sur son propre corpus : Commander à 100 cartes en un seul exemplaire, Pauper et Modern à 60 avec quatre exemplaires autorisés et sans général — les couleurs se déduisent alors des deux mieux fournies de la collection, un deck qui touche à tout ne produisant jamais le mana qu'il lui faut.

La différence est la **fiabilité du gabarit**, et elle est mesurée. Les 190 précons Commander se ressemblent : leur médiane décrit un deck qui existe. Les 725 decks Pauper s'étalent de 25 à 40 % de créatures et de 23 à 43 % de sorts, les 113 Modern de même : ce sont des archétypes distincts — aggro, contrôle, combo — dont la médiane décrit un deck jouable mais qui ne ressemble à aucun d'eux. `BlueprintReliability` porte cette distinction et la vue l'annonce à l'utilisateur, plutôt que de présenter les trois comme équivalents. Les couvrir vraiment demanderait de regrouper les decks par famille avant de moyenner — un travail de classification, pas un réglage.

**L'algorithme remplit des cases.** À chaque tour, la carte retenue est celle qui comble le manque le plus criant, rôles et courbe confondus ; glouton, sans retour arrière. À cette échelle — deux cents cartes pour soixante places — un recuit n'achèterait rien de mesurable et le résultat cesserait d'être explicable. Le départage alphabétique rend la construction reproductible : deux appels sur la même collection donnent le même deck, sans quoi on ne saurait plus lequel on a noté.

**Les rôles se reconnaissent au texte oracle**, faute de mieux : aucun catalogue ne dit qu'une carte sert de retrait, mais son texte dit « Destroy target ». Grossier, et suffisant pour empêcher un deck sans retrait ni pioche — d'autant que les cibles du corpus ont été mesurées avec les mêmes motifs, ce qui rend les deux comparables. Les rôles se recouvrent volontairement : une créature qui produit du mana compte dans les deux.

**Ce qui manque est dit.** Le diagnostic compare l'obtenu aux cibles et ne signale que ce qui sort de l'écart interquartile mesuré : reprocher au résultat une liberté que les decks du corpus prennent eux-mêmes n'apprendrait rien.

**Le facteur limitant n'est pas l'algorithme, c'est le vivier.** Sur une collection de 205 cartes Commander, une paire de couleurs offre 72 sorts jouables pour 61 places : le constructeur en écarte onze, il ne choisit pas. La qualité d'un deck vient de la sélection, et la sélection suppose de pouvoir jeter. C'est à mesure que la collection approche les 2 000 cartes visées que les quotas commenceront à vouloir dire quelque chose.

**Deux limites mesurées** sur cette collection d'essai : les créatures dépassent leur quota (39 pour 29) parce qu'une collection qui en regorge en fait entrer par la porte de la courbe, et le palier à sept manas reste vide faute de cartes assez chères. Ni l'une ni l'autre ne se corrige en tordant l'algorithme.

### Plusieurs decks à la fois — des decks disjoints

Un deck seul répond à « que puis-je jouer ? ». Une **série** répond à « combien de decks puis-je poser sur la table en même temps ? », et c'est une autre question : les decks doivent être **disjoints**, un exemplaire employé par le premier ne pouvant pas resservir au second. `deck_series.dart` construit, retire du vivier ce que le deck a consommé, recommence.

**Le partage est glouton et séquentiel.** Le premier deck se sert dans toute la collection, le second dans ce qui reste : les decks sont de qualité décroissante. La série ne prétend donc pas répartir équitablement, elle prétend que chacun des decks rendus est complet et conforme au corpus. Un partage équilibré est un problème d'optimisation d'une autre nature, qu'on n'ouvrira pas sans l'avoir mesuré.

**Le refus a une mesure, pas une opinion.** Un deck est écarté quand il manque de cartes, ou quand un rôle s'écarte de sa cible au-delà de l'écart interquartile que porte `Quota.spread` — au-delà, donc, de la bande où tient la moitié des decks réels. Refuser sur un seuil inventé serait un jugement.

**Elle s'arrête en disant pourquoi**, et c'est la moitié de son utilité : le deck refusé est conservé (`DeckSeries.refused`). Répondre « pas de troisième deck » sans dire à combien de cartes il était n'apprend rien ; le rendre avec ses six cartes manquantes permet d'aller les acheter.

**Les généraux des decks suivants sont réservés**, et c'est un test qui l'a imposé avant qu'on y pense : sans réservation, le premier deck mange les créatures légendaires comme n'importe quelle créature, et la série s'arrête au tour suivant faute de général. On en met de côté autant qu'il reste de decks à faire, et pas davantage — chaque général réservé est une créature de moins pour le deck en cours.

**Les terrains de base ne sont jamais décomptés**, puisqu'ils ne viennent pas de la collection. Ce qui s'épuise et limite le nombre de decks, ce sont les sorts et les terrains non basiques.

**L'écran ne montre la série que lorsqu'elle a quelque chose à dire.** Une collection trop mince pour deux decks — le cas courant — retrouve exactement l'écran d'un deck seul : pas de sélecteur, pas de bandeau, rien de changé. Dès qu'il y a deux decks, un bandeau annonce le nombre, rappelle qu'aucune carte n'est partagée, dit ce qui a arrêté la série, et une puce par deck permet de passer de l'un à l'autre — un deck à la fois, quatre listes de cent cartes empilées étant illisibles. En Commander, le général choisi par l'utilisateur est **imposé au premier deck** : lui en substituer un autre au motif qu'il ouvre davantage serait le contredire sans le dire.

**Et quand la série refuse tout, c'est le deck ordinaire qui s'affiche**, avec ce qu'on peut lui reprocher. Refuser de montrer serait une régression : l'écran d'un deck seul a toujours montré les decks imparfaits, c'est même sa raison d'être — la série ajoute, elle n'enlève pas.

**Le vivier décidera, pas l'algorithme**, et le chiffre du paragraphe précédent dit déjà à quoi s'attendre : 72 sorts jouables pour 61 places, sur une paire de couleurs. Un seul deck épuise presque le vivier ; un second deck Commander complet suppose une collection sensiblement plus fournie. La série répondra donc souvent « un seul », et c'est une réponse juste — pas une panne.

**Le deck est jetable.** Rien n'est enregistré : on construit, on lit, on recopie, on ferme. Conserver les decks demanderait une table, un écran pour les relire et de décider ce qu'il advient d'un deck quand la collection change — un produit à lui seul, qu'il vaut mieux bâtir une fois qu'on saura si le résultat mérite d'être gardé.

`my_buildable_cards` sert la collection entière et d'un coup, avec le texte oracle que la page de collection ne porte pas. La pagination n'a pas de sens ici : on ne choisit pas quelles cartes retenir en n'en voyant qu'un vingtième.

---

## 8. Parcours de livraison

| Jalon | Contenu |
|---|---|
| **1** | Collection par saisie texte avec autocomplétion, valorisation, matching et suggestions — **en Pauper**. Boucle de valeur complète, sans vision. |
| **1b** | Extension à Commander (précons MTGJSON) et Modern. Le moteur ne change pas : seules les légalités diffèrent, et Scryfall les fournit. |
| **2** | Reconnaissance d'une carte à la fois : photo et caméra. |
| **3** | Étalement multi-cartes. |
| **4** | Saisie vocale, feuilletage temps réel. |

Le jalon 1 prouve la valeur du produit avant tout investissement dans la vision, qui concentre le risque et la charge de travail.

### La barre du haut porte une information, pas un titre

« Ma collection » écrit au-dessus de la collection n'apprend rien : la barre de navigation le dit déjà, en surbrillance. Cette place revient donc à ce que chaque onglet a de plus utile à montrer d'un coup d'œil, collé au bord droit — l'ancrage constant est ce qui rend la valeur lisible sans la chercher.

| Onglet | Ce qui s'affiche | Pourquoi |
|---|---|---|
| Ajouter | Les trois entrées non clavier : étalement, dictée, visée | Elles occupaient la ligne du champ, qu'elles rétrécissaient d'un tiers ; en haut, elles deviennent les entrées de l'onglet |
| Collection | Le nombre de cartes | Le poids de la collection, la seule donnée qu'on veut voir sans agir |
| Decks | Préconstruits / Construire | C'est le mode de l'onglet ; sous les filtres de format, il passait pour un filtre de plus |
| Compte | Nom d'usage et adresse | Savoir quel compte est ouvert, sans photo ni décor |

**Chaque information n'existe qu'à un endroit.** Le bandeau de totaux de la collection et le bloc d'identité du compte disaient ce que la barre du haut dit désormais ; les garder aurait volé une bande de hauteur pour redire la même chose.

**Le premier onglet s'appelle « Ajouter », non « Rechercher ».** On n'y vient pas pour consulter le catalogue mais pour faire entrer une carte dans sa collection : la recherche est le moyen, pas la fin. Ses filtres de type sont passés d'une rangée de puces débordante à un **menu à gauche du champ**, où ils annoncent la portée de ce qu'on va taper — plusieurs types restent cochables, l'étiquette nommant le premier et comptant les autres.

**Le choix de la finition précède l'action sur une case.** Une case dit ce qu'elle contient, pas ce qu'on tient en main : on peut posséder la version normale et vouloir ajouter la brillante, qui se range dans la même case mais ne vaut pas le même prix. Sans ce choix, aucun moyen d'ajouter l'autre finition depuis le classeur.

### Trois défauts que l'usage a révélés

**Certaines pages chargeaient sans fin.** Riverpod dispose un provider dès que plus personne ne l'écoute, et annule la requête en cours avec lui. Or une feuille est construite puis détruite plusieurs fois pendant un retournement — la face qui passe, celle qu'on découvre, celle qui revient : la requête était annulée puis relancée sans jamais aboutir, et la page restait en chargement pour toujours. Le serveur, lui, répondait en 0,2 s pour ces mêmes pages. `ref.keepAlive()` assorti d'un délai de trois minutes lève le blocage et évite de retélécharger une feuille qu'on vient de quitter, sans garder un classeur de 97 feuilles en mémoire une fois refermé.

**Une case a deux prix, pas un.** Le brillant et le normal s'y rangent ensemble mais se vendent du simple au triple : `my_binder_page` rend donc les deux, et la feuille d'action affiche celui de la finition qu'on s'apprête à ajouter. Un tiret dit l'absence de cote — un zéro ferait croire à une carte sans valeur.

**Le renversement du tri avait été perdu** en passant des puces aux menus. Re-choisir un critère inverse le sens, comme dans l'ancienne liste ; l'entrée déjà sélectionnée annonce ce qu'un second appui fera — « Dernière page d'abord », « Les moins chères d'abord », « De Z à A » — plutôt que de paraître inerte. Le champ fermé, lui, ne montre que le critère : la phrase y déborderait.

### Aucune requête ne peut plus attendre sans fin

**Un écran restait en chargement perpétuel, et la cause n'était pas le serveur.** Mesuré sous l'identité du compte, les quatre fonctions que l'application appelle au démarrage — étagère, totaux, pile à trier, suggestions de decks — répondent en moins d'une seconde, y compris lancées ensemble ; l'étagère revient en 0,13 s. Aucune n'était donc en cause.

Ce qui manquait était un **délai maximal**. Une connexion TCP qui meurt sans le dire — un VPN qui bascule, un Wi-Fi qu'on quitte pour les données mobiles — ne renvoie ni réponse ni erreur : le `Future` reste en attente indéfiniment, et l'indicateur de chargement avec lui. Sans message, sans bouton, sans fin. Le diagnostic avait déjà été posé pour l'index d'empreintes, qui porte son propre délai depuis ; il n'avait simplement jamais été généralisé, et **dix-neuf appels sur vingt en étaient dépourvus**.

`requestTimeout` (`app/lib/src/config/request_timeout.dart`) porte désormais la règle une fois pour toutes : vingt secondes, soit vingt fois la marge mesurée, et une extension `.timedOut()` posée sur chaque appel. L'index d'empreintes garde son propre délai de quinze secondes, justifié par sa mesure — 130 ms par page — mais lève la même exception.

**Un délai ne suffit pas** : il change un chargement sans fin en message d'erreur, ce qui reste une impasse. Les quatre écrans du classeur portent donc un bouton **Réessayer** qui redemande vraiment au serveur. Une panne de réseau n'est pas un état définitif ; sans ce bouton, il ne resterait qu'à quitter l'application.

Enfin, l'exception est **à nous** plutôt que le `TimeoutException` de Dart : l'interface affiche le message tel quel, et « TimeoutException after 0:00:20.000000 » ne dit rien à qui tient un téléphone. Le texte nomme la cause probable, qui est presque toujours le réseau.

### La roue chromatique

**Cinq pastilles posaient une question ambiguë.** Cocher le rouge voulait-il dire « des decks rouges » ou « des decks uniquement rouges » ? Le serveur répondait la seconde — `dc.colors <@ p_colors` —, si bien que demander du rouge écartait tous les bicolores rouges, ce que personne n'a jamais voulu en cochant une couleur. Et rien ne permettait de dire « du rouge, mais pas de bleu », qui est pourtant la question qu'on se pose devant sa collection : on connaît ses couleurs, et celles qu'on ne jouera pas.

La sémantique est donc renversée et dédoublée : `p_colors` liste les couleurs que le deck **doit** porter (`p_colors <@ dc.colors`), `p_banned_colors` celles qu'il ne doit **pas** porter (`NOT (dc.colors && p_banned_colors)`). Mesuré sur le corpus Commander : sans filtre 100 decks, rouge voulu 100, rouge voulu et bleu banni 50, rouge et blanc voulus 59.

**Trois états par couleur, atteints par appuis successifs** — indifférente, voulue, bannie — plutôt qu'un second contrôle ou un mode à choisir avant. Le troisième appui revient au départ.

**Le pentagone, et pas une rangée.** Les cinq couleurs se disposent au dos de chaque carte dans cet ordre depuis trente ans ; un joueur y lit les alliances et les oppositions sans réfléchir — les voisines s'allient, les opposées se combattent. Une ligne perd cette information que la forme donne gratuitement. Refermée, la roue est un disque de cinq quartiers qui montre l'état du filtre sans l'ouvrir, à la place d'une seule pastille au lieu de cinq.

Une phrase sous le pentagone dit ce que le filtre demande — « Decks contenant rouge, sans bleu ». La forme dit l'état couleur par couleur ; la phrase dit ce qu'on obtiendra, et c'est elle qui lève le dernier doute.

### Un seul contrôle pour « jusqu'où suis-je prêt à aller »

« Constructibles » et le plafond de budget répondaient à la même question mais se cochaient séparément : on pouvait demander un deck **sans rien à acheter** *et* un budget de cinquante euros — une combinaison dont la seconde moitié ne voulait rien dire. Les deux ont fondu dans un menu unique.

**« Constructible » n'est pourtant pas « zéro euro », et c'est pourquoi il ouvre le menu au lieu d'y figurer comme un montant.** Une carte manquante sans cote coûte zéro et manque quand même ; le cas exige qu'il ne manque *rien* (`p_max_missing = 0`), les autres plafonnent une dépense (`p_max_cost`). Le rapprochement est légitime — on choisit un effort — mais l'assimilation aurait été fausse, et 82 549 impressions sur 166 998 n'ayant pas de cote en euros, elle se serait vue.

## 9. Ce qui se comporte pareil d'un écran à l'autre

### Aucune requête n'attend sans fin, ni ne parle en Dart

`requestTimeout` (20 s) et son extension `.timedOut()` couvrent tous les appels
au serveur, et les écrans qui peuvent échouer portent un bouton **Réessayer**.

**Le défaut n'était pas une lenteur mais une absence** : une connexion morte ne
renvoie ni réponse ni erreur, et le `Future` restait en attente pour toujours —
alors que les quatre appels du démarrage répondent en moins d'une seconde,
lancés ensemble.

`.timedOut()` traduit aussi l'**injoignable** : « ClientException with
SocketException: Failed host lookup » s'affichait tel quel. Ne pas répondre et ne
pas être joignable sont deux pannes distinctes, et une seule se guérit en
attendant — `NetworkUnreachable` nomme le VPN, cause fréquente ici puisqu'un
tunnel impose son propre résolveur. On intercepte `ClientException` et non
`SocketException`, qui vient de `dart:io` et casserait la cible web.

L'index d'empreintes garde son propre délai (15 s, mesuré : l'index complet
arrive en 6,6 s depuis un poste filaire, soit environ 130 ms par page).


Chaque écran a été écrit à son tour, et chacun a inventé sa réponse à des questions que les précédents avaient déjà tranchées. Les divergences relevées ici n'étaient pas des choix : elles tenaient à l'ordre d'écriture. Un test par écran ne les aurait jamais vues — elles ne sont visibles qu'en comparant les écrans entre eux, ce que fait `test/src/features/ui_coherence_test.dart`.

### Toucher agit, maintenir montre

**La règle, sans exception.** Un appui simple exécute l'action propre à la surface — ajouter, choisir une édition, ouvrir une feuille. L'appui long ouvre toujours la même chose : la carte en grand.

Neuf surfaces agrandissent une carte. Huit le faisaient déjà au maintien ; une seule le faisait au **toucher** — la ligne du général sur une tuile de deck. C'était aussi la seule à porter un pictogramme d'aperçu, si bien que **la surface aberrante était celle qui enseignait la règle** : l'utilisateur en déduisait « je tape sur le nom », geste sans effet dans le classeur, les scans et les listes de courses. Le pictogramme a disparu avec l'exception, et la tuile entière porte désormais le couple canonique.

Trois écrans n'offraient aucun chemin vers la carte en grand, et ce sont ceux où il manquait le plus :

| Écran | Pourquoi il en avait besoin |
|---|---|
| Onglet **Ajouter** | C'est le point où l'on décide d'écrire une carte en collection, et la vignette de 56 × 42 ne lève pas un doute entre deux noms voisins |
| **Visée** (une carte photographiée) | La seule voie de saisie qui ajoute d'un appui et referme aussitôt : aucune liste à cocher ne rattrape une reconnaissance de travers |
| **Général du deck bâti** | Il était agrandissable à l'écran précédent, et les 99 autres cartes du même écran le sont ; le revoir obligeait à toucher « Changer », ce qui détruit le deck |

La **pile à trier** fait exception, et c'est motivé : son image est un substitut assumé — la vue élit une impression représentative par `oracle_id`, le français d'abord puis la plus récente. Agrandir une image arbitraire dans l'écran dont le seul objet est de décider *quelle* impression on tient donnerait du poids à ce qui n'en a pas. L'agrandissement y vit un cran plus loin, dans le sélecteur d'édition, sur le bon objet.

### Un seul aperçu, un seul objet, une seule sortie

Trois dialogues d'aperçu coexistaient, avec **deux contenus** et **trois façons de fermer**. `card_art_view.dart` les remplace tous.

**La carte entière, y compris dans le sélecteur d'édition**, qui montrait l'illustration recadrée. La question qu'on y pose est « laquelle de ces trente Foudre est-ce que je tiens ? » — et deux impressions partagent souvent la même illustration sans partager leur cadre, leur symbole d'extension ni leur numéro. Le recadrage effaçait précisément ce qui les départage. L'illustration y perd environ la moitié de sa taille apparente, l'art n'occupant que ~45 % de la hauteur d'une carte : c'est le prix assumé.

**Taper la carte referme, partout.** Le classeur enseignait ce réflexe ; ailleurs il ne produisait rien, et la zone de sortie se réduisait aux douze pixels de marge autour d'une image qui remplit l'écran. Le geste est capté sur le cadre entier, si bien que le chargement et les messages d'absence se referment de la même façon.

**Le cadre épouse la carte** — aux proportions du jeu affiché — et le reflet de diffraction suit la finition choisie : sans ce rapport, le reflet d'une brillante couvrait toute la boîte de dialogue.

### Les images de cartes tiennent sur l'appareil

L'`ImageCache` de Flutter est en **mémoire seule** et se vide à la fermeture : une feuille de classeur — neuf cases, plus les deux feuilles voisines préchargées — retéléchargeait vingt-sept images à chaque démarrage à froid, pour des pages qu'on rouvre tous les jours.

**Les commiter en assets est exclu** : ce sont des illustrations Wizards of the Coast servies par Scryfall, et le garde-fou 10 interdit de commiter toute donnée venue d'une source dans un dépôt public. Le cache sur l'appareil est la seule voie ouverte — c'est déjà ce que fait `art_index_cache.dart` pour l'index d'empreintes.

**Sans aucune dépendance ajoutée**, et c'est une contrainte assumée : `cached_network_image` tire `flutter_cache_manager`, `sqflite` et `path_provider`, soit deux greffons natifs de plus — il augmenterait la volatilité de build qu'on cherche à réduire. `image_store_io.dart` se contente donc de `dart:io` et de `Directory.systemTemp`, que l'embarqueur fait pointer sur le répertoire de cache privé de l'application ; le système peut le vider sous pression de stockage, ce qui est la sémantique voulue. Le web garde une coquille vide : son navigateur a déjà un cache HTTP, et `dart:io` n'y existe pas.

**Le nom de fichier est un condensé FNV-1a 64 bits**, seize caractères là où l'URL en fait cent trente et frôlerait la limite de chemin de Windows. Un condensé peut entrer en collision : **l'URL est donc réécrite en tête du fichier et vérifiée à la lecture**, de sorte qu'une collision produise un défaut de cache et jamais la mauvaise carte — la seule erreur qu'un cache d'images n'a pas le droit de commettre. Le répertoire est plafonné à 60 Mo, les fichiers les moins récemment touchés partant en premier.

Au passage, les huit `Image.network` répartis dans cinq fichiers sont devenus un seul `CardImage`. L'un d'eux — l'aperçu plein écran du classeur — n'avait aucun `errorBuilder` : une image morte y laissait la zone d'exception de Flutter.

### Le vocabulaire

| Notion | Ce qui s'écrit | Ce qui a disparu |
|---|---|---|
| Finition brillante | « Brillante », « Brillant », « brillante » | « Foil », « · foil » — deux mots pour la facette qui double le prix ne disaient pas qu'il s'agissait de la même |
| Choisir l'édition | `Icons.layers` / `layers_outlined` | `Icons.style`, qui est **d'abord** l'icône de l'onglet Collection, visible en permanence sous tous les écrans |
| Prix inconnu | « — » | « 0.00 € », qui se lit « gratuite » dans le seul écran où l'on décide d'un achat |

**Trois formes pour compter des exemplaires**, et chacune dit *quand* on regarde le nombre :

| Forme | Sens | Où |
|---|---|---|
| « Déjà N » | stock **avant** l'ajout, donc un avertissement anti-doublon | recherche, sélecteur d'édition |
| « ×N » | compte compact **posé sur une image**, faute de place pour un mot | case de classeur, résultat de recherche d'étagère |
| « N exemplaires » | la même chose en toutes lettres, quand la ligne a la place | feuille d'action d'une case |

### Trois impasses fermées

**Le retour du système ne refermait pas un classeur.** L'ouverture d'un classeur est un état Riverpod, pas une route : le geste de sortie le plus universel d'Android quittait donc l'application depuis la vue où l'on séjourne le plus. Un `PopScope` sur `BinderView` fait au retour ce que fait déjà la flèche de l'en-tête ; depuis l'étagère, il n'y a plus rien à refermer et le retour reprend son sens ordinaire.

**L'étagère vide renvoyait vers un écran supprimé** — « la vue Liste les montre toutes » — tout en masquant la seule sortie réelle, la tuile « À trier », qui n'était rendue que dans la branche non vide. C'est pourtant l'état du premier jour, ou celui d'une collection dictée : aucune carte n'a d'édition, donc aucune n'a de case. La tuile est désormais rendue dans les deux branches, et le message distingue « des cartes attendent leur édition » de « il n'y a pas encore de cartes » — nommer une sortie qui n'existe pas serait répéter la faute.

**Une panne d'enregistrement effaçait le lot d'un étalement.** `_error` portait deux sens — « la photo n'a rien donné » et « l'écriture a échoué » — et le second déclenchait le plein écran du premier : dix-sept lignes mesurées sur une photo réelle, leurs cases cochées, leurs quantités et les éditions choisies une par une disparaissaient d'un coup. La dictée gardait déjà les siennes pour la même erreur ; c'est son bandeau qu'on imite.

Enfin, l'onglet **Collection** n'avait aucun bouton **Réessayer** alors que le classeur en portait quatre — c'était sa porte d'entrée qui était un cul-de-sac. `StateMessage` (`lib/src/common/`) porte désormais le dispositif pour tout le monde. Et le classeur, seul écran muet quand les quatre voies de saisie accusent réception, dit maintenant ce qui vient d'arriver : corriger une édition envoie la carte dans le classeur d'une autre extension et vide la case sous le doigt — rien ne distinguait « c'est fait » de « la feuille s'est refermée toute seule ».

### Une écriture rend ce qu'elle a fait, non l'état qui en résulte

C'est la règle qui rend un geste annulable, et deux fonctions Postgres la violaient : elles rendaient un **total**, lequel mêle ce qu'on vient de faire à ce qui était déjà là. `set_collection_print` et `remove_from_collection` rendent désormais le nombre d'exemplaires **effectivement déplacés** ou **effectivement retirés** (migration 049).

**Le piège est la fusion.** Déplacer des exemplaires vers une édition qu'on possède déjà les additionne à la ligne existante (`ON CONFLICT … quantity = quantity + EXCLUDED.quantity`). Le cas mesuré en base, dans une transaction annulée : on possède 2 exemplaires d'une impression, on y corrige 1 exemplaire venu d'une autre — la ligne en porte 3. Rejouer le mouvement en sens inverse **sans quantité** en renverrait 3. La collection resterait juste en nombre total, mais deux cartes bien rangées auraient quitté leur classeur sans que rien ne le dise, et rien dans l'interface ne l'aurait signalé. Avec la quantité, la vérification rend exactement 2 et 1, l'état de départ.

**Le second défaut se voyait à l'écran.** Une case range ensemble le normal et le brillant : la feuille d'action propose donc « Retirer un exemplaire brillant » même sur une case qui n'en contient aucun. La fonction ne faisait alors rien — et l'accusé de réception affirmait pourtant un retrait. Le total rendu ne permettait pas de s'en apercevoir, puisqu'il compte la carte entière précisément pour ne pas laisser croire à zéro exemplaire quand une autre édition est en collection. Zéro exemplaire retiré se dit maintenant « Aucun exemplaire brillant à retirer ici », et n'offre rien à annuler : rajouter un exemplaire jamais retiré inventerait une carte.

**« Annuler » couvre les trois écritures qui font disparaître ce qu'on regarde** — retirer, corriger l'édition, ranger une carte de la pile à trier. Ajouter n'en a pas besoin : son inverse est le bouton juste en dessous. L'annulation s'exécute après la fermeture de la feuille, donc sur le `ProviderContainer` et non sur `ref`, dont l'état meurt avec le widget ; et la notification porte `persist: false`, faute de quoi Flutter la ferait attendre un balayage en recouvrant les commandes du classeur.

### La dictée précise l'édition, sans la demander

Deux écrans jumeaux — même liste de lignes, mêmes quantités, même « Ajouter (N) », même validation en bloc — n'enregistraient pas la même chose. L'étalement enregistrait l'édition et la finition de chaque carte ; la dictée n'enregistrait qu'un `oracle_id`, si bien que **tout ce qui passait par elle atterrissait dans la pile à trier**.

Ce n'était pas grave tant qu'on croyait qu'aucune carte n'était rangeable. Mais 274 des 278 lignes de la collection réelle sont précisées, et c'est `soleEditions` qui les a produites toute seule à l'étalement : la dictée était donc la seule voie qui fabriquait systématiquement du travail pour plus tard.

**Ce qui a été retenu — et ce qui a été écarté.** La parité complète (sélecteur d'édition + puce de finition sur chaque ligne) se heurte à la nature de l'écran : un modal s'ouvrirait pendant que `SpeechService` écoute encore, et les cartes s'accumuleraient derrière lui ; il faudrait suspendre l'écoute puis la reprendre. Or l'argument « mains occupées » plaide contre les **gestes**, pas contre le fait de **savoir**. La dictée appelle donc `soleEditions` sur ce qui vient d'être entendu — groupé par langue, au plus deux requêtes par énoncé — et retient l'édition des cartes qui n'en admettent qu'une. Elle l'**annonce** sur la tuile, comme l'exige le garde-fou §IV.8 pour une édition posée sans geste. Corriger reste l'affaire du classeur, et une panne du catalogue renvoie simplement à l'état d'avant : la carte part sans édition, jamais perdue.

**Un défaut trouvé en écrivant le test.** `dispose()` appelait `ref.read(speechServiceProvider).stop()`, ce que Riverpod refuse — « Using "ref" when a widget is about to or has been unmounted is unsafe », `ref` s'appuyant sur un `BuildContext` qui ne vaut plus rien. Quitter l'écran pouvait donc laisser l'écoute ouverte, et avec elle l'audio qui continue de sortir de l'appareil vers le moteur du système. Le service est désormais retenu dans un champ dès le montage, remède que Riverpod indique lui-même. L'écran de dictée n'avait aucun test ; il en a cinq.

### Ce qui a été vérifié et laissé tel quel

`cupertino_icons` ne figure dans aucune ligne de `lib/` ni de `test/`, et son retrait a pourtant été **annulé** : `flutter build web` avertit alors « Expected to find fonts for (MaterialIcons, packages/cupertino_icons/CupertinoIcons) ». La référence vient du framework, par les widgets Cupertino que Flutter monte pour la sélection de texte — chercher les occurrences dans le code du projet ne pouvait pas la voir. Le coût est nul de toute façon : la police est réduite de 257 628 à 1 472 octets par l'élagage d'icônes.

Côté Python, chaque dépendance porte désormais un **plafond de version majeure**. Le plancher seul en laissait franchir en silence — `Pillow>=11.0` était résolu en 12.3.0, `pytest>=8.3` en 9.1.1. Sans conséquence jusqu'ici, mais il existe un chemin, un seul, par lequel une bibliothèque Python atteint l'application sans passer par un plantage : `numpy` et `Pillow` calculent les empreintes que l'app recompare avec son jumeau Dart. Un arrondi qui change n'échoue pas — il écrit des empreintes valides mais **incomparables**, et la reconnaissance se dégrade en silence. C'est la seule panne de ce dépôt qu'un opérateur ne verrait pas devant sa commande. Le plafond ne remplace pas les vecteurs de parité, qui restent le vrai filet ; il évite que la montée se produise sans qu'on l'ait décidée.
