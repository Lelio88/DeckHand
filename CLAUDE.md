# DeckHand — Deckbuilding Magic adossé à une collection physique

## I. Finalité

Transformer une collection **physique** de cartes Magic (500–2 000 cartes, anglais et français mélangés) en decks jouables. L'utilisateur saisit ses cartes (texte, voix, photo, scan multi-cartes), DeckHand valorise la collection et propose des decks classés en deux familles : constructibles immédiatement, ou à quelques cartes près avec le coût de complétion.

**Formats couverts** : Pauper, Commander, Modern. Pauper est prioritaire — c'est le seul où une collection ordinaire produit des decks réellement complets, les cartes chères y étant exclues par la restriction aux communes.

**Second jeu, Riftbound** (cartes papier League of Legends) : catalogue ingéré et cloisonné par `cards.game`, mais la boucle de valeur n'y est pas encore bouclée — ni prix, ni corpus de decks, ni gabarit d'illustration. Voir [`docs/multi-game.md`](./docs/multi-game.md).

Usage privé (le propriétaire et quelques amis) sur un dépôt public. Ni produit commercial, ni service ouvert.

## II. Architecture

Monorepo à deux têtes : `app/` (Flutter, mobile + web) et `api/` (jobs Python), sur Supabase.
L'application parle **directement** à Supabase — aucun serveur intermédiaire. `api/` ne contient
que des jobs d'ingestion et d'indexation, exécutés à la demande depuis un poste de travail.
La reconnaissance de cartes s'exécute **embarquée dans l'app** ; les jobs se contentent de
construire l'index d'empreintes qu'elle télécharge.

→ **Détail complet : [`docs/architecture.md`](./docs/architecture.md)** (pipeline de vision, modèle de données, connecteurs de sources).

## III. Pile Technologique

| Couche | Choix |
|---|---|
| `app/` | Flutter (mobile + web), Riverpod, `image` (empreintes), `image_picker` + `image_cropper` (scan), `speech_to_text` (dictée), `google_mlkit_text_recognition` (lecture du nom, embarquée), `shared_preferences` (cache) |
| `api/` | Python 3.11+, httpx, psycopg, Pillow, numpy — jobs hors ligne, pas de serveur |
| Données | Supabase — Postgres, Auth, Storage |
| Hébergement | Supabase cloud uniquement — rien à déployer, les jobs sont lancés en local |
| Sources | Scryfall (catalogue, prix), TopDeck.gg (méta), MTGJSON (précons), Riftcodex (catalogue Riftbound) |

## IV. Garde-Fous non négociables

1. **EDHREC est interdit.** Ses conditions d'utilisation prohibent explicitement les requêtes automatisées et la republication de contenu. Ses endpoints JSON sont techniquement accessibles — ne jamais les appeler.
2. **Attribution obligatoire.** TopDeck.gg exige un crédit visible et un lien depuis tout projet consommant son API ; Scryfall l'exige également. Deux niveaux, complémentaires : chaque deck porte le crédit de sa source (`deck_sources`), pour que l'interface ne puisse pas l'oublier en affichant la donnée ; et l'écran « à propos » crédite l'ensemble des sources, y compris Scryfall dont vient tout le catalogue sans qu'aucun écran ne le montre.
3. **Ne jamais paywaller ni simplement repackager les données Scryfall** — leurs conditions l'interdisent. La valeur ajoutée de DeckHand est le matching collection ↔ decks.
4. **Respecter les débits.** Scryfall : ≤ 10 req/s, `User-Agent` descriptif obligatoire, préférer les *bulk data* aux appels unitaires. TopDeck.gg : 100 req/min.
5. **Les prix Scryfall ne changent qu'une fois par jour.** Toute re-interrogation plus fréquente est du gaspillage.
6. **Un connecteur isolé par source de decks.** Aucune dépendance à une source ne remonte dans le cœur du produit — Archidekt et Moxfield sont fragiles ou conditionnels par nature.
7. **Secrets hors dépôt**, dans `../.deckhand-secrets/` (clés API TopDeck.gg, Supabase service role).
8. **Toute carte identifiée passe par une confirmation utilisateur.** Aucune entrée n'est écrite en collection sur la seule foi de la reconnaissance.
9. **Riftcodex n'a pas publié ses conditions.** La source du catalogue Riftbound est un projet de fans, non affilié à Riot ; l'API officielle, elle, répond 403 aux clés de développement et n'ouvre que sur approbation nommée. À défaut de règles explicites, appliquer celles de Scryfall — `User-Agent` descriptif, débit bas, attribution visible — et basculer vers Riot dès que possible. Ne jamais réhéberger les illustrations : elles sont servies par le CDN de Riot.
10. **Le dépôt est public** — trois conséquences : aucune donnée issue des sources n'est commitée (dumps Scryfall, decklists, index d'empreintes sont des artefacts générés, jamais versionnés) ; les attributions Scryfall et TopDeck.gg figurent dans le `README.md` ; le `.gitignore` couvre tous les caches de données.

## V. Flux de Travail (Explore → Plan → Code → Verify)

1. **Explore** — lire `docs/architecture.md` avant toute intervention structurante.
2. **Plan** — pour toute évolution touchant le pipeline de vision, le moteur de matching ou un connecteur de source, poser le plan avant d'écrire.
3. **Code** — TDD sur le moteur de matching et les parseurs de decklists (logique pure, testable sans réseau). Fakes plutôt que mocks.
4. **Verify** — aucun test ne doit dépendre d'un appel réseau réel : les réponses des sources externes sont figées en *fixtures*.

## VI. Commandes de Développement

```bash
# App — les --dart-define sont OBLIGATOIRES : sans eux l'app refuse de
# démarrer avec un message explicite, plutôt que d'échouer en 401 plus tard.
# Valeurs dans ../.deckhand-secrets/supabase.env
cd app && flutter run -d chrome \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=...

# Tests
cd api && .venv/Scripts/python -m pytest
cd app && flutter test

# Rafraîchir toutes les données Magic (idempotent, saute ce qui n'a pas changé).
cd api && .venv/Scripts/python -m app.ingestion.refresh
#   --force        réingère le catalogue même s'il n'a pas changé
#   --skip-decks   catalogue et empreintes uniquement

# Catalogue Riftbound (1 451 impressions, quelques minutes)
cd api && .venv/Scripts/python -m app.ingestion.riftcodex_ingest

# Migrations : fichiers horodatés dans supabase/migrations/, joués par psycopg
# et non par le CLI Supabase, qui exige un lien de projet interactif.
cd api && .venv/Scripts/python apply_migration.py ../supabase/migrations/<fichier>.sql
```

## VII. Maintenance documentaire

**Règle d'or** : le diff du code et celui de la doc correspondante vont dans le **même commit**.

| Modification | Fichier à mettre à jour |
|---|---|
| Nouvelle source de decks, ou changement de ses conditions d'usage | `CLAUDE.md` §IV + `docs/architecture.md` |
| Évolution du pipeline de reconnaissance | `docs/architecture.md` |
| Changement du modèle de données | `docs/architecture.md` |
| Nouveau secret / clé d'API | `../.deckhand-secrets/` (jamais dans le dépôt) |

## VIII. Contexte de Session

- **État** : catalogue peuplé — 33 953 cartes dont 1 077 jetons, ~63 600 noms indexés (dont les noms français et chaque face des cartes recto-verso), et **167 000 impressions** anglaises et françaises : chaque édition d'une carte est connue, choisissable et cotée séparément. Base à 155 Mo sur les 500 du plan gratuit. L'application permet de chercher une carte — en voyant combien d'exemplaires on en possède déjà —, l'ajouter à sa collection en désignant ou non son édition, et consulter celle-ci à l'échelle : recherche par nom (français compris), tri par nom, classeur, numéro de collection, valeur, quantité ou date d'ajout, chargement par pages. Re-choisir un critère de tri inverse la liste ; des filtres isolent la finition, les pleines illustrations et ce qui reste à préciser. Le tri « classeur » range par extension puis par numéro, comme on range une boîte — le numéro seul mêlerait les volumes, `mar #43` et `msh #43` se suivant ; les exemplaires brillants se repèrent au fond irisé de leur ligne ; un filtre rassemble ce qui reste à préciser. Le compteur de références dénombre les **éditions** — le couple (extension, numéro) — là où le deckbuilding continue de compter des cartes : 871 éditions de Plaine partagent un seul `oracle_id`, mais occupent 871 cases d'un classeur. Les totaux portent toujours sur la collection entière, indépendamment du filtre affiché. Préciser n'est jamais obligatoire — la saisie rapide en dépend. Le sélecteur montre l'illustration de chaque édition, filtre sur la langue du nom trouvé, et distingue le brillant du normal (prix séparés, ligne de collection distincte). Le bandeau indique combien d'exemplaires restent sans édition : leur valorisation est un plancher, pas une estimation.
- **Corpus** : 1 028 decks — 725 Pauper et 113 Modern de TopDeck.gg (étiquetés `competitive`), 190 précons Commander de MTGJSON (étiquetés `accessible`). Le moteur de suggestion et son écran sont en place : la boucle saisie → collection → decks constructibles est complète.
- **Reconnaissance** : deux voies — le **nom imprimé** est lu puis confronté au catalogue, l'empreinte d'illustration (31 634 entrées) servant de recours et de confirmation. Ce renversement vient du premier test terrain : l'empreinte seule exige un cadrage à 3 % près et suppose l'illustration exacte présente dans l'index, deux conditions qu'une photo à main levée ne remplit pas. Mesures et impasses dans [`docs/architecture.md`](./docs/architecture.md). Pipeline de vision en Dart pur, parité avec Python verrouillée par des vecteurs de test. Compte de test : `test@deckhand.app`, mot de passe dans `../.deckhand-secrets/supabase.env`.
- **Saisie** : quatre entrées — clavier, photo, dictée continue, étalement. La dictée accumule les cartes en écoute continue et les ajoute en bloc après validation ; l'étalement lit tous les noms d'une photo et propose une liste à cocher.
- **Préciser l'édition** : le code d'extension imprimé en bas de carte est lu avec le reste du texte, et l'édition correspondante remonte en tête du sélecteur. Le **numéro** de la même ligne, lui, est illisible à main levée — sur la lecture réelle figée il sort « C O0O5 », étant imprimé deux fois plus petit que le nom. Le code seul suffit pourtant : le couple (carte, extension) désigne une case unique dans **83,1 %** des cas, 87,9 % en français, 72 % des exemplaires réellement joués (`api/app/measure/edition_from_set.py`). Rien n'est coché d'office — la lecture est annoncée, l'utilisateur confirme. Sa fiabilité terrain reste à établir : elle ne repose pour l'instant que sur deux lignes d'une seule photo.
- **Éditions** : une édition est un couple (extension, numéro), jamais une langue. Le sélecteur sert la langue cherchée quand elle existe et l'anglais sinon, mais n'efface plus aucune édition — Scryfall ne catalogue pas toutes les impressions dans toutes les langues, et le filtre exclusif d'avant remplaçait une carte française bien réelle par une autre extension six fois plus chère. Conséquence : le nombre d'éditions ne dépend plus de la langue, donc les **quatre cartes sur dix qui n'en ont qu'une** se précisent d'office à l'étalement (`sole_editions`, un aller-retour pour tout le lot). La finition reste un choix, réglable à même la ligne.
- **Étalement** : les noms d'une photo sont lus, puis cherchés **tous ensemble en une seule requête** — `search_cards_bulk`. Une requête par ligne coûtait 77 secondes sur dix-sept cartes et échouait en silence ; le même lot revient en 3,3 s. Mesuré sur deux photos réelles : **17 cartes sur 17** à plat, 18 sur 19 en éventail. Le seuil de score est à 0,60 — descendu de 0,72 parce que ce qu'il écartait n'était pas du hasard mais des lectures mutilées (« Agents du S.H.LE.LD. »), au prix d'une fausse carte que la liste à cocher rend décochable. Limites assumées : un nom non lu n'est rattrapable par aucun réglage, et deux exemplaires identiques comptent pour un. **Se règle par la mesure et jamais à vue** — `--dart-define=DECKHAND_DIAG=true` allume un journal que `adb logcat` récupère, `app/tool/dump_fan_candidates.dart` imprime les candidats tels que l'app les produit (mesurer sans les filtres Dart gonfle les fausses), et la fixture `test/src/features/scan/measured_flat.dart` fige de vrais scores pour rejouer le seuil hors ligne. Impasses conservées dans [`docs/spread-detection.md`](./docs/spread-detection.md), à lire avant d'y revenir.
- **Constructeur de decks** : bâtit un Commander de cent cartes avec la seule collection, autour d'un général choisi ou proposé. Les proportions viennent du corpus mesuré (38 % de terrains, 29 % de créatures, 12 % de pioche, 6 % de rampe, 6 % de retrait) et non d'une opinion. Les trois formats sont couverts, chacun avec le gabarit de son corpus, mais ils ne se valent pas : la médiane des 190 précons Commander décrit un deck réel, celle des 725 Pauper mêle des archétypes incompatibles et décrit un deck qui n'existe nulle part. La vue l'annonce plutôt que de les présenter comme équivalents. Le deck est **jetable**, rien n'est enregistré. Le facteur limitant est le vivier, pas l'algorithme : 72 sorts pour 61 places ne laissent rien à choisir.
- **Focus immédiat** : éprouver la saisie à l'échelle visée, jamais tentée au-delà de quelques dizaines de cartes (`api/app/measure/typing_pace.py` reconstitue le rythme depuis `added_at`). Côté Riftbound, trois manques avant que la boucle de valeur tienne : les prix, un corpus de decks, et le gabarit d'illustration — sans lui la reconnaissance ne peut pas fonctionner, l'empreinte y étant la voie principale faute de catalogue traduit. L'index couvre les 49 484 illustrations distinctes du catalogue, et le scan d'une carte détecte désormais ses quatre coins : le cadrage a cessé d'être le facteur limitant — 37 cartes sur 40 reconnues à partir d'une photo ordinaire, contre aucune auparavant (`api/app/measure/framing_bench.py`).
- **Attributions** : Scryfall, TopDeck.gg et MTGJSON sont crédités dans l'écran « à propos » de l'application, en plus du README. Obligation contractuelle, pas décoration.
