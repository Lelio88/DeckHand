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
- `app/lib/src/common/` et `config/` — images en cache, délais de requête, jeu sélectionné
- `api/app/ingestion/` — un connecteur isolé par source ; `api/app/vision/` — empreintes ; `api/app/measure/` — bancs de mesure ; `api/app/twitch/` — bot de chat en lecture, lancé le temps d'un direct
- `supabase/migrations/` — fichiers horodatés, joués par `api/apply_migration.py`

## III. Pile Technologique

*Versions contraintes par `app/pubspec.yaml` et `api/pyproject.toml`. N'introduisez aucune dépendance alternative sans approbation.*

- **`app/`** : Flutter (mobile + web), Riverpod, `image` (empreintes), `image_picker` + `image_cropper`, `speech_to_text`, `google_mlkit_text_recognition`, `shared_preferences`, `flutter_svg`
- **`api/`** : Python 3.11+, httpx, psycopg, Pillow, numpy — **chaque contrainte porte un plafond de majeure** : `numpy` et `Pillow` sont le seul chemin par lequel une bibliothèque peut dégrader la reconnaissance en silence, une empreinte au calcul modifié restant valide mais devenant incomparable au jumeau Dart
- **Données** : Supabase — Postgres, Auth, Storage. Cloud uniquement, rien à déployer
- **Sources** : Scryfall (catalogue, prix), TopDeck.gg (decks des deux jeux), MTGJSON (précons), Riftcodex (catalogue Riftbound), TCGCSV (prix Riftbound), BCE (taux de change)

## IV. Garde-Fous non négociables

1. **EDHREC est interdit.** Ses conditions prohibent les requêtes automatisées et la republication. Ses endpoints JSON sont accessibles — ne jamais les appeler.
2. **Attribution obligatoire**, et **visible de qui regarde**. Chaque deck porte le crédit de sa source (`deck_sources`) ; l'écran « à propos » crédite l'ensemble ; toute page vue par des inconnus porte le sien en pied.
3. **Ne jamais paywaller ni repackager les données Scryfall.** La valeur ajoutée est le matching collection ↔ decks.
4. **Respecter les débits.** Scryfall ≤ 10 req/s, `User-Agent` descriptif, *bulk data* plutôt qu'appels unitaires. TopDeck.gg : 100 req/min.
5. **Les prix ne changent qu'une fois par jour.** Toute re-interrogation plus fréquente est du gaspillage.
6. **Un connecteur isolé par source de decks.** Aucune dépendance à une source ne remonte dans le cœur du produit.
7. **Secrets hors dépôt**, dans `../.deckhand-secrets/`. Les clés de publication viennent des secrets d'actions, jamais du dépôt.
8. **Toute carte identifiée passe par une confirmation utilisateur.** L'**édition**, elle, est déduite sans geste quand rien ne reste à choisir — désigner l'unique candidat n'apporte aucune information que la carte ne porte déjà. Dès que deux cases subsistent, l'utilisateur choisit.
9. **Une source sans conditions publiées reçoit celles de Scryfall** — `User-Agent` descriptif, débit bas, attribution visible. Vaut pour Riftcodex et TCGCSV. Ne jamais réhéberger d'illustration.
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

cd app && flutter analyze && flutter test    # 400 tests
cd api && .venv/Scripts/python -m pytest     # 83 tests

# Ingestion — idempotente, saute ce qui n'a pas changé
cd api && .venv/Scripts/python -m app.ingestion.refresh            # Magic (--force, --skip-decks)
cd api && .venv/Scripts/python -m app.ingestion.riftcodex_ingest   # catalogue Riftbound
cd api && .venv/Scripts/python -m app.ingestion.tcgcsv_prices      # prix Riftbound (--force)
cd api && .venv/Scripts/python -m app.ingestion.topdeck_ingest --riftbound

# Bot Twitch, en lecture seule — tourne le temps d'un direct, rien à déployer
cd api && .venv/Scripts/python -m app.twitch          # --game riftbound

# Vérifier l'arithmétique de l'écran Decks : <format> <jeu>
cd api && .venv/Scripts/python -m app.measure.deck_math constructed riftbound

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
| Évolution propre à Riftbound | [`docs/multi-game.md`](./docs/multi-game.md) |
| Nouvelle impasse mesurée | Section « impasses » de l'annexe concernée |
| Nouveau secret / clé d'API | `../.deckhand-secrets/` (jamais dans le dépôt) |

## VIII. Contexte de Session

- **État** : 33 953 cartes Magic et 167 000 impressions cotées ; 1 035 cartes Riftbound, cotées et adossées à 2 500 decks. Les deux jeux bouclent la même promesse. Collection réelle : 343 lignes, 451 exemplaires, aucune sans édition. Compte `buton1@live.fr`, mot de passe dans `../.deckhand-secrets/supabase.env`.
- **Focus immédiat** : la reconnaissance Riftbound n'a **jamais rencontré une carte de papier** (issues #4 et #5) — seul manque de ce jeu, et il demande du matériel, pas du code. Côté Twitch, la lecture publique et le bot `!card` sont en place ; restent l'overlay OBS (#14) et le temps réel (#8) dont il dépend, et dont la première tâche est une mesure : chronométrer une image de bout en bout sur l'appareil.
