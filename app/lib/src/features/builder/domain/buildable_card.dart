/// Une carte de la collection, telle que le constructeur de decks la voit.
///
/// **Ce n'est pas une ligne de collection.** Une ligne de collection décrit ce
/// qu'on possède — édition, finition, prix payé. Le constructeur, lui, ne
/// s'intéresse qu'à ce que la carte *fait* : son coût, son type, ses couleurs,
/// son texte. Deux exemplaires d'éditions différentes sont ici la même carte, et
/// c'est heureux : en Commander, on ne peut de toute façon en jouer qu'un.
///
/// Le texte oracle est là pour une seule raison : reconnaître les rôles. Aucun
/// catalogue ne dit qu'une carte « sert de retrait », mais son texte dit
/// « Destroy target ». Voir [CardRole].
library;

/// Identité couleur, en symboles Scryfall (`W`, `U`, `B`, `R`, `G`).
typedef ColorIdentity = Set<String>;

class BuildableCard {
  const BuildableCard({
    required this.oracleId,
    required this.name,
    required this.typeLine,
    required this.cmc,
    required this.colorIdentity,
    this.manaCost = '',
    this.printedName,
    this.oracleText = '',
    this.quantity = 1,
    this.priceEur,
  });

  final String oracleId;

  /// Nom oracle anglais — l'identité canonique de la carte.
  final String name;

  /// Nom français quand il existe : c'est celui qu'on lit sur la carte en main.
  final String? printedName;

  final String typeLine;

  /// Coût converti de mana. Zéro pour un terrain, ce qui est exact et explique
  /// qu'on les exclue de la courbe : ils l'écraseraient.
  final double cmc;

  /// Coût tel qu'il est imprimé sur la carte — `{2}{B}`, `{X}{R}`.
  ///
  /// **C'est lui qu'on affiche, jamais le coût converti.** Dans une liste de
  /// deck, un nombre nu devant un nom de carte se lit comme une quantité : la
  /// convention est universelle, et l'ignorer faisait croire à quatre
  /// exemplaires d'une carte qu'on ne peut jouer qu'en un seul. Le coût
  /// converti reste utile au calcul de la courbe, où il ne s'affiche pas.
  final String manaCost;

  final ColorIdentity colorIdentity;
  final String oracleText;

  /// Exemplaires possédés. Sert aux formats à quatre exemplaires ; en
  /// Commander, tout se joue en un seul de toute façon.
  final int quantity;

  final double? priceEur;

  String get displayName => printedName ?? name;

  bool get isLand => typeLine.contains('Land');

  /// Terrain de base : illimité et gratuit, il ne se choisit pas, il se
  /// complète. Le motif est celui de la base — « Basic Land — Plains », « Basic
  /// Snow Land — Island » — et laisse hors les terrains légendaires.
  bool get isBasicLand => typeLine.startsWith('Basic Land');

  bool get isCreature => typeLine.contains('Creature');

  /// Créature légendaire : candidate à être le général d'un deck Commander.
  bool get canCommand => typeLine.contains('Legendary Creature');

  /// Vrai si cette carte peut entrer dans un deck d'identité [identity].
  ///
  /// La règle du Commander : l'identité d'une carte doit être **contenue** dans
  /// celle du général. Une carte incolore entre partout, ce qui en fait la
  /// monnaie d'échange de tous les decks.
  bool playableIn(ColorIdentity identity) =>
      colorIdentity.every(identity.contains);
}
