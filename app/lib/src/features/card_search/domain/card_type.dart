/// Types de cartes proposés comme filtres de recherche.
///
/// **Pourquoi filtrer par type.** Chercher « marais » rend une cinquantaine de
/// cartes dont une poignée seulement sont des terrains : les créatures, les
/// éphémères et les enchantements dont le nom contient le mot noient celui qu'on
/// tient. Le type est ce que l'œil vérifie juste après le nom, et c'est la
/// coupe la plus économique qu'on puisse offrir à la saisie.
///
/// **[kind] est une sous-chaîne anglaise de la ligne de type**, pas une
/// catégorie fermée. Une carte cumule ses types (« Artifact Creature — Golem »)
/// et répond donc aux deux filtres, ce qui est la lecture juste. Le libellé,
/// lui, est français : c'est l'utilisateur qui lit.
///
/// **Les types dépendent du jeu.** Magic en compte huit d'usage courant,
/// Riftbound six, et rien ne les recouvre. Proposer les uns dans l'autre
/// catalogue offrirait des filtres qui ne rendent jamais rien.
library;

import '../../../config/selected_game.dart';

class CardType {
  const CardType(this.kind, this.label);

  /// Sous-chaîne cherchée dans `type_line`, en anglais comme le catalogue.
  final String kind;

  /// Libellé affiché, en français.
  final String label;
}

/// Types Magic, dans l'ordre où ils peuplent le catalogue : une carte au hasard
/// a bien plus de chances d'être une créature qu'une bataille, et le filtre le
/// plus probable doit être le plus proche du pouce.
const _magicTypes = <CardType>[
  CardType('Creature', 'Créature'),
  CardType('Instant', 'Éphémère'),
  CardType('Sorcery', 'Rituel'),
  CardType('Enchantment', 'Enchantement'),
  CardType('Artifact', 'Artefact'),
  CardType('Land', 'Terrain'),
  CardType('Planeswalker', 'Planeswalker'),
  CardType('Battle', 'Bataille'),
  // Les jetons portent « Token » en tête de leur ligne de type. Ils répondent
  // aussi au filtre de leur type de jeu — un jeton de créature est une créature
  // —, ce qui est exact et laisse celui-ci pour les isoler.
  CardType('Token', 'Jeton'),
];

const _riftboundTypes = <CardType>[
  CardType('Unit', 'Unité'),
  CardType('Spell', 'Sort'),
  CardType('Gear', 'Équipement'),
  CardType('Legend', 'Légende'),
  CardType('Battlefield', 'Champ de bataille'),
  CardType('Rune', 'Rune'),
];

List<CardType> cardTypesFor(Game game) => switch (game) {
  Game.magic => _magicTypes,
  Game.riftbound => _riftboundTypes,
};
