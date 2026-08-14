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

/// Types Yu-Gi-Oh, dans l'ordre où ils peuplent le catalogue : 9 318 monstres,
/// 2 867 magies, 2 076 pièges — relevé, pas supposé.
///
/// **Les familles de monstres viennent après les trois grandes coupes.** Un
/// catalogue de 14 491 cartes se scinde d'abord en monstre / magie / piège ;
/// c'est ce que l'œil vérifie en premier. Les quatre familles d'Extra Deck sont
/// proposées ensuite parce qu'elles répondent à une autre question — « qu'est-ce
/// que je peux mettre dans mon Extra ? » — et qu'elles pèsent chacune quelques
/// centaines de cartes.
const _yugiohTypes = <CardType>[
  CardType('Monster', 'Monstre'),
  // **« Spell Card » et non « Spell »**, parce que le filtre est un `ILIKE` sur
  // la ligne de type entière : « Spell » seul attrape les quelque sept cents
  // monstres de la famille *Spellcaster*, mesuré. Le vocabulaire officiel du
  // jeu dit d'ailleurs « Spell Card », et il est repris tel quel par la source.
  CardType('Spell Card', 'Magie'),
  CardType('Trap Card', 'Piège'),
  CardType('XYZ', 'XYZ'),
  CardType('Fusion', 'Fusion'),
  CardType('Synchro', 'Synchro'),
  CardType('Link', 'Lien'),
  CardType('Pendulum', 'Pendule'),
  CardType('Ritual', 'Rituel'),
];

/// **Trois familles, et elles partitionnent le jeu entier** — 17 587 Pokémon,
/// 2 844 Dresseurs, 533 Énergies sur les 20 964 cartes du catalogue. Les
/// sous-familles Dresseur (Supporter, Objet, Stade, Outil) ne sont pas
/// proposées ici : un filtre de recherche gagne à trancher large, et les trois
/// familles suffisent à couper le catalogue sans reste.
const _pokemonTypes = [
  CardType('Pokemon', 'Pokémon'),
  CardType('Trainer', 'Dresseur'),
  CardType('Energy', 'Énergie'),
];

/// **Deux types, et ils partitionnent le jeu sans reste** — Personnage ou
/// Terrain, tels que la source les nomme. C'est la coupe la plus courte de tous
/// les jeux couverts, et elle suffit : un deck se compose de 10 terrains et de
/// 40 personnages, si bien que ce filtre répond exactement à la question qu'on
/// se pose en construisant.
///
/// L'effigie (Laink, Terracid, Guest) n'est pas proposée ici : elle dit de quel
/// personnage la carte porte le visage, pas ce que la carte fait.
const _wankulTypes = [
  CardType('Personnage', 'Personnage'),
  CardType('Terrain', 'Terrain'),
];

List<CardType> cardTypesFor(Game game) => switch (game) {
  Game.magic => _magicTypes,
  Game.riftbound => _riftboundTypes,
  Game.yugioh => _yugiohTypes,
  Game.pokemon => _pokemonTypes,
  Game.wankul => _wankulTypes,
};
