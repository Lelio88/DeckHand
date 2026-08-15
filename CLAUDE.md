# DeckHand — Contexte d'Opération et Garde-Fous Agentiques

Résolvez les problèmes sans introduire de régression ni de dette architecturale.

## I. Finalité

**Application** : DeckHand — transformer une collection **physique** de cartes en decks jouables.

**Objectif métier** : l'utilisateur saisit ses cartes (clavier, voix, photo, étalement) ; DeckHand valorise la collection, la range en classeurs, et propose des decks classés en deux familles — constructibles immédiatement, ou à quelques cartes près avec le coût de complétion. **Magic** est le jeu principal (Pauper, Commander, Modern ; Pauper prioritaire, seul format où une collection ordinaire produit des decks réellement complets). **Riftbound** boucle la même promesse, cloisonné par `cards.game` — voir [`docs/multi-game.md`](./docs/multi-game.md).

Usage privé (le propriétaire et quelques amis) sur un dépôt public. Ni produit commercial, ni service ouvert — **mais une collection peut être donnée à lire** : `collections.is_public` vaut `false` par défaut, publier est un geste explicite et révocable.

## II. Architecture

**Modèle** : monorepo à deux têtes, sans serveur intermédiaire. `app/` (Flutter, mobile + web) parle **directement** à Supabase ; `api/` ne contient que des jobs d'ingestion et d'indexation, lancés à la main. Le moteur de matching vit dans la base, en fonctions SQL. La reconnaissance de cartes s'exécute **embarquée dans l'app**.

**Détails complets** : [`docs/architecture.md`](./docs/architecture.md), qui sert d'index aux annexes.

Topologie rapide :
- `app/lib/src/features/` — par domaine : `card_search`, `collection`, `binders`, `decks`, `builder`, `scan`, `voice`, `printings`, `account`, `about`, `auth`
- `app/lib/src/common/` et `config/` — images en cache, délais de requête, jeu sélectionné ; `app/tool/` — bancs de mesure Dart
- `api/app/ingestion/` — un connecteur isolé par source ; `api/app/vision/` — empreintes ; `api/app/measure/` — bancs de mesure ; `api/app/twitch/` — bot de chat en lecture, lancé le temps d'un direct
- `supabase/migrations/` — fichiers horodatés, joués par `api/apply_migration.py`

## III. Pile Technologique

*Versions contraintes par `app/pubspec.yaml` et `api/pyproject.toml`. N'introduisez aucune dépendance alternative sans approbation.*

- **`app/`** : Flutter (mobile + web), Riverpod, `image` (empreintes), `image_picker` + `image_cropper`, `camera` (flux temps réel), `speech_to_text`, `google_mlkit_text_recognition`, `shared_preferences`, `flutter_svg`
- **`api/`** : Python 3.11+, httpx, psycopg, Pillow, numpy — **chaque contrainte porte un plafond de majeure** : `numpy` et `Pillow` sont le seul chemin par lequel une bibliothèque peut dégrader la reconnaissance en silence, une empreinte au calcul modifié restant valide mais devenant incomparable au jumeau Dart
- **Données** : Supabase — Postgres, Auth, Storage. Cloud uniquement, rien à déployer
- **Sources** : Scryfall (catalogue, prix), TopDeck.gg (decks), MTGJSON (précons), Riftcodex (catalogue Riftbound), TCGCSV (prix Riftbound, Yu-Gi-Oh et Pokémon), BCE (taux de change), YGOPRODeck (catalogue Yu-Gi-Oh), TCGdex (catalogue Pokémon), Limitless TCG (decks Pokémon), Wankuldex (catalogue Wankul, sous autorisation)

## IV. Garde-Fous non négociables

1. **EDHREC est interdit.** Ses conditions prohibent les requêtes automatisées et la republication. Ses endpoints JSON sont accessibles — ne jamais les appeler.
2. **Attribution obligatoire**, et **visible de qui regarde**. Chaque deck porte le crédit de sa source (`deck_sources`) ; l'écran « à propos » crédite l'ensemble ; toute page vue par des inconnus porte le sien en pied.
3. **Ne jamais paywaller ni repackager les données Scryfall.** La valeur ajoutée est le matching collection ↔ decks.
4. **Respecter les débits.** Scryfall ≤ 10 req/s, `User-Agent` descriptif, *bulk data* plutôt qu'appels unitaires. TopDeck.gg : 100 req/min.
5. **Les prix ne changent qu'une fois par jour.** Toute re-interrogation plus fréquente est du gaspillage.
6. **Un connecteur isolé par source de decks.** Aucune dépendance à une source ne remonte dans le cœur du produit.
7. **Secrets hors dépôt**, dans `../.deckhand-secrets/`. Les clés de publication viennent des secrets d'actions, jamais du dépôt.
8. **Toute carte identifiée passe par une confirmation utilisateur.** L'**édition**, elle, est déduite sans geste quand rien ne reste à choisir — désigner l'unique candidat n'apporte aucune information que la carte ne porte déjà. Dès que deux cases subsistent, l'utilisateur choisit.
9. **Une source sans conditions publiées reçoit celles de Scryfall** — `User-Agent` descriptif, débit bas, attribution visible. Vaut pour Riftcodex, TCGCSV, YGOPRODeck — dont le guide d'API tient lieu de conditions et **demande** le stockage local — TCGdex, dont le catalogue Pokémon est ingéré, et Limitless TCG, qui ne publie aucune condition (404 sur `/terms`). Ne jamais réhéberger d'illustration.
10. **Wankul est ingéré sous autorisation nominative de LINK DIGITAL SPIRIT**, éditeur du jeu, et par elle seule. Ses conditions (article 4) interdisent sinon « toute utilisation de robots, systèmes d'exploration de données et autres outils de collecte » — sans condition de finalité, donc y compris pour un usage privé. C'est le cas EDHREC du §IV.1, levé par un accord explicite : **le retirer remettrait la source hors la loi du projet**. **L'autorisation couvre aussi l'hébergement des illustrations, et c'est la seule source dans ce cas.** Son CDN refuse de les servir — `403 Hotlinking not allowed` sans `Referer`, avec un `Referer` étranger, et avec celui de `wankul.fr` : une politique, pas un en-tête à ajuster. Les rendus sont donc versés dans le bucket `card-art` (`app.ingestion.wankul_art_upload`) et `art_crop_url` pointe dessus. **Ce bucket n'est pas un cache générique** : un autre jeu n'y entre pas parce que son CDN a eu un hoquet, il y entre avec son propre accord — d'où le préfixe de jeu dans le chemin. Pour tous les autres, la règle reste de pointer l'URL de l'éditeur et de n'en rien garder (§IV.3, §IV.9). L'index d'empreintes, lui, ne dépend d'aucun des deux : il est bâti depuis un dossier local (`app.vision.local_index`). Débit de collecte : une requête toutes les deux secondes, le plus prudent du projet.
11. **Le dépôt est public** : aucune donnée de source n'est commitée (dumps, decklists, index d'empreintes sont des artefacts générés) ; les attributions figurent dans le `README.md` ; le `.gitignore` couvre tous les caches.
12. **Une migration jouée n'est jamais modifiée.** Pour corriger, en ajouter une nouvelle : un fichier édité n'est pas rejoué, et les environnements divergeraient en silence.

## V. Flux de Travail (Explore → Plan → Code → Verify)

1. **Explore** — lire `docs/architecture.md` avant toute intervention structurante, et les fichiers adjacents pour calquer les patterns.
2. **Plan** — pour toute évolution touchant le pipeline de vision, le moteur de matching, la RLS ou un connecteur de source, poser le plan avant d'écrire.
3. **Code** — TDD sur le moteur de matching et les parseurs (logique pure, testable sans réseau). **Fakes plutôt que mocks.**
4. **Verify** — aucun test ne dépend d'un appel réseau réel : les réponses des sources sont figées en *fixtures*. **Vérifier sous le rôle qui subira la règle** — la connexion d'ingestion est propriétaire et masque les oublis de `GRANT` comme de RLS. Une politique se vérifie **dans les deux sens** : le cas permis prouve qu'elle marche, le cas refusé qu'elle sert.
5. **Mesurer avant de régler.** Seuils, gabarits et proportions se tirent d'un banc (`api/app/measure/`), jamais de l'œil. Une décision d'écran se regarde **sur l'appareil** : la double page couchée a été jugée bonne sur les nombres, puis mauvaise dès la première capture.

**Auto-documentation** — tout nouveau fichier principal publie en tête un commentaire-doc : ce qu'il fait en une phrase, les choix non évidents **et leur motivation**, les invariants à préserver, un exemple canonique si l'API n'est pas évidente. C'est ce qui permet de reconstruire la rationale sans dépendre d'une doc externe périssable.

## VI. Commandes de Développement

```bash
# App — les --dart-define sont OBLIGATOIRES (valeurs dans ../.deckhand-secrets/supabase.env)
cd app && flutter run -d chrome --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...

cd app && flutter analyze && flutter test    # 591 tests
cd api && .venv/Scripts/python -m pytest     # 304 tests

# Ingestion — idempotente, saute ce qui n'a pas changé
cd api && .venv/Scripts/python -m app.ingestion.refresh            # Magic (--force, --skip-decks)
cd api && .venv/Scripts/python -m app.ingestion.riftcodex_ingest   # catalogue Riftbound
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_prices      # prix Riftbound (--force)
cd api && .venv/Scripts/python -m app.ingestion.ygoprodeck_ingest  # catalogue Yu-Gi-Oh (--force)
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_yugioh_prices # prix Yu-Gi-Oh (--force)
cd api && .venv/Scripts/python -m app.ingestion.tcgdex_ingest      # catalogue Pokémon (--force)
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_pokemon_prices # prix Pokémon (--force)
cd api && .venv/Scripts/python -m app.ingestion.topdeck_ingest --riftbound
cd api && .venv/Scripts/python -m app.ingestion.topdeck_ingest --yugioh   # decks Yu-Gi-Oh (4 formats rétro)
cd api && .venv/Scripts/python -m app.ingestion.limitless_ingest   # decks Pokémon (--days N, défaut 90)
cd api && .venv/Scripts/python -m app.ingestion.wankul_ingest      # catalogue Wankul (958 cartes, ~2 min)
# Index d'empreintes depuis un dossier local — Wankul refuse le telechargement
cd api && .venv/Scripts/python -m app.vision.local_index wankul <dossier>
# Vignettes vers le bucket card-art (--force pour reverser) — a jouer AVANT l'ingestion
cd api && .venv/Scripts/python -m app.ingestion.wankul_art_upload <dossier>
cd api && .venv/Scripts/python -m app.measure.wankul_art_window <dossier> # --terrains / --verticales
# Reprendre une course coupée : borne haute, pour ne pas repayer ce qui est acquis
cd api && .venv/Scripts/python -m app.ingestion.limitless_ingest --days 30 --before 2026-08-08

# Bot Twitch en lecture — tourne le temps d'un direct, rien à déployer
cd api && .venv/Scripts/python -m app.twitch                       # --game riftbound

# Bancs de mesure : arithmétique de l'écran Decks, puis coût d'une image caméra
cd api && .venv/Scripts/python -m app.measure.deck_math constructed riftbound
# De quoi un deck est fait — traits et zones propres à chaque jeu
cd api && .venv/Scripts/python -m app.measure.deck_anatomy --game yugioh
# Ce que l'index annonce quand il ne devrait rien dire — à rejouer à chaque jeu
cd api && .venv/Scripts/python -m app.measure.art_collisions        # --game <jeu> --sample N
# Où tombe, dans l'index réel, une empreinte relevée sur le terrain (`art_hash` du journal)
cd api && .venv/Scripts/python -m app.measure.art_probe <hex> --game riftbound --expect "<carte>"
cd app && dart run tool/frame_bench.dart   # durées réelles : --dart-define=DECKHAND_BENCH=true
# Détection de bords : 40 cartes × 8 régimes de cadrage et d'éclairage
cd api && .venv/Scripts/python -m app.measure.export_framing_set   # une fois, hors dépôt
cd app && dart run tool/framing_bench.dart              # --centered pour comparer
cd app && dart run tool/probe_photo.dart <photo> --game riftbound --out <dossier>
# Flux : détecter à chaque image, ou suivre le quadrilatère (#8)
cd app && dart run tool/stream_bench.dart   # --cards N --regime <nom> --noise N
# Pokémon (#28) : mesure seule, aucune ingestion — voir docs/multi-game.md §8
cd api && .venv/Scripts/python -m app.measure.pokemon_taxonomy       # familles et discriminants
cd api && .venv/Scripts/python -m app.measure.pokemon_art_window     # --group / --merge / --dump
cd api && .venv/Scripts/python -m app.measure.pokemon_energy_collisions

# Migrations — jouées par psycopg, le CLI Supabase exigeant un lien interactif
cd api && .venv/Scripts/python apply_migration.py ../supabase/migrations/<fichier>.sql

# Config d'authentification : relais d'envoi, adresses de retour, gabarits
cd api && .venv/Scripts/python push_auth_config.py             # --verifier pour lire
```

## VII. Maintenance documentaire

**Règle d'or** : le diff du code et celui de la doc correspondante vont dans le **même commit**.

| Modification | Fichier à mettre à jour |
|---|---|
| Nouvelle source, ou changement de ses conditions | `CLAUDE.md` §IV + `docs/architecture.md` §3 |
| Évolution du pipeline de reconnaissance | `docs/architecture.md` §2 |
| Changement du modèle de données ou d'une politique RLS | `docs/architecture.md` §4 |
| Évolution du classeur, du journal ou du partage | [`docs/collection-architecture.md`](./docs/collection-architecture.md) |
| Évolution des comptes, de la connexion ou du mot de passe | `docs/architecture.md` §4 |
| Accueil d'un jeu, ou ce qui dépend du jeu | [`docs/multi-game.md`](./docs/multi-game.md) |
| Nouveau gabarit d'illustration, ou nouvelle maquette | `api/app/vision/art_box.py` **et** `app/lib/src/features/scan/domain/art_box.dart` (jumeaux, un test lit le Dart) |
| Nouvelle impasse mesurée | Section « impasses » de l'annexe concernée |
| Nouveau secret / clé d'API | `../.deckhand-secrets/` (jamais dans le dépôt) |

## VIII. Contexte de Session

- **État** : **cinq jeux, dont quatre bouclent la promesse entière.** 32 918 cartes Magic et 165 547 impressions, 1 028 decks ; 929 cartes Riftbound, cotées et adossées à 2 500 decks ; 13 866 cartes Yu-Gi-Oh et 44 139 impressions, cotées à 92,7 %, 3 935 decks ; **20 964 cartes Pokémon**, cotées à 75,8 % et adossées à **23 574 decks** (602 121 lignes, aucune orpheline) — le plus gros corpus du projet, en cartes comme en decks. **958 cartes Wankul**, cinquième jeu, ingéré sous autorisation nominative de son éditeur : ni prix — le jeu n'a aucun marché secondaire coté —, ni decks — aucun corpus de listes n'est publié —, ni illustrations, dont l'accès direct rend un `403 Hotlinking not allowed`. La collection s'y saisit, s'y range et s'y compte ; elle ne s'y valorise pas. **Les cinq index d'empreintes sont pleins** : 32 808 Magic (les 110 manquantes n'ont aucune impression porteuse d'`illustration_id`, sans lequel rien ne dit si leur image a déjà été hachée), 19 326 Pokémon, 13 866 Yu-Gi-Oh, 958 Wankul, 929 Riftbound. **Les quatre jeux cotés savent construire un deck.** Collection réelle : 343 lignes, 451 exemplaires, aucune sans édition — dont 22 jetons, jouables nulle part. Compte `buton1@live.fr`, mot de passe dans `../.deckhand-secrets/supabase.env`.
- **Ce que Pokémon a coûté, et ce qu'il a appris.** Le catalogue vient du point GraphQL de TCGdex (8,95 Mio, 1,5 s) et non de ses 21 000 appels REST ; trois pièges muets s'y cachaient — le resolveur de `pagination` est cassé, un GET rend une page GraphiQL qui ressemble à une réponse, et `Accept-Language` ne fait rien, si bien que la première version a écrit **zéro nom français sans lever d'erreur**. L'identité est l'identifiant TCGdex et non le nom : **92 % des cartes partagent le leur** (112 Pikachu). Les prix viennent de TCGCSV, et leur rapprochement a failli faire un dégât muet — ma normalisation réduisait *Base Set* (1999) et *SM Base Set* (2017) à la même clé vide. Un rapprochement de noms ne produit pas que des manques, il produit des **faux couples** ; la règle est donc en trois temps, le nom propose (143/203), 26 alias tranchent (170/203), la date de sortie **oppose son veto** — distinction payée en mesure, les neuf POP Series portant une date égale au jour de la requête. Les decks viennent de Limitless : **la fenêtre de trente jours est couverte**, 334 tournois, 602 121 lignes, Standard à 99,4 %. Un dernier défaut y dormait, et il ne se voyait qu'en rapprochant deux nombres : le deck était identifié par son **classement**, or la source rend `placing: null` pour tout joueur non classé, si bien que tous partageaient une clé et s'écrasaient. Le connecteur comptait juste ce qu'il écrivait — 23 488 — quand la base n'en gardait que 18 041. La clé est désormais le pseudonyme, présent partout, unique dans un tournoi et **stable dans le temps** ; le corpus a gagné **5 533 decks sans une requête de plus**. **Un compteur d'écritures n'est pas un compteur de résultats** — seul le décompte des lignes en base les sépare. Le gabarit de deck est mesuré sur 17 295 listes et c'est le chiffre le plus net du projet — **60 cartes, écart interquartile 0,0** — avec trois familles à 6,7 points d'écart chacune (dresseurs 51,7 %, pokémon 33,3 %, énergies 15,0 %) et **aucune courbe**, `cmc` y portant les points de vie. Enfin les **sigles d'extension avaient trois causes et non une** : un parcours qui violait la priorité des gisements, un même code PTCGO porté par une extension et sa *Trainer Gallery*, et une annexe seule à porter le sigle de sa mère. Réglés — 49 267 codes indexés contre 43 361 ; sur le corpus entier il reste 45 sigles non résolus, largement dominés par `TRR`, qui coûtent 201 decks écartés (0,8 %).
- **Ce que Wankul a coûté, et pourquoi il ne boucle pas la promesse.** Cinquième jeu, et le premier ingéré **sous autorisation nominative** : ses conditions interdisent sinon toute collecte, sans condition de finalité — le cas EDHREC, levé par un accord explicite. Trois manques sont structurels et non des retards : **aucun prix** (le jeu se vend en direct, sans marché secondaire coté), **aucun deck** (nul corpus de listes publié), **aucune illustration** (`403 Hotlinking not allowed`, une politique et non une panne). Trois pièges muets s'y cachaient. Le champ **`orientation` ne dit pas comment la carte est imprimée** : `?orientation=horizontal` rend 40 cartes dont 13 sont debout, promos PGW confrontées à leur rendu de 751 × 1059 ; ce qui sépare les maquettes est la présence d'un rendu **paysage**. La **pagination est cassée** au-delà de la page 1 — 503 déterministe, `limit` plafonné à 100 — et le catalogue s'obtient en découpant par extension × effigie, 30 requêtes contre 162 par rareté. Enfin l'identité `extension:numéro` **fusionnait 15 cartes sur 958** : « Hors Série » agrège des sous-collections dont chacune recommence sa numérotation, `hors-serie:1` désignant quatre cartes. L'identité vient de l'identifiant de la source, comme chez Pokémon. **Les trois défauts ont été pris avant la première écriture définitive**, là où leurs équivalents Yu-Gi-Oh et Pokémon avaient coûté une réingestion complète.
- **Wankul est complet en base, et son index aussi — bâti sans télécharger une image.** Les 958 impressions et les 958 noms de recherche manquaient : la table `cards` était pleine, si bien que rien ne le signalait, mais aucune carte n'était trouvable à la saisie ni rangeable en classeur. Le CDN refusant tout (`403` sans `Referer`, avec un `Referer` étranger, **et avec celui de `wankul.fr`** — une politique, pas un en-tête à contourner), `app.vision.local_index` lit un dossier local et écrit les mêmes lignes qu'`index_builder`, sans réimplémenter un pas de la chaîne de calcul. Le lien fichier ↔ impression est l'**UUID que la source donne à chaque rendu** : 958 fichiers, 958 impressions, aucun orphelin. Deux pièges y attendaient — 308 masques holographiques qui sont des images valides et se seraient hachées sans rien dire, et `art_crop_url` qui désigne le rendu *paysage* d'un Terrain, absent du dossier : c'est `illustration_id` qui fait le lien.
- **Les Terrains : un quart de tour, deux maquettes — et la conclusion précédente était l'inverse.** Un seul quart de tour horaire redresse les 146, vérifié en les regardant toutes. Ce que l'image moyenne montrait — deux jeux de bandeaux symétriques — venait des deux **maquettes** (bloc de texte à 0,1700→0,4150 sur 77 cartes, à 0,6300→0,8750 sur 69) et non de deux sens de rotation ; le demi-tour conditionnel ajouté pour « recoller » la moyenne **introduisait** le résidu qu'il croyait supprimer, et trois tentatives s'y sont épuisées. Les deux maquettes ne sont pas un demi-tour l'une de l'autre — 0,045 d'écart —, ce qui oblige à deux cadres là où la reconnaissance essaie déjà les deux quarts de tour. Elles se lisent sur l'image (force des traits × platitude des bandeaux ; pire cas 1,28, les douze plus serrés vérifiés à l'œil). **Une leçon de méthode** : le gabarit vertical repris sur 812 cartes au lieu de 11 est *moins bon* (1,04 % d'annonces fausses contre 0,84 %) — il mord sur le pavé de texte, identique partout. Un échantillon plus grand ne fait pas un meilleur gabarit. Détail : [`docs/multi-game.md`](./docs/multi-game.md) §9.
- **Les vignettes Wankul sont hébergées, et c'est la seule source dans ce cas.** Le CDN de l'éditeur refuse de servir ses images à qui que ce soit ; l'accord couvrant l'hébergement, les 958 rendus sont versés dans le bucket `card-art` en deux paliers — 1 916 objets, 65,1 Mio — et `art_crop_url` pointe dessus. **Aucune ligne de Dart n'a été écrite** : le chemin calque celui de Scryfall (`/normal/` ↔ `/small/`), que `previewCardImage` sait déjà échanger pour charger une vignette légère avant la grande. L'URL est **dérivée d'`illustration_id`**, donc l'ingestion la recalcule sans rien demander au bucket — sans quoi une prochaine course l'aurait fait retomber sur le CDN bloqué. Un défaut trouvé en regardant ce qui avait été versé : une boîte fixe de 146 × 204 écrasait les 146 Terrains, qui sont couchés — deux proportions pour la même carte, posées l'une sur l'autre sans transition. Le palier léger contraint désormais le **plus grand côté**.
- **Ce qui reste dû sur Wankul** : une **carte de papier** — le format 63 × 88 est présumé, seule entrée de `CARD_ASPECTS` sans vérification sur carton — et un **regard sur l'appareil** : les Terrains sont versés couchés, donc recadrés au centre par `BoxFit.cover` dans une case de classeur, comme un champ de bataille Riftbound. C'est un choix de mise en page qui n'a pas encore été vu à l'écran.
- **Ce qui reste dû sur Pokémon** : **aucune carte de papier n'a été photographiée**, et le propriétaire n'en a pas — cette validation dépendra d'un tiers, comme les huit cartes Riftbound. Un écart y attend d'être mesuré : le carton fait 63 × 88 mm (0,7159) quand le rendu TCGdex fait 600 × 825 (0,7273), 1,6 % — les fenêtres de #28 ayant été mesurées sur les rendus, elles peuvent glisser d'environ 1 % en hauteur sur une photo. Trop peu pour manquer une illustration, assez pour valoir la vérification.
- **Ce qui reste dû sur Yu-Gi-Oh** : le carton, **mais le propriétaire n'a aucune carte de ce jeu** — validation indisponible ici, pas tâche en attente. Le trou est plus étroit qu'il n'y paraît : le défaut de réduction révélé par le carton Riftbound vivait dans du code partagé sans paramètre de jeu, et l'orientation ne concerne que les jeux imprimant en travers, ce que Yu-Gi-Oh ne fait pas.
- **Plusieurs decks à la fois.** Le constructeur répond désormais à « combien de decks puis-je poser sur la table en même temps ? », et la réponse exige des decks **disjoints** — un exemplaire employé par le premier ne peut pas resservir au second. Le critère de refus n'est pas un seuil inventé : c'est `Quota.spread`, l'écart interquartile du corpus, au-delà duquel un deck sort de la bande où tient la moitié des decks réels. La série **s'arrête en disant pourquoi** et conserve le deck refusé, parce que « il manque six cartes » se règle en achetant six cartes là où « pas de troisième deck » ne se règle pas. Un test a imposé de **réserver les généraux des decks suivants** : sans cela, le premier deck mange les créatures légendaires et la série s'arrête faute de général. Sur la collection réelle en Pauper, la réponse est **trois decks**, un quatrième à deux cartes près. L'écran ne montre la série que lorsqu'elle a quelque chose à dire — une collection trop mince retrouve exactement l'écran d'un deck seul.
- **L'étagère groupe les classeurs par sortie.** « Marvel Super Heroes » produit quatre extensions — boosters, decks Commander, jetons de chacune — que l'étagère alignait au même niveau alors que `card_sets.parent_set_code` porte la parenté depuis l'ingestion et n'était **lu nulle part**. Grouper n'est pas fusionner : les numérotations se chevauchent, le n° 1 vaut trois cartes différentes, et trois cartes ne tiennent pas dans une case. Les jetons se rangent en dernier et portent une pastille — aucune de leurs cartes n'est légale dans un format construit, vérifié sur les vingt-deux exemplaires possédés.
- **Ce que l'appareil a montré et que rien d'autre ne voyait.** L'installation sur le téléphone a rendu **deux défauts en deux captures** : `$copies` s'affichait littéralement, cassé en trois devant chaque carte — le dollar était échappé, invisible en Commander où aucune carte n'a deux exemplaires, massif en Pauper —, et le sélecteur de mode débordait de 6,2 px, la boucle ajoutant un séparateur après la dernière puce. Puis deux chevauchements sur l'étagère, corrigés de la même façon. Ni `flutter analyze` ni les tests ne mesurent une largeur. **Le téléphone est joignable en adb** (`A069`, sans fil) : installer un APK, lancer l'app, capturer et regarder est à portée, et doit être fait pour toute décision d'écran.
- **La route du mot de passe existe enfin, et il lui manque un facteur.** Trois manques se tenaient : un mot de passe saisi une seule fois à l'aveugle, une adresse que rien ne vérifie, aucune récupération — une frappe de travers à l'inscription rendait le compte irrécupérable, avec la collection dedans. L'inscription demande désormais deux saisies, l'œil permet de relire, et « Mot de passe oublié ? » ouvre la route calquée sur DewDrop : lien `deckhand://reset-password`, session temporaire, écran de remplacement. La réponse **ne dit jamais si un compte existe**. Détail et pièges : `docs/architecture.md` §4. **Le courriel part par Brevo**, sur le compte de DewDrop — le relais de démonstration de Supabase plafonnait à deux courriels par heure et n'écrivait qu'aux membres du projet. Partager le compte ne laisse **aucune trace chez le destinataire** : nom d'expéditeur, adresse, sujet et corps sont réglés par projet Supabase, l'identifiant du relais n'apparaissant jamais dans le message. Ce qui est partagé tient à l'administration seule — quota, journaux, révocation commune.
- **Publication Play Store** : préparée, pas engagée. Politique de confidentialité **en ligne** (<https://lelio88.github.io/DeckHand/privacy.html>, servie par le build web dont le workflow `pages.yml` publie `app/build/web` — ne jamais basculer Pages sur `/docs`, cela casserait le partage de collection). Signature de release câblée sur `android/key.properties`, absent du dépôt. Compte de démonstration dédié dans le coffre (`DECKHAND_DEMO_EMAIL`), 30 cartes et 23 classeurs — **`DECKHAND_TEST_EMAIL` n'en est pas un** malgré son nom, c'est le compte du propriétaire. Procédure et textes de fiche : [`docs/publication-play.md`](./docs/publication-play.md). Restent le keystore, la création de la fiche, les captures et l'icône.
