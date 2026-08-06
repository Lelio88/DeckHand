# DeckHand — Deckbuilding Magic adossé à une collection physique

## I. Finalité

Transformer une collection **physique** de cartes Magic (500–2 000 cartes, anglais et français mélangés) en decks jouables. L'utilisateur saisit ses cartes (texte, voix, photo, scan multi-cartes), DeckHand valorise la collection et propose des decks classés en deux familles : constructibles immédiatement, ou à quelques cartes près avec le coût de complétion.

**Formats couverts** : Pauper, Commander, Modern. Pauper est prioritaire — c'est le seul où une collection ordinaire produit des decks réellement complets, les cartes chères y étant exclues par la restriction aux communes.

Usage privé (le propriétaire et quelques amis) sur un dépôt public. Ni produit commercial, ni service ouvert.

## II. Architecture

Monorepo à deux têtes : `app/` (Flutter, mobile + web) et `api/` (Python/FastAPI), sur Supabase.
La reconnaissance de cartes s'exécute **embarquée dans l'app** ; le serveur ne construit que l'index d'empreintes.

→ **Détail complet : [`docs/architecture.md`](./docs/architecture.md)** (pipeline de vision, modèle de données, connecteurs de sources).

## III. Pile Technologique

| Couche | Choix |
|---|---|
| `app/` | Flutter (mobile + web), Riverpod, go_router, freezed |
| `api/` | Python 3.11+, FastAPI, httpx, Pillow/OpenCV (indexation hors ligne) |
| Données | Supabase — Postgres, Auth, Storage |
| Hébergement | Render (API) + Supabase cloud |
| Sources | Scryfall (catalogue, prix), TopDeck.gg (méta), MTGJSON (précons) |

## IV. Garde-Fous non négociables

1. **EDHREC est interdit.** Ses conditions d'utilisation prohibent explicitement les requêtes automatisées et la republication de contenu. Ses endpoints JSON sont techniquement accessibles — ne jamais les appeler.
2. **Attribution obligatoire.** TopDeck.gg exige un crédit visible et un lien depuis tout projet consommant son API. Scryfall exige également l'attribution. Ces mentions sont portées par la donnée (`deck_sources`), pas par un écran « à propos ».
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
# API
cd api && uvicorn app.main:app --reload

# App — les --dart-define sont OBLIGATOIRES : sans eux l'app refuse de
# démarrer avec un message explicite, plutôt que d'échouer en 401 plus tard.
# Valeurs dans ../.deckhand-secrets/supabase.env
cd app && flutter run -d chrome \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=...

# Tests
cd api && .venv/Scripts/python -m pytest
cd app && flutter test

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

- **État** : catalogue peuplé — 31 634 cartes, 61 298 noms indexés dont 29 664 en français, une impression de référence par carte. Base à 100 Mo sur les 500 du plan gratuit. L'application permet de chercher une carte, l'ajouter à sa collection et en voir la valeur. Le corpus de decks est vide.
- **Focus immédiat** : connecteurs de decks (TopDeck.gg pour le Pauper, MTGJSON pour les précons), puis moteur de matching collection ↔ decks.
- **Compte de test** : `test@deckhand.app`, mot de passe dans `../.deckhand-secrets/supabase.env`.
- **Décision révisable avant le jalon 2** : le pipeline de vision est prévu en Dart pur pour couvrir mobile et web d'un seul code. Si la détection de contours s'avère trop lente sur l'étalement multi-cartes, ce seul maillon bascule en natif.
