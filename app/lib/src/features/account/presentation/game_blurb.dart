/// Ce qu'une tuile dit d'un jeu : ses chiffres, et sa réserve s'il en a une.
///
/// **Une source unique parce que deux écrans les affichent** — le sélecteur et
/// l'étape de choix des jeux. Recopiés, ces textes auraient divergé dès la
/// prochaine ingestion : ce sont des chiffres, et ils bougent.
library;

import '../../../config/selected_game.dart';

/// Les chiffres du catalogue, tels qu'ils s'affichent sous le nom du jeu.
String gameDetail(Game game) => switch (game) {
  Game.magic => '32 918 cartes, 1 028 decks',
  // 929 et non 1 035 : le catalogue enregistrait deux fois les cartes dont la
  // source réécrit le nom ou le texte d'une extension à l'autre. L'identité
  // tient désormais au titre, au type et au champion.
  Game.riftbound => '929 cartes, 2 500 decks',
  Game.yugioh => '13 866 cartes, 3 935 decks',
  Game.pokemon => '20 964 cartes, 23 574 decks',
  // **Le seul jeu sans decks, et ce n'est pas un retard** : aucun corpus de
  // listes n'est publié pour lui. La tuile annonce donc les cartes seules —
  // écrire « 0 deck » se lirait comme une panne là où c'est une propriété du
  // jeu.
  Game.wankul => '958 cartes',
  Game.swu => '2 180 cartes, 5 038 decks',
  Game.onepiece => '2 541 cartes, 2 526 decks',
  Game.lorcana => '2 517 cartes, 124 decks',
};

/// La réserve à faire connaître avant de choisir ce jeu, ou `null`.
String? gameNote(Game game) => switch (game) {
  // **Les prix Riftbound sont convertis, et ça se dit ici.** Ils sont relevés
  // en dollars chez TCGplayer ; l'euro affiché passe par le taux de la BCE et
  // n'est donc pas un prix de marché européen. Le chiffre est bon, sa
  // provenance mérite d'être connue avant qu'on décide d'acheter sur sa foi.
  // Les jeux servis par TCGCSV sont dans le même cas.
  Game.riftbound ||
  Game.yugioh ||
  Game.pokemon ||
  Game.swu ||
  Game.onepiece ||
  Game.lorcana => 'Prix convertis du dollar au taux de la BCE',
  Game.magic => null,
  // **Wankul n'aura pas de prix, et ce n'est pas un retard.** Les autres jeux
  // sont cotés parce qu'ils ont un marché secondaire indexé — TCGplayer, relevé
  // par TCGCSV. Wankul se vend en direct par son éditeur, et la recherche a été
  // menée : ni TCGCSV, ni Cardmarket, ni aucun index public ne le cote carte par
  // carte (voir `docs/multi-game.md` §9). La collection s'y compte et s'y range,
  // elle ne s'y valorise pas.
  Game.wankul => 'Sans valorisation : aucun index ne cote ce jeu',
};
