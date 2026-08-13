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
- **Sources** : Scryfall (catalogue, prix), TopDeck.gg (decks), MTGJSON (précons), Riftcodex (catalogue Riftbound), TCGCSV (prix Riftbound et Yu-Gi-Oh), BCE (taux de change), YGOPRODeck (catalogue Yu-Gi-Oh)

## IV. Garde-Fous non négociables

1. **EDHREC est interdit.** Ses conditions prohibent les requêtes automatisées et la republication. Ses endpoints JSON sont accessibles — ne jamais les appeler.
2. **Attribution obligatoire**, et **visible de qui regarde**. Chaque deck porte le crédit de sa source (`deck_sources`) ; l'écran « à propos » crédite l'ensemble ; toute page vue par des inconnus porte le sien en pied.
3. **Ne jamais paywaller ni repackager les données Scryfall.** La valeur ajoutée est le matching collection ↔ decks.
4. **Respecter les débits.** Scryfall ≤ 10 req/s, `User-Agent` descriptif, *bulk data* plutôt qu'appels unitaires. TopDeck.gg : 100 req/min.
5. **Les prix ne changent qu'une fois par jour.** Toute re-interrogation plus fréquente est du gaspillage.
6. **Un connecteur isolé par source de decks.** Aucune dépendance à une source ne remonte dans le cœur du produit.
7. **Secrets hors dépôt**, dans `../.deckhand-secrets/`. Les clés de publication viennent des secrets d'actions, jamais du dépôt.
8. **Toute carte identifiée passe par une confirmation utilisateur.** L'**édition**, elle, est déduite sans geste quand rien ne reste à choisir — désigner l'unique candidat n'apporte aucune information que la carte ne porte déjà. Dès que deux cases subsistent, l'utilisateur choisit.
9. **Une source sans conditions publiées reçoit celles de Scryfall** — `User-Agent` descriptif, débit bas, attribution visible. Vaut pour Riftcodex, TCGCSV, YGOPRODeck — dont le guide d'API tient lieu de conditions et **demande** le stockage local — et TCGdex, interrogé par les seuls bancs de mesure Pokémon. Ne jamais réhéberger d'illustration.
10. **Le dépôt est public** : aucune donnée de source n'est commitée (dumps, decklists, index d'empreintes sont des artefacts générés) ; les attributions figurent dans le `README.md` ; le `.gitignore` couvre tous les caches.
11. **Une migration jouée n'est jamais modifiée.** Pour corriger, en ajouter une nouvelle : un fichier édité n'est pas rejoué, et les environnements divergeraient en silence.

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

cd app && flutter analyze && flutter test    # 480 tests
cd api && .venv/Scripts/python -m pytest     # 221 tests

# Ingestion — idempotente, saute ce qui n'a pas changé
cd api && .venv/Scripts/python -m app.ingestion.refresh            # Magic (--force, --skip-decks)
cd api && .venv/Scripts/python -m app.ingestion.riftcodex_ingest   # catalogue Riftbound
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_prices      # prix Riftbound (--force)
cd api && .venv/Scripts/python -m app.ingestion.ygoprodeck_ingest  # catalogue Yu-Gi-Oh (--force)
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_yugioh_prices # prix Yu-Gi-Oh (--force)
cd api && .venv/Scripts/python -m app.ingestion.topdeck_ingest --riftbound
cd api && .venv/Scripts/python -m app.ingestion.topdeck_ingest --yugioh   # decks Yu-Gi-Oh (4 formats rétro)

# Bot Twitch en lecture — tourne le temps d'un direct, rien à déployer
cd api && .venv/Scripts/python -m app.twitch                       # --game riftbound

# Bancs de mesure : arithmétique de l'écran Decks, puis coût d'une image caméra
cd api && .venv/Scripts/python -m app.measure.deck_math constructed riftbound
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
```

## VII. Maintenance documentaire

**Règle d'or** : le diff du code et celui de la doc correspondante vont dans le **même commit**.

| Modification | Fichier à mettre à jour |
|---|---|
| Nouvelle source, ou changement de ses conditions | `CLAUDE.md` §IV + `docs/architecture.md` §3 |
| Évolution du pipeline de reconnaissance | `docs/architecture.md` §2 |
| Changement du modèle de données ou d'une politique RLS | `docs/architecture.md` §4 |
| Évolution du classeur, du journal ou du partage | [`docs/collection-architecture.md`](./docs/collection-architecture.md) |
| Accueil d'un jeu, ou ce qui dépend du jeu | [`docs/multi-game.md`](./docs/multi-game.md) |
| Nouvelle impasse mesurée | Section « impasses » de l'annexe concernée |
| Nouveau secret / clé d'API | `../.deckhand-secrets/` (jamais dans le dépôt) |

## VIII. Contexte de Session

- **État** : 32 918 cartes Magic et 165 547 impressions, 1 028 decks ; 929 cartes Riftbound, cotées et adossées à 2 500 decks ; 13 866 cartes Yu-Gi-Oh et 44 139 impressions, cotées à 92,7 % et adossées à 3 935 decks — **le plus gros corpus des trois**. Les trois jeux bouclent la même promesse. **Les trois index d'empreintes sont pleins** — 929 Riftbound, 13 866 Yu-Gi-Oh, et 32 808 Magic sur 32 918 : les 110 manquantes n'ont aucune impression porteuse d'`illustration_id`, sans lequel rien ne dit si leur image a déjà été hachée, et sont écartées par construction. Collection réelle : 343 lignes, 451 exemplaires, aucune sans édition. Compte `buton1@live.fr`, mot de passe dans `../.deckhand-secrets/supabase.env`.
- **Troisième jeu** : #22 relève les sources d'autres TCG, conditions en main — Wankul est **refusé** faute d'autorisation écrite. Découpé en cinq sous-issues, #24 à #28. **Toutes sont faites.** #24 : le format d'une carte était écrit en dur **neuf fois**, il est désormais une propriété du jeu — ce qui cédait n'était pas le contrôle d'aspect mais le cadrage de repli et le cadre imposé à l'utilisateur, les deux endroits sans tolérance. #25 : **le catalogue Yu-Gi-Oh est en base** — 13 866 cartes sur carton, 44 139 impressions, 11 504 noms français, en 29 secondes. Ce jeu a coûté moins cher que Riftbound sur chaque poste : identité donnée (le passcode imprimé sur la carte), **zéro homonyme**, français servi, et deux gabarits mesurés par recoupement à 0,001 près dont le choix repose sur un contrat de la source et non sur une heuristique. Il est aussi le premier à n'imprimer pas en 63 × 88, ce qui rend le paramétrage de #24 éprouvé plutôt que théorique. #26 : **les prix sont en base**, 40 918 impressions sur 44 139. Le catalogue les servait pourtant déjà en euros, ce qui promettait d'économiser TCGCSV et la conversion BCE — mesuré, c'est un plancher et non un prix de marché : là où les deux existent, le prix par impression vaut 20 fois le prix par carte en médiane, et l'écart ne suit pas la rareté, ce qui écarte l'explication naturelle. Le rapprochement tient à un identifiant composite — numéro d'impression et rareté — et non à une ressemblance de noms. #27 : **le corpus de decks est en base**, 3 935 listes. Le format que #25 avait déclaré sur la foi de son nom, `Advanced`, porte 3 decklists quand Edison en porte 3 069 : 97 % du corpus est dans les formats rétro, ce qui sert le produit plutôt que de le desservir — un pool figé est fait de cartes disponibles et bon marché, exactement l'argument qui fait du Pauper le format prioritaire de Magic. Deux défauts muets y sont tombés : les libellés de zone sont saisis à la main (`#main`, `Deck - 41 Cards`), et les lire strictement coûtait 305 decks sans lever une erreur ; et une carte rééditée porte un second passcode, ce qui rendait Monster Reborn et Cyber Dragon introuvables et aurait enregistré 93 decks **amputés**, donc plus complets qu'ils ne sont. #28 : **Pokémon est mesuré, et rien n'en est ingéré** — c'était un chantier de mesure, dont le résultat devait dire si un quatrième jeu est tenable. Il l'est, et moins cher que redouté. La crainte portait sur le bon endroit et la réponse est l'inverse : le discriminant n'est pas la rareté mais **cinq champs à vocabulaire fermé** (`serie`, `localId` vs `cardCount.official`, `category`, `suffix`/`stage`, `energyType`), et une règle par rareté laisserait 1 783 cartes non isolables. Deux d'entre eux démentent le relevé d'ouverture : la famille à fenêtre haute a bien un discriminant structuré, et `category` est un axe qu'on ne voyait pas — la fenêtre d'un Dresseur s'arrête 40 px plus bas que celle d'un Pokémon, et les mêler faisait dériver l'arête haute de 32 px entre deux tirages. La méthode Yu-Gi-Oh est fermée (aucune illustration détourée) ; l'écart-type entre cartes aussi, et c'est l'impasse propre au jeu — **la couleur du cadre suit le type du Pokémon**, donc le cadre varie autant que l'illustration. Ce qui tranche est le **gradient de l'image moyenne** : fond à 5, traits de fenêtre à 63. Résultat : **une seule fenêtre** (0,0850 · 0,1055 · 0,9200 · 0,4727) sert le Pokémon encadré **de 2003 à 2024** — les quatre gabarits d'époque mesurés sont interchangeables en bits — et elle sert aussi les cartes à fenêtre haute *mieux que la leur* (20 bits de marge contre 19). Le Dresseur garde le sien. La famille « pleine page » n'est pas une famille : `Shiny rare` y est un cadre standard, `Special illustration rare` n'a aucune arête. Les énergies de base sont **exclues, chiffres à l'appui** : 97,1 % ont une jumelle sous le seuil de confiance et **12 % seraient annoncées à tort avec assurance**. Deux limites restent : la règle du numéro ne couvre que 92,1 % du catalogue, et une réédition à 0 bit (*Professor Turo's Scenario*) rappelle qu'une identité de carte devra fusionner les impressions. Détail : [`docs/multi-game.md`](./docs/multi-game.md) §8.
- **Ce qui reste dû sur Yu-Gi-Oh** : une carte de papier — aucune n'a encore été photographiée. Le gabarit de deck (`DeckBlueprint`) reste `null` : le corpus existe désormais, mais ses proportions ne sont pas mesurées, et les déclarer d'avance referait l'erreur que le choix du format a déjà coûtée.
- **Focus immédiat** : la reconnaissance a rencontré sa première carte de papier Riftbound, et quatre défauts y sont tombés — le jeu saisi n'atteignait ni les gabarits ni le catalogue, trois messages d'échec accusaient la lecture de ce qu'elle avait réussi, et la détection de bords cédait sous un éclairage latéral. Cette carte se reconnaît désormais par son nom **et** par son illustration (rang 1 sur 1 035, 7 bits). Ce qui reste dû de #5 : le **lot** sur carton — cartes trouvées sur cartes réelles. Les **fausses cartes annoncées avec assurance sont désormais chiffrées** (`app.measure.art_collisions`) : environ **1 %** des cartes étrangères à un index le franchissent, et la plus proche descend à 2 bits — moins que le bruit d'un décodeur JPEG. La marge de confiance encaisse le reste : un tiers du catalogue Magic est confondable, 1,5 % seulement est affirmé. Deux découvertes en sont sorties — la densité a doublé avec le catalogue (18,7 % → 36,4 % de cartes ayant une voisine sous le seuil), et **des cartes Riftbound étaient enregistrées deux fois** par le catalogue. Corrigé (#29) : l'identité se dérivait du triplet nom + type + texte, deux champs d'affichage que la source réécrit d'une extension à l'autre — le champion passe du nom aux tags, le séparateur change, et VEN retire les rappels de règles entre parenthèses. **87 identités nouvelles en réunissent 192 anciennes** : 5 groupes par le seul nom, **63 par le seul texte** — que #29 ne pouvait pas voir puisqu'il ne regardait que les noms —, 19 par les deux. La règle est désormais **titre + type + champion**, le champion venant des tags ; elle sépare les trois titres portés par deux champions différents (« Rumble - Hotheaded » / « Vi - Hotheaded »), qui sont bien deux cartes. Trois pistes mesurées puis écartées, dont `riftbound_id` — son dernier segment ne prend que 13 valeurs et regroupe des centaines de cartes sans rapport. **Le lot sur carton est passé** — huit cartes Riftbound françaises photographiées par un tiers, quatorze reconnaissances : **zéro fausse carte annoncée**, deux reconnues avec assurance et justes, sur des noms qui n'existent pas au catalogue (« Boss de l'arène » y est « Arena Kingpin »). Le carton a montré ce que le banc ne pouvait pas : une carte couchée glissée dans une **pochette droite** se fait détecter comme une carte debout, et le gabarit couché s'appliquait alors de travers. L'orientation est devenue une hypothèse comme le cadre — un cadre couché dans un quadrilatère droit est lu tourné, dans les deux sens, une empreinte ne survivant pas au demi-tour. Altar of Blood passe du rang 492 au **rang 1**. La réciproque est refusée à dessein : elle inventait une carte à 12 bits sur une photo au masque faux. Le carton a livré un second défaut, et il était **un cran avant le seuillage qu'on soupçonnait** : la réduction qui amène la photo à la taille d'analyse interpolait entre les quatre pixels immédiats, quel que soit le facteur. À 1/10 — 4000 px ramenés à 400 — c'est du sous-échantillonnage : la trame d'un tissu replie en un bruit que le seuillage local lit comme du carton, 82,5 % de l'image tenue pour une carte. C'est le **facteur** qui décide et non le tissu : l'interpolation tient jusqu'à 2,7 et cède à partir de 3. Rien ne pouvait le voir — les tests travaillent sur des figures de 300 px, jamais réduites, et le banc compose des photos dont les facteurs vont de 1,6 à 2,7, soit un cran avant. Ce qui l'a révélé est d'avoir joué **la même photo dans les deux jumeaux** : le Python rendait la carte, le Dart rendait l'image entière. La parité était rompue en silence, et dans le sens inverse de la règle — c'est le Python qui avait raison. Les deux réduisent désormais par le filtre de moyenne à bornes entières que `art_hash.dart` emploie depuis toujours, et les coins coïncident au pixel près. La seconde prise d'Autel du Sang, jusque-là illisible, sort au **rang 1 à 11 bits** ; la première perd un bit (7 → 8) sans changer de verdict ; au banc, 293 cartes sur 320 contre 291. Coût : `findCard` passe de 26 à 53 ms sur une photo de 12 Mpx. Côté Twitch, la lecture publique et le bot `!card` sont en place ; restent l'overlay OBS (#14) et le temps réel (#8) dont il dépend. Le coût d'une image est **mesuré sur l'appareil**, et il tranche #8 en deux : à caméra fixe, 2,5 ms du capteur à l'identifiant — aucun problème de budget ; en **flux libre**, où il faut d'abord retrouver la carte, **52 ms**, soit 19 images par seconde et non 30. Baisser la résolution du capteur ne sauve pas la détection : diviser l'aire par 2,7 divise tout ce qui lit les pixels source (l'image entière passe de 10,4 à 3,9 ms) mais laisse `findCard` à 27-30 ms, son coût étant payé à la taille d'analyse, fixe. La piste du masque a été suivie : `List<bool>` — huit octets et un déréférencement par pixel — est passé en `Uint8List`, à comportement rigoureusement identique. `findCard` gagne **15 %** sur l'appareil (27,2 → 23,0 ms, mesuré en alternant les deux APK sur trois tours), mais cela ne suffisait pas. Le vrai levier était de **ne pas construire l'image** : `findCardInLuma` lit le plan de luminance sur place et fait passer la détection de 34,5 ms (image entière + `findCard`) à **23,0 ms**, mesuré dans la même exécution, **60 quadrilatères identiques sur 60**. Puis le même raccourci sur l'empreinte (`sampleArtFromLuma`, identique **bit à bit**) : la chaîne entière — détecter, découper dans le quadrilatère, hacher, chercher — tombe à **27,4 ms p50** contre 52 ms au départ. **Le flux libre tient dans les 33 ms**, donc 30 img/s est atteint ; le p90 affleure le budget. **La conception qui restait est tranchée, et la mesure a renversé deux attentes** (`app/tool/stream_bench.dart`, onze stratégies sur une séquence composée). D'abord, c'est **la détection elle-même qui tremble** : sur une carte immobile, un quadrilatère redétecté à chaque image fait varier l'empreinte jusqu'à 11 bits, contre 2 pour un quadrilatère tenu. Suivre n'est donc pas seulement moins cher, c'est plus fidèle. Ensuite, **l'échange de carte n'est pas le danger** — il est vu en zéro image par toutes les stratégies, la géométrie restant valable et l'empreinte prise à travers l'ancien quadrilatère étant déjà celle de la nouvelle carte. Le danger est la **dérive**, et il est structurel : chaque image ne s'écarte que de 1 à 4 bits, jamais assez pour franchir un seuil, mais après une douzaine d'images l'écart cumulé atteint **35 bits**. Aucun seuil de saut ne peut voir cela — d'où **deux garde-fous et non un** : le saut (12 bits, dans un fossé de trente entre le bruit à 2 et l'échange à 35) et l'âge (5 images). Retenu : 12,3 ms par image contre 27,4, trois reconnaissances perdues sur 156 images, et **aucune carte annoncée à tort** — sur onze stratégies et deux régimes, la dérive coûte un silence, jamais une erreur. Sous éclairage latéral, le suivi **récupère 17 reconnaissances** que la détection par image perd. La politique vit dans `quad_tracker.dart` (le banc la mesure, il n'en copie pas une réplique) ; elle n'est **pas branchée** sur le chemin caméra, et les deux seuils attendent un vrai capteur.
