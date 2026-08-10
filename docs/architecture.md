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

**L'entrée est une étagère, pas un classeur.** 695 éditions au catalogue : n'y figurent que celles où au moins une carte est rangée, les autres seraient 690 classeurs vides. Mesuré sur la collection réelle : `msh` 216/453 cases (47,7 %), `tmsh` 15/27, `msc` 12/866, `mar` 3/100, `tmsc` 1/32. La page est demandée au serveur et non découpée côté application — une édition compte jusqu'à 866 cases, soit 97 feuilles.

Les cartes sans édition précisée n'ont **aucune case**, par construction. Elles ne sont pas perdues pour autant : `my_collection_summary` les compte, et le bandeau de l'onglet le rappelle.

**La case montre la carte entière, pas son illustration.** Une case de classeur contient une carte — son cadre, son nom, son coût, son numéro. N'en montrer que l'illustration donnait une planche-contact, jolie mais impossible à reconnaître comme sa propre collection. À trois par ligne le texte imprimé devient illisible, exactement comme dans un vrai classeur qu'on regarde de loin : c'est l'image qu'on reconnaît, pas le texte qu'on lit. L'URL de la carte entière est **déduite** de celle de l'illustration (`fullCardImage`), les tailles de Scryfall ne différant que par un segment de chemin — vérifié sur de vraies URL. La solution de rechange serait une colonne de plus sur 167 000 impressions et une réingestion complète ; elle redeviendra la bonne réponse si Scryfall change la forme de ses URL, ce qui casserait de toute façon `art_crop_url` du même coup.

**Le brillant se montre, il ne se dit pas.** Un symbole annonce qu'une carte est brillante ; un reflet le montre — et ce qu'on reconnaît d'un classeur ouvert, c'est justement une pochette qui accroche la lumière au milieu de cartes mates. `FoilSheen` pose un dégradé de diffraction **par-dessus** l'image, là où `foilDecoration` glisse le sien derrière une ligne de texte : sur une case pleine, un fond serait entièrement masqué.

### Ranger ou inventorier : deux régimes, une seule différence

**Le tri par numéro range, les autres inventorient**, et tout tient dans le sort des cases vides. Trié par **numéro**, le classeur montre les trous : la question posée est « que me manque-t-il ». Trié par **valeur** ou par **nom**, la question devient « mes cartes, de la plus chère à la moins chère » — et une case vide n'a alors ni valeur, ni nom, ni place dans un ordre qui ignore les numéros. Elle disparaît, et c'est ce que la demande implique. `BinderSort.keepsEmptyCells` porte cette distinction, et `my_binder_page` l'applique côté serveur : hors du rangement, les cases non possédées ne sont pas rendues.

**Le filtre de finition, lui, ne change pas de régime.** Restreindre au brillant ne sort pas du rangement : l'ordre reste le numéro, seule change la définition de « possédé ». Une case vide y signifie « je n'ai pas cette carte en brillant » — c'est la complétion d'un classeur de brillants, et les trous restent à dessein.

**Une page vide n'est pas une impasse.** Un filtre serré laisse des feuilles entièrement creuses : sur les 97 feuilles de `msc`, dont douze cases occupées, ouvrir à la première serait ouvrir sur du vide. `my_binder_first_page` dit où commencer — mesuré : page 42 pour `msc`, page 2 pour les brillants de `msh`. La question ne se pose que dans le régime de rangement ; ailleurs, la première page est pleine par construction.

**Le prix d'une case est celui de la plus chère de ses impressions.** L'impression représentative est choisie française pour son nom imprimé, or Scryfall ne cote pratiquement que l'anglais : trier par valeur ne triait rien, toutes les cases valant zéro. La case étant le même objet physique quelle que soit la langue, son prix se prend sur l'ensemble.

### La pile à trier

**Une carte sans édition précisée n'a aucune case**, par construction — ni extension, ni numéro. Elle était donc invisible dès que la collection se regardait en classeur, ce qui est devenu grave le jour où le classeur est passé en vue par défaut. `my_unsorted_pile` la montre.

**C'est une pile, pas un classeur**, et la fonction le dit : aucun numéro, aucune case vide, aucun taux de complétion. Elle est ordonnée **par entrée, la plus récente d'abord** — une pile se prend par le dessus, et ce qu'on vient de saisir est ce qu'on a encore en main ; trier par nom aurait enfoui la dernière carte scannée au milieu de l'alphabet. Toucher une carte ouvre le sélecteur d'édition et appelle `set_collection_print` : la pile se vide à mesure qu'on range, et l'entrée disparaît de l'étagère quand il ne reste rien.

L'illustration y est celle d'une impression **représentative**, faute d'impression désignée. C'est faux au sens strict — ce n'est pas forcément l'exemplaire qu'on tient — et sans conséquence : cette vue sert à reconnaître une carte pour lui donner son édition.

### Chercher une carte, et agir sur une case

**Chercher était la dernière chose qu'une liste faisait mieux qu'un classeur.** L'ordre des numéros ne répond pas à « où est ma Foudre ? » : il faudrait connaître l'extension et tourner les feuilles. `my_binder_find` rend donc la **page**, pas seulement la case, et le résultat y mène d'un geste. La recherche ne porte que sur les cartes possédées — chercher dans un classeur, c'est chercher parmi ses cartes ; proposer les 33 000 autres du catalogue ferait doublon avec la recherche de cartes, qui existe ailleurs.

**Toucher une case ouvre ce qu'on peut en faire** : ajouter un exemplaire, en retirer un, corriger l'édition. Ces gestes vivaient dans la liste, et le retrait n'existait nulle part ailleurs — les perdre en la supprimant aurait été une régression déguisée en simplification. Une case vide n'ouvre rien : il n'y a rien à retirer d'une carte qu'on ne possède pas.

### La liste triable a été supprimée

L'onglet Collection n'a plus qu'une vue. Chacun des services de la liste a trouvé un équivalent qui ne dénature pas le rangement :

| Ce que la liste faisait | Ce qui le fait |
|---|---|
| Trier par valeur, par nom | Les régimes de lecture du classeur |
| Filtrer sur la finition | Le filtre du classeur, trous conservés |
| Atteindre les cartes sans édition | La pile « à trier » |
| Chercher une carte par son nom | La recherche de l'étagère, qui donne la page |
| Ajouter, retirer, corriger l'édition | Les actions d'une case |

Ce qu'on y gagne est ce qu'aucune liste ne montrait : **les cases vides**. Le bandeau de totaux subsiste — il porte sur la collection entière et vient d'un appel distinct, si bien qu'aucun filtre ne le fait varier. `my_collection` reste en base, désormais sans appelant : la fonction est juste, et la ressortir coûterait moins que la réécrire.

### Les feuilles se tournent

**Un vrai retournement, pas un fondu ni un glissement.** Ce qu'on reconnaît d'un classeur qu'on feuillette, c'est la feuille qui pivote sur sa reliure : elle se soulève, montre sa tranche, laisse voir la suivante par-dessous, puis retombe en présentant son dos. Un fondu enchaîné donnerait la même information sans donner la même chose à voir. `page_turn.dart` porte la mécanique.

**La reliure est à gauche**, comme un classeur à anneaux ouvert à plat : glisser vers la gauche avance, vers la droite on revient. L'axe de rotation change avec le sens — bord gauche pour avancer, bord droit pour reculer — sans quoi la feuille pivoterait autour du mauvais côté et sortirait de la reliure. Le dos d'une feuille est la page suivante **en miroir** : sans cette inversion, la grille apparaîtrait à l'envers, première case à droite.

**La feuille se courbe, elle ne pivote pas d'un bloc.** La première version faisait tourner un plan rigide : la mécanique était juste, le résultat évoquait une carte à jouer qu'on retourne. La courbure fait toute la différence. Elle est obtenue en découpant la feuille en **huit lamelles verticales** dont l'angle croît de la reliure vers le bord libre — le bord se soulève avant le milieu, comme une page qu'on pince. Une déformation continue demanderait un maillage et un shader ; huit lamelles suffisent à ce que l'œil lise une courbe. Elle est **nulle aux deux extrémités et maximale à mi-course** (`sin`) : une page est plate quand elle repose. S'y ajoutent une ombre portée sur la feuille découverte, et un assombrissement qui suit le creux de la courbe — sans lumière, huit facettes ne montrent que des arêtes.

**Le geste pilote l'animation, il ne la déclenche pas.** La feuille suit le doigt et l'on peut revenir en arrière en cours de route ; elle ne bascule qu'au-delà du tiers de la largeur, ou plus tôt si le geste est vif (600 px/s). Un frôlement pendant qu'on regarde ne tourne donc rien. La page ne change qu'une fois la feuille retombée : la changer à mi-course rechargerait la grille sous le doigt.

**La charge est tenue par le voisinage, pas par la taille des images.** L'issue prescrivait les vignettes ; la carte entière a été préférée — c'est elle qu'on range dans une case — et le coût est absorbé autrement : seules les feuilles **immédiatement voisines** sont préchargées, et hors mouvement une seule feuille est construite. Précharger plus loin rapatrierait un classeur entier pour en montrer un neuvième.

**La feuille entière tient à l'écran.** Un rapport figé à 0,716 — la proportion d'une carte — débordait en hauteur et coupait la troisième rangée. Une feuille de classeur ne défile pas, elle se tourne : c'est donc la grille qui s'adapte à la place disponible, quitte à laisser de l'air sur les côtés. Dans le même but, les six puces de tri et de finition ont laissé place à **deux menus** sur une seule ligne, et la glissière permanente a disparu — elle coûtait la hauteur d'une rangée pour un geste rare. Traverser les 51 feuilles reste possible en touchant « Page 3 sur 51 ».

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

Ce que le sélecteur en fait est délibérément minimal : l'extension lue **remonte en tête**, annoncée par « Extension lue sur la carte : MSH ». Rien n'est coché ni ajouté d'office (garde-fou §IV.8) — sur une carte rééditée quarante fois, cet ordre est déjà ce qui rend le geste tenable, et l'annoncer permet de comprendre une lecture fausse au lieu de subir un ordre inexplicable. Les 17 % de couples ambigus restent départagés à la main : chaque édition portant le code lu est marquée, plutôt que de laisser croire que la première est la bonne.

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
