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

/// **Cinq types, et ce sont ceux du jeu** — le vocabulaire de la source, qui
/// est aussi celui imprimé sur la carte. Ils partitionnent le catalogue sans
/// reste : 1 369 unités, 414 événements, 154 leaders, 154 améliorations,
/// 90 bases.
///
/// C'est le même vocabulaire qui décide de la fenêtre d'illustration, un
/// événement portant la sienne en bas et un leader étant imprimé en travers.
/// Un type ne sert donc pas qu'à filtrer ici : il traverse le produit.
const _swuTypes = [
  CardType('Unit', 'Unité'),
  CardType('Event', 'Événement'),
  CardType('Upgrade', 'Amélioration'),
  CardType('Leader', 'Leader'),
  CardType('Base', 'Base'),
];

/// One Piece — cinq types, dont le Leader qui ne se joue pas dans le deck.
///
/// Il figure quand même : on le possède, on le range en classeur, et on le
/// cherche pour choisir son deck. Ne pas le lister le rendrait introuvable
/// alors qu'il est la carte la plus structurante du jeu. Même raison que la
/// Base et le Leader de SWU.
const _onepieceTypes = [
  CardType('Character', 'Personnage'),
  CardType('Event', 'Événement'),
  CardType('Stage', 'Décor'),
  CardType('Leader', 'Leader'),
];

/// Disney Lorcana — quatre types publiés, la Chanson étant une Action.
///
/// « Action Song » est la ligne de type d'une Chanson : la lister à part
/// laisserait croire qu'elle n'est pas une Action, alors que tout ce qui vaut
/// pour l'une vaut pour l'autre.
const _lorcanaTypes = [
  CardType('Character', 'Personnage'),
  CardType('Action', 'Action'),
  CardType('Item', 'Objet'),
  CardType('Location', 'Lieu'),
];

List<CardType> cardTypesFor(Game game) => switch (game) {
  Game.magic => _magicTypes,
  Game.riftbound => _riftboundTypes,
  Game.yugioh => _yugiohTypes,
  Game.pokemon => _pokemonTypes,
  Game.wankul => _wankulTypes,
  Game.swu => _swuTypes,
  Game.onepiece => _onepieceTypes,
  Game.lorcana => _lorcanaTypes,
};
