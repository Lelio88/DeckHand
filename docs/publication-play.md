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

CINQ JEUX

Magic: The Gathering (Pauper, Commander, Modern), Pokémon, Yu-Gi-Oh, Riftbound et Wankul. Chaque jeu
a ses règles de construction, ses formats et ses prix propres — pas un moule commun. Wankul se
saisit, se range et se compte, mais ne se valorise pas : aucun index public ne cote ce jeu.

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

## 6. Les envois suivants passent par l'API

Le premier envoi se fait à la main ; **tous les suivants passent par
`tools/release/publish_play.py`**, copié depuis DewDrop sans une ligne de
modification — il détecte seul le dépôt, le module Flutter, l'`applicationId`
lu dans Gradle, la version de `pubspec.yaml`, l'AAB et la clé de service.

```bash
cd api
.venv/Scripts/python -m pip install -e ".[release]"      # une fois

# Toujours commencer par là : un vrai upload dans un edit temporaire, abandonné
# ensuite. C'est ce qui prouve les droits et la validité du bundle avant
# d'engager quoi que ce soit.
.venv/Scripts/python ../tools/release/publish_play.py --track alpha \
    --notes-file ../tools/release/notes-<version>.txt --dry-run

.venv/Scripts/python ../tools/release/publish_play.py --track alpha \
    --notes-file ../tools/release/notes-<version>.txt

.venv/Scripts/python ../tools/release/publish_play.py --list-tracks
```

**Incrémenter `version:` dans `app/pubspec.yaml` avant de construire** : Play
refuse un `versionCode` déjà envoyé, et le refus arrive après l'upload.

Le compte de service ne peut pas atteindre la production — la permission n'a pas
été accordée, à dessein. Voir `INFRASTRUCTURE.md` §compte de service à la racine
des projets.

## 7. Les captures de la fiche

**Quatre, prises sur l'appareil**, toutes en 1224 × 2720 (9:16), dans
`app/store/` :

| Fichier | Ce qu'elle montre |
|---|---|
| `01-classeurs.png` | l'étagère, et le **regroupement par sortie** — une extension mère, ses satellites Commander et jetons |
| `02-classeur.png` | une page de classeur : possédées en clair avec leur nombre, manquantes en fantôme avec leur numéro |
| `03-decks.png` | le constructeur : **trois decks jouables en même temps, aucune carte partagée**, et ce que chacun vise |
| `04-recherche.png` | la saisie — prix, formats légaux, et les quatre modes d'entrée (clavier, voix, photo, étalement) |

Elles couvrent les quatre piliers de la description longue. Play en accepte
jusqu'à huit ; ces quatre suffisent à raconter l'application.

**Rien ne bloque plus la production côté matière.** Ce qui reste est de la
console, et ne peut pas passer par l'API : créer la version de production,
répondre aux questionnaires (déjà rédigés en § 5), et publier. Le compte de
service n'a pas le droit d'atteindre la production, à dessein.

⚠ **Passer en production rend l'application publique.** La fiche devient
trouvable par n'importe qui et le contact `heianenterpriseyt@gmail.com` visible.
Le dépôt est déjà public, mais l'usage décrit dans le `CLAUDE.md` — « le
propriétaire et quelques amis » — reste vrai fonctionnellement sans l'être en
vitrine. Un test fermé suffit si ce n'est pas le but.
