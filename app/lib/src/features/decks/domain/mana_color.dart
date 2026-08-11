/// Les cinq couleurs de Magic, telles qu'on les désigne et telles qu'on les voit.
///
/// **Le symbole est celui de Scryfall** (`W`, `U`, `B`, `R`, `G`) : il part tel
/// quel dans les appels au serveur, où il est comparé à `cards.color_identity`.
/// Le bleu est `U` et non `B`, lequel désigne le noir — c'est une convention du
/// jeu, pas une coquille.
///
/// **L'ordre est WUBRG**, celui du dos des cartes et de toutes les listes de
/// decks depuis trente ans. Le trier autrement, fût-ce alphabétiquement, ferait
/// hésiter un joueur devant une rangée qu'il lit d'habitude sans regarder.
///
/// **La teinte n'est plus ce qu'on montre, mais ce qui tient la place.** Les
/// pastilles portaient une lettre — `W`, `U`, `B` — là où un joueur attend le
/// symbole imprimé sur ses cartes. Celui-ci est désormais servi par Scryfall
/// (voir `manaSymbolUrl`), et `swatch` ne sert plus qu'aux quartiers de la
/// roue-résumé et à l'attente du réseau. Les teintes restent donc celles du dos
/// de carte, plus saturées que les symboles officiels, qui sont pastel.
library;

import 'package:flutter/material.dart';

class ManaColor {
  const ManaColor(this.symbol, this.label, this.swatch);

  /// Symbole Scryfall, envoyé au serveur — et nom du fichier de son icône.
  final String symbol;

  /// Nom français, pour l'infobulle.
  final String label;

  final Color swatch;
}

const manaColors = <ManaColor>[
  ManaColor('W', 'Blanc', Color(0xFFF3E9C8)),
  ManaColor('U', 'Bleu', Color(0xFF3A7DC1)),
  ManaColor('B', 'Noir', Color(0xFF2E2A31)),
  ManaColor('R', 'Rouge', Color(0xFFC0453A)),
  ManaColor('G', 'Vert', Color(0xFF3E8A5B)),
];

/// Ce qu'on demande d'une couleur.
///
/// **Trois états et non deux.** Cocher une couleur veut dire « j'en veux » ;
/// il manquait le moyen de dire « surtout pas ». « Du rouge, mais pas de bleu »
/// est pourtant la question qu'on se pose devant sa collection — on connaît ses
/// couleurs, et celles qu'on ne jouera pas.
enum ManaChoice {
  /// Indifférent : la couleur peut être là ou non.
  neutral,

  /// Le deck doit la porter.
  wanted,

  /// Le deck ne doit pas la porter.
  banned;

  /// Un appui fait passer à l'état suivant, et le troisième revient au départ.
  ManaChoice get next => switch (this) {
    ManaChoice.neutral => ManaChoice.wanted,
    ManaChoice.wanted => ManaChoice.banned,
    ManaChoice.banned => ManaChoice.neutral,
  };
}
