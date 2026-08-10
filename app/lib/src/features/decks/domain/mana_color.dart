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
/// Les teintes sont celles du dos de carte, assombries juste assez pour qu'un
/// texte reste lisible dessus dans les deux thèmes.
library;

import 'package:flutter/material.dart';

class ManaColor {
  const ManaColor(this.symbol, this.label, this.swatch, this.onSwatch);

  /// Symbole Scryfall, envoyé au serveur.
  final String symbol;

  /// Nom français, pour l'infobulle.
  final String label;

  final Color swatch;

  /// Couleur du texte posé sur la pastille.
  final Color onSwatch;
}

const manaColors = <ManaColor>[
  ManaColor('W', 'Blanc', Color(0xFFF3E9C8), Color(0xFF2B2416)),
  ManaColor('U', 'Bleu', Color(0xFF3A7DC1), Color(0xFFF2F7FC)),
  ManaColor('B', 'Noir', Color(0xFF2E2A31), Color(0xFFE8E4EA)),
  ManaColor('R', 'Rouge', Color(0xFFC0453A), Color(0xFFFBEEEC)),
  ManaColor('G', 'Vert', Color(0xFF3E8A5B), Color(0xFFEFF8F2)),
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
