# DeckHand

Un assistant de deckbuilding adossé à une collection **physique** de cartes.

Vous saisissez les cartes que vous possédez réellement — au clavier, à la voix, en
photographiant une carte ou une poignée étalées sur la table. DeckHand valorise la
collection, la range en classeurs comme le ferait un vrai classeur à pochettes, et propose
des decks classés en deux familles : ceux que vous pouvez construire **ce soir**, et ceux
auxquels il ne manque que quelques cartes — chiffrées.

**Jeux couverts** : *Magic: The Gathering* (Pauper, Commander, Modern) et *Riftbound*, le jeu
de cartes League of Legends.

---

## Ce que ça fait

**Saisir.** Quatre chemins, du plus large au plus fin : photographier une dizaine de cartes
étalées, dicter en continu, viser une carte, ou taper son nom. Le français et l'anglais sont
acceptés partout, et les fautes de frappe tolérées.

**Ranger.** Un classeur est une extension, une case est un numéro. La page montre donc aussi
**les cases vides** — c'est ce qu'un classeur dit et qu'une liste ne dit pas. Les feuilles se
tournent au doigt ; couché, l'appareil ouvre le classeur à plat sur une double page.

**Valoriser.** Chaque carte porte sa cote, et le total de la collection en découle. Une carte
dont l'édition n'est pas précisée compte pour un plancher, jamais pour une estimation.

**Construire.** DeckHand ne génère pas de decks : il confronte votre collection à des
milliers de decklists réelles — tournois et précons officiels — et vous dit lesquelles sont à
portée, et pour combien.

**Partager.** Une collection peut être donnée à lire : un lien ouvre vos classeurs sans
compte, et se révoque d'un interrupteur. Vous choisissez quels classeurs partager, et sous
quel nom — l'adresse se dicte. Un bot Twitch lit par cette même porte : `!card Ka-Zar`
répond « Marvel Super Heroes #174, page 20 case 3 », et rien de ce que vous n'avez pas
partagé.

## Pourquoi Pauper d'abord

Les boosters sont majoritairement composés de cartes communes. Une collection ordinaire est
donc riche en cartes légales en Pauper — format restreint aux communes — et pauvre en rares
coûteuses. C'est le format où la promesse « voilà ce que vous pouvez jouer ce soir » tient
vraiment : les decks y coûtent quelques dizaines d'euros, contre plusieurs centaines en
Modern.

## Comment c'est fait

Deux têtes dans un seul dépôt, et **aucun serveur** entre les deux :

- **`app/`** — l'application Flutter (mobile et web). Elle parle directement à Supabase.
  La reconnaissance de cartes s'y exécute **embarquée** : elle fonctionne hors ligne.
- **`api/`** — des jobs Python lancés à la main pour ingérer les catalogues, les prix et les
  decklists, et pour construire l'index d'empreintes que l'application télécharge.

Le reste — base de données, authentification, calcul des suggestions — vit dans Supabase,
sous forme de fonctions SQL.

→ Détail technique dans [`docs/architecture.md`](./docs/architecture.md).

## Démarrer

L'application a besoin de deux valeurs, sans lesquelles elle refuse de se lancer plutôt que
d'échouer plus tard :

```bash
cd app
flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
```

Les jobs d'ingestion sont idempotents et sautent ce qui n'a pas changé :

```bash
cd api && .venv/Scripts/python -m app.ingestion.refresh
```

Le bot Twitch tourne le temps d'un direct, sur le poste qui diffuse — rien à déployer :

```bash
cd api && .venv/Scripts/python -m app.twitch
```

## Crédits et sources de données

DeckHand n'existe que grâce à ces services, qui ouvrent leurs données.

- **[Scryfall](https://scryfall.com)** — catalogue des cartes, noms localisés, légalités,
  identité couleur, prix et illustrations. DeckHand respecte leurs
  [directives d'API](https://scryfall.com/docs/api) : débit limité, `User-Agent` identifiant,
  exports groupés plutôt qu'appels unitaires.
- **[TopDeck.gg](https://topdeck.gg)** — decklists de tournoi, pour les trois jeux.
- **[MTGJSON](https://mtgjson.com)** — decks préconstruits officiels, sous licence MIT.
- **[Riftcodex](https://riftcodex.com)** — catalogue des cartes Riftbound. Base communautaire
  non affiliée à Riot Games, qui ne publie pas de conditions d'usage : DeckHand lui applique
  les mêmes égards qu'à Scryfall, et ne réhéberge aucune illustration.
- **[TCGCSV](https://tcgcsv.com)** — prix de marché TCGplayer pour Riftbound et Yu-Gi-Oh, convertis en
  euros au **taux de référence quotidien de la [Banque centrale européenne](https://www.ecb.europa.eu)**.
  Ce sont donc des prix convertis, non relevés sur un marché européen, et l'application le dit.
- **[Riot Games](https://riotgames.com)** — Riftbound, ses cartes et leurs illustrations.
  DeckHand n'est ni approuvé ni sponsorisé par Riot Games.
- **[YGOPRODeck](https://ygoprodeck.com)** — catalogue des cartes Yu-Gi-Oh, noms français et
  illustrations. Base communautaire qui ne publie pas de CGU : son
  [guide d'API](https://ygoprodeck.com/api-guide/) fait foi, il demande le stockage local des
  données, et DeckHand lui applique pour le reste les mêmes égards qu'à Scryfall.
- **[Konami](https://www.konami.com)** — Yu-Gi-Oh!, ses cartes et leurs illustrations.
  DeckHand n'est ni approuvé ni sponsorisé par Konami.

Aucune donnée issue de ces sources n'est versionnée ici : tout est téléchargé à l'exécution,
dans le respect des conditions de chaque fournisseur.

## Mentions légales

Contenu non officiel de fan. Non approuvé par Wizards of the Coast. Certains éléments sont la
propriété de Wizards of the Coast LLC, filiale de Hasbro, Inc. DeckHand n'est affilié ni à
Wizards of the Coast, ni à Riot Games, ni à aucune des sources de données citées.

Projet personnel, sans finalité commerciale.
