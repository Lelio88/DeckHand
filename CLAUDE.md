# DeckHand — Deckbuilding Magic adossé à une collection physique

## I. Finalité

Transformer une collection **physique** de cartes Magic (500–2 000 cartes, anglais et français mélangés) en decks jouables. L'utilisateur saisit ses cartes (texte, voix, photo, scan multi-cartes), DeckHand valorise la collection et propose des decks classés en deux familles : constructibles immédiatement, ou à quelques cartes près avec le coût de complétion.

**Formats couverts** : Pauper, Commander, Modern. Pauper est prioritaire — c'est le seul où une collection ordinaire produit des decks réellement complets, les cartes chères y étant exclues par la restriction aux communes.

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
| Sources | Scryfall (catalogue, prix), TopDeck.gg (méta), MTGJSON (précons) |

## IV. Garde-Fous non négociables

1. **EDHREC est interdit.** Ses conditions d'utilisation prohibent explicitement les requêtes automatisées et la republication de contenu. Ses endpoints JSON sont techniquement accessibles — ne jamais les appeler.
2. **Attribution obligatoire.** TopDeck.gg exige un crédit visible et un lien depuis tout projet consommant son API ; Scryfall l'exige également. Deux niveaux, complémentaires : chaque deck porte le crédit de sa source (`deck_sources`), pour que l'interface ne puisse pas l'oublier en affichant la donnée ; et l'écran « à propos » crédite l'ensemble des sources, y compris Scryfall dont vient tout le catalogue sans qu'aucun écran ne le montre.
3. **Ne jamais paywaller ni simplement repackager les données Scryfall** — leurs conditions l'interdisent. La valeur ajoutée de DeckHand est le matching collection ↔ decks.
4. **Respecter les débits.** Scryfall : ≤ 10 req/s, `User-Agent` descriptif obligatoire, préférer les *bulk data* aux appels unitaires. TopDeck.gg : 100 req/min.
5. **Les prix Scryfall ne changent qu'une fois par jour.** Toute re-interrogation plus fréquente est du gaspillage.
6. **Un connecteur isolé par source de decks.** Aucune dépendance à une source ne remonte dans le cœur du produit — Archidekt et Moxfield sont fragiles ou conditionnels par nature.
7. **Secrets hors dépôt**, dans `../.deckhand-secrets/` (clés API TopDeck.gg, Supabase service role).
8. **Toute carte identifiée passe par une confirmation utilisateur.** Aucune entrée n'est écrite en collection sur la seule foi de la reconnaissance.
9. **Le dépôt est public** — trois conséquences : aucune donnée issue des sources n'est commitée (dumps Scryfall, decklists, index d'empreintes sont des artefacts générés, jamais versionnés) ; les attributions Scryfall et TopDeck.gg figurent dans le `README.md` ; le `.gitignore` couvre tous les caches de données.

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

# Rafraîchir toutes les données (idempotent, saute ce qui n'a pas changé).
# Les prix Scryfall dérivent chaque jour : sans cela, la valorisation de
# collection et les coûts de complétion deviennent progressivement faux.
cd api && .venv/Scripts/python -m app.ingestion.refresh
#   --force        réingère le catalogue même s'il n'a pas changé
#   --skip-decks   catalogue et empreintes uniquement

# Base de données — les migrations vivent dans supabase/migrations/,
# convention attendue par le CLI et par l'intégration GitHub.
supabase link --project-ref <ref>
supabase db push                   # applique les migrations au projet distant
supabase migration new <nom>       # nouvelle migration horodatée
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

- **État** : catalogue peuplé — 31 634 cartes, ~61 000 noms indexés (dont les noms français et chaque face des cartes recto-verso), et **162 000 impressions** anglaises et françaises : chaque édition d'une carte est connue, choisissable et cotée séparément. Base à 155 Mo sur les 500 du plan gratuit. L'application permet de chercher une carte — en voyant combien d'exemplaires on en possède déjà —, l'ajouter à sa collection en désignant ou non son édition, et consulter celle-ci à l'échelle : recherche par nom (français compris), tri par nom, valeur, quantité ou date d'ajout, chargement par pages. Les totaux portent toujours sur la collection entière, indépendamment du filtre affiché.
- **Éditions et finition** : préciser n'est jamais obligatoire — la saisie rapide en dépend. Le sélecteur montre l'illustration de chaque édition, filtre sur la langue du nom trouvé, et distingue le brillant du normal (prix séparés, ligne de collection distincte). Le bandeau indique combien d'exemplaires restent sans édition : leur valorisation est un plancher, pas une estimation.
- **Corpus** : 1 028 decks — 725 Pauper et 113 Modern de TopDeck.gg (étiquetés `competitive`), 190 précons Commander de MTGJSON (étiquetés `accessible`). Le moteur de suggestion et son écran sont en place : la boucle saisie → collection → decks constructibles est complète.
- **Reconnaissance** : deux voies — le **nom imprimé** est lu puis confronté au catalogue, l'empreinte d'illustration (31 634 entrées) servant de recours et de confirmation. Ce renversement vient du premier test terrain : l'empreinte seule exige un cadrage à 3 % près et suppose l'illustration exacte présente dans l'index, deux conditions qu'une photo à main levée ne remplit pas. Mesures et impasses dans [`docs/architecture.md`](./docs/architecture.md).
- **Saisie** : quatre entrées — clavier, photo, dictée continue, étalement. La dictée accumule les cartes en écoute continue et les ajoute en bloc après validation ; l'étalement lit tous les noms d'une photo et propose une liste à cocher.
- **Étalement** : les noms d'une photo sont lus puis triés par la taille du texte, mesurée sur les coins de chaque ligne — la boîte englobante mesure la longueur, pas la taille. Cinq cartes sur cinq sans fausse sur un étalement réel, là où la segmentation d'image plafonnait à 57 % ([`docs/spread-detection.md`](./docs/spread-detection.md) conserve ses impasses, à lire avant d'y revenir). Limites assumées : un nom non lu n'est rattrapable par aucun réglage, et deux exemplaires identiques comptent pour un. **Se règle par la mesure** — `--dart-define=DECKHAND_DIAG=true` allume un journal que `adb logcat` récupère, et `app/tool/sweep_spread_threshold.dart` rejoue le filtrage à tous les seuils sur une photo unique, seule façon de comparer autre chose que des photos différentes.
- **Focus immédiat** : éprouver la saisie à l'échelle visée, jamais tentée au-delà de quelques dizaines de cartes (`api/app/measure/typing_pace.py` reconstitue le rythme depuis `added_at`), puis vérifier l'écran Decks sur une collection fournie. Deux chantiers connus restent ouverts — l'index ne porte qu'une illustration par carte (un quart des rééditions changent d'art), et rien ne détecte les bords de la carte dans la photo.
- **Attributions** : Scryfall, TopDeck.gg et MTGJSON sont crédités dans l'écran « à propos » de l'application, en plus du README. Obligation contractuelle, pas décoration.
- **Compte de test** : `test@deckhand.app`, mot de passe dans `../.deckhand-secrets/supabase.env`.
- **Décision tranchée** : pipeline de vision en Dart pur, parité avec Python verrouillée par des vecteurs de test. La détection de contours ne devient nécessaire qu'au jalon 3 — le jalon 2 s'en passe grâce au cadrage guidé.
