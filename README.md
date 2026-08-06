# DeckHand

Assistant de deckbuilding *Magic: The Gathering* adossé à une collection **physique**.

Vous saisissez les cartes que vous possédez réellement — au clavier, à la voix, ou en les
photographiant. DeckHand estime la valeur de la collection et propose des decks classés en
deux familles : ceux que vous pouvez construire **immédiatement**, et ceux auxquels il ne
manque que quelques cartes, chiffrées.

**Formats** : Pauper, Commander, Modern.

> **État du projet** : utilisable. Recherche bilingue, collection valorisée, suggestions de
> decks et reconnaissance de cartes par photo fonctionnent. L'étalement multi-cartes et la
> saisie vocale restent à faire.

## Pourquoi Pauper en premier

Les boosters sont majoritairement composés de cartes communes. Une collection ordinaire est
donc riche en cartes légales en Pauper — format restreint aux communes — et pauvre en rares
coûteuses. C'est le format où la promesse « voilà ce que vous pouvez construire ce soir »
tient réellement : les decks y coûtent quelques dizaines d'euros, contre plusieurs centaines
en Modern.

## Architecture

Monorepo à deux têtes : `app/` (Flutter, mobile et web) et `api/` (jobs Python), sur Supabase.
L'application interroge Supabase directement — il n'y a pas de serveur intermédiaire. La
reconnaissance de cartes s'exécute embarquée ; `api/` ne sert qu'à ingérer les données et à
construire l'index d'empreintes.

→ Détail complet dans [`docs/architecture.md`](./docs/architecture.md).

## Crédits et sources de données

DeckHand n'existe que grâce à ces services, qui ouvrent gratuitement leurs données.

- **[Scryfall](https://scryfall.com)** — catalogue des cartes, noms localisés, légalités par
  format, identité couleur et prix. DeckHand respecte leurs
  [directives d'API](https://scryfall.com/docs/api) : débit limité, `User-Agent` identifiant,
  et usage des exports groupés plutôt que des appels unitaires.
- **[TopDeck.gg](https://topdeck.gg)** — decklists de tournoi pour les formats 60 cartes.
  Données fournies par l'[API TopDeck.gg](https://topdeck.gg/docs/tournaments-v2).
- **[EDHTop16](https://edhtop16.com)** — decklists de Commander compétitif.
- **[MTGJSON](https://mtgjson.com)** — decks préconstruits officiels, sous licence MIT.

Aucune donnée issue de ces sources n'est versionnée dans ce dépôt : elle est téléchargée à
l'exécution, dans le respect des conditions de chaque fournisseur.

## Mentions légales

Contenu non officiel de fan. Non approuvé par Wizards of the Coast. Certains éléments sont la
propriété de Wizards of the Coast LLC, filiale de Hasbro, Inc. DeckHand n'est affilié ni à
Wizards of the Coast, ni à aucune des sources de données citées.

Projet personnel, sans finalité commerciale.
