# Publication Google Play — DeckHand

Procédure **propre à DeckHand**. La procédure générique, elle, vit hors du dépôt :
[`../../play-store-publication-guide.md`](../../play-store-publication-guide.md) (13 sections, questionnaires
IARC, Data safety, liste complète des tags). Ce fichier ne répète pas le guide — il porte les réponses
et les valeurs qui sont celles de cette app.

**Cible : test interne.** DeckHand est d'usage privé — le propriétaire et quelques amis. Google exige
de toute façon une première release manuelle avant d'ouvrir l'API.

## 1. Ce qui est prêt dans le dépôt

| Pièce | État |
|---|---|
| `applicationId` | `app.deckhand` — définitif après création de la fiche |
| Version | `1.0.0+1` dans `app/pubspec.yaml` |
| Signature de release | câblée, lit `app/android/key.properties` |
| Politique de confidentialité | <https://lelio88.github.io/DeckHand/privacy.html> |
| Compte de démonstration | `DECKHAND_DEMO_EMAIL` / `DECKHAND_DEMO_PASSWORD` dans `../.deckhand-secrets/supabase.env` |

## 2. La clé de signature — à faire une seule fois

**Le keystore n'est pas dans le dépôt** (garde-fou §IV.7) et **le perdre interdit toute mise à jour de
l'app, définitivement.** Il vit dans `../.deckhand-secrets/`, avec les autres secrets.

```bash
cd ../.deckhand-secrets
keytool -genkey -v -keystore upload-keystore.jks \
        -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Puis `app/android/key.properties`, avec un **chemin absolu** — Gradle résout les chemins relatifs
depuis `android/app/`, ce qui est une source d'erreurs silencieuses :

```properties
storePassword=<saisi à la création>
keyPassword=<idem>
keyAlias=upload
storeFile=C:/Users/buton/Documents/Projets/.deckhand-secrets/upload-keystore.jks
```

Sans ce fichier, la version release reste signée avec la clé de **débogage** : Gradle l'accepte, Play
la refuse, et le refus arrive après l'envoi. D'où l'avertissement émis par `build.gradle.kts`.

## 3. La fiche — textes prêts à coller

**Nom** (30 car. max) : `DeckHand`

**Description courte** (80 car. max — **73 utilisés**) :

```
Vos cartes réelles, rangées et jouables : valeur et decks constructibles.
```

> La première rédaction faisait 83 caractères et paraissait tenir : `wc -c` comptait
> 85 **octets**, deux accents pesant deux octets chacun en UTF-8. Play compte des
> caractères. Vérifier avec `len()` et non avec `wc`.

**Description longue** (4 000 car. max) :

```
DeckHand transforme une collection de cartes physiques en decks jouables.

Vous saisissez vos cartes — au clavier, à la voix, en photographiant, ou en étalant plusieurs cartes
devant l'objectif. DeckHand les reconnaît, les range en classeurs, en donne la valeur, et vous dit
ce que vous pouvez construire avec.

CE QU'IL FAIT

• Saisie rapide : clavier avec recherche instantanée, dictée, ou reconnaissance par la caméra.
• Classeurs : vos cartes rangées comme dans vos vrais classeurs, page par page, pour retrouver une
  carte sans tout sortir.
• Valeur : le prix indicatif de chaque carte et de la collection entière, rafraîchi une fois par jour.
• Decks constructibles : les decks que votre collection permet de monter dès maintenant, et ceux qui
  sont à quelques cartes près — avec le coût exact de ce qu'il manque.
• Journal : ce qui est entré et sorti de la collection, et quand.
• Partage : montrez un classeur à un ami par un lien, si vous le décidez. Rien n'est public par défaut.

QUATRE JEUX

Magic: The Gathering (Pauper, Commander, Modern), Pokémon, Yu-Gi-Oh et Riftbound. Chaque jeu a ses
règles de construction, ses formats et ses prix propres — pas un moule commun.

LA RECONNAISSANCE SE FAIT SUR VOTRE APPAREIL

Les photos de vos cartes ne quittent jamais le téléphone : l'image est analysée sur place et jetée.
Seul le nom que vous confirmez est enregistré. Et rien n'entre dans votre collection sans que vous
l'ayez validé.

PAS DE PUBLICITÉ, PAS DE PISTAGE

Aucune publicité, aucune mesure d'audience, aucune revente de données. DeckHand est un outil
personnel, sans finalité commerciale.

SOURCES

Les données de cartes proviennent de Scryfall, TCGdex, TCGCSV, YGOPRODeck, Riftcodex, TopDeck.gg,
Limitless TCG et MTGJSON, que l'application crédite. DeckHand n'est affiliée à aucun éditeur de jeu
de cartes ; les noms de cartes et de jeux appartiennent à leurs ayants droit.
```

**Catégorie** : Application → **Divertissement** (DeckHand est un outil de collection, on n'y joue
pas ; la catégorie « Jeux → Cartes » déclencherait le questionnaire IARC complet des jeux — violence,
peur, interactions — pour une app qui n'a aucun de ces contenus).

**Coordonnées** : `heianenterpriseyt@gmail.com` — contact public de toutes les apps du compte. Ne
jamais y mettre d'adresse professionnelle.

## 3 bis. Le compte de démonstration

**`DECKHAND_TEST_EMAIL` n'est pas un compte de test** malgré son nom : c'est
`buton1@live.fr`, le compte du propriétaire, avec ses 5 classeurs réels et son
journal de mouvements. Le donner aux examinateurs leur donnerait accès à tout
cela, et la possibilité de le modifier.

Le compte à fournir est `DECKHAND_DEMO_EMAIL` / `DECKHAND_DEMO_PASSWORD`, créé
par l'API admin de Supabase avec `email_confirm` — le domaine n'existe pas, et
un examinateur n'a pas de boîte à relever. Il porte **30 cartes Pauper en quatre
exemplaires, rangées dans 23 classeurs** : un écran vide inviterait à conclure
que l'application ne fonctionne pas.

Le mot de passe est généré et ne figure que dans le coffre. Pour le lire au
moment de le coller :

```bash
grep DECKHAND_DEMO ../.deckhand-secrets/supabase.env
```

## 4. Les réponses aux sections du guide

| Section | Réponse pour DeckHand |
|---|---|
| 2 · Politique de confidentialité | <https://lelio88.github.io/DeckHand/privacy.html> |
| 3 · App access | **Oui, une partie est limitée** — l'app exige un compte. Fournir `DECKHAND_DEMO_EMAIL` / `DECKHAND_DEMO_PASSWORD`. **Surtout pas `DECKHAND_TEST_EMAIL`** : malgré son nom, c'est le compte du propriétaire, avec sa collection réelle et son journal. |
| 4 · Annonces | **Non**, aucune publicité. |
| 5 · Classification IARC | Catégorie *Application*, donc questionnaire court. Aucune violence, aucun contenu sexuel, aucun jeu d'argent, aucune substance. **Pas de chat** : le partage est en lecture seule, sans messagerie. |
| 6 · Public cible | 13 ans et plus. L'app ne cible pas les enfants et ne collecte rien à des fins publicitaires. |
| 7 · Data safety | **Collecté** : adresse e-mail (compte), et le contenu que l'utilisateur crée — collection, classeurs, decks. Finalité : *fonctionnement de l'application*. Chiffré en transit, suppression sur demande. **Non collecté** : photos et vidéos — la reconnaissance est embarquée, l'image est jetée après analyse. L'**audio** de la dictée est traité par le moteur du système (Google), pas par DeckHand. |
| 8 · Applis gouvernementales | Non. |
| 9 · Fonctionnalités financières | Aucune. Les prix affichés sont indicatifs ; l'app ne vend rien et ne prend aucun paiement. |
| 10 · Applis de santé | Non. |

## 4 bis. Où vivent la clé et le bundle

| Fichier | Emplacement |
|---|---|
| Clé de signature | `../.deckhand-secrets/upload-keystore.jks` — même nom que dewdrop, GTG, LLMarmite |
| Mot de passe | `../.deckhand-secrets/supabase.env` → `DECKHAND_KEYSTORE_PASSWORD` |
| Bundle | `app/build/app/outputs/bundle/release/app-release.aab` — **là où Flutter le produit** |

**Le bundle reste dans le dossier de build**, comme dans les quatre autres apps
du compte. Le garde-fou du hub le dit : « les APK/AAB/binaires restent dans le
dossier de build natif du projet ».

Une seule app fait autrement : CulturiaQuests archive en plus ses envois dans son
coffre (`culturiaquests-v1…v5-com.culturiaquests.app.aab`), ce qui garde
l'historique des versions soumises. C'est une pratique **facultative**, pas la
règle — l'adopter ici demanderait de le décider, pas de le supposer.

**Rien de sensible n'entre dans le dépôt** : `key.properties` est ignoré deux
fois, et `*.aab` / `*.apk` le sont aussi — un bundle pèse 60 Mo et se régénère.

⚠️ **Le keystore ne se perd pas.** Le perdre interdit toute mise à jour de
l'application, définitivement — aucune récupération n'existe. Play App Signing
laissé activé à l'envoi est le seul filet.

## 5. La release

```bash
cd app
# Les --dart-define sont OBLIGATOIRES : sans eux l'app boote sans Supabase.
flutter build appbundle --release \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=...
```

L'AAB sort dans `app/build/app/outputs/bundle/release/app-release.aab`.

Puis **Tests → Tests internes → Créer une version** : uploader l'AAB, laisser *Play App Signing*
activé, ajouter les testeurs, envoyer pour examen.

Le compte de service `play-publisher` (commun à toutes les apps du compte, clé dans
`../.play-secrets/play-sa.json`) permet ensuite de publier par API — mais seulement **après** cette
première release manuelle, et il faut l'inviter sur cette application dans *Utilisateurs et
autorisations* avec l'autorisation *Gérer les versions de test*. La production ne lui est pas
accordée, à dessein.

## 6. Ce qui manque encore

- **Les captures d'écran** — au moins deux, à faire sur l'appareil. Seule pièce que rien ne peut
  produire sans lui.
- **L'icône** — 512 × 512 px, et une bannière 1024 × 500.
- **`publish_play.py`** — à copier depuis `dewdrop/tools/release/` et adapter, pour les envois qui
  suivront le premier.
