/// Un deck confronté à la collection de l'utilisateur.
library;

import '../../../config/selected_game.dart';

/// Les formats couverts, dans l'ordre où ils sont proposés.
///
/// Pauper vient en tête : c'est le seul où une collection Magic ordinaire
/// produit des decks réellement complets, les cartes chères en étant exclues
/// d'office.
enum DeckFormat {
  pauper('pauper', 'Pauper'),
  modern('modern', 'Modern'),
  commander('commander', 'Commander'),
  constructed('constructed', 'Construit'),
  edison('edison', 'Edison'),
  goat('goat', 'Goat'),
  redu('redu', 'REDU'),
  hat('hat', 'HAT'),

  /// Pokémon. **Standard porte 99,5 % du corpus importé** — 17 295 decks sur
  /// 17 380 — quand GLC en a 58, EX 14 et Expanded 9. C'est l'exact inverse de
  /// Yu-Gi-Oh, où les formats rétro portaient 97 % du corpus.
  ///
  /// Cela dessert plutôt le produit : Standard tourne sur des extensions
  /// récentes, donc chères et peu probables dans une collection ordinaire. Mais
  /// c'est ce que la source publie, et inventer un format mieux servi serait
  /// pire qu'un format cher.
  standard('standard', 'Standard'),

  /// Wankul. **Un format distinct de `constructed`, et non son partage.**
  /// Riftbound porte déjà `constructed`, or `DeckBlueprint.of` ne reçoit que le
  /// format, jamais le jeu : partager l'identifiant ferait partager le gabarit,
  /// et un deck Wankul se construirait sur les proportions d'un autre jeu sans
  /// que rien ne l'annonce. Le nom vient des « règles de tournoi » publiées par
  /// l'éditeur, qui est le vocabulaire du jeu.
  tournament('tournament', 'Tournoi'),

  /// Star Wars Unlimited. **Le seul format qui porte le corpus**, et il est
  /// mesuré : `Premier` couvre 19 tournois sur 20, tous officiels, le
  /// vingtième n'en déclarant aucun.
  ///
  /// Comme `tournament` pour Wankul, c'est un identifiant distinct plutôt
  /// qu'un partage de `constructed` : `DeckBlueprint.of` ne reçoit que le
  /// format, jamais le jeu, et partager l'identifiant ferait construire un deck
  /// SWU sur les proportions d'un autre jeu sans que rien ne l'annonce.
  premier('premier', 'Premier');

  const DeckFormat(this.id, this.label);

  final String id;
  final String label;
}

const _magicFormats = [
  DeckFormat.pauper,
  DeckFormat.modern,
  DeckFormat.commander,
];

const _riftboundFormats = [DeckFormat.constructed];

/// **Quatre formats rétro, et pas le format courant du jeu.** Le premier jet
/// déclarait `Advanced` — le format de tournoi actuel — sur la foi de son nom.
/// Mesuré sur un an chez TopDeck.gg, il porte **3 decklists sur 168 tournois**,
/// quand Edison en porte 3 069, Goat 485, REDU 320 et HAT 81 : 97 % du corpus
/// est dans les formats rétro. L'onglet `Advanced` serait resté vide.
///
/// Ce n'est pas un pis-aller, c'est le meilleur cas pour ce produit : un format
/// rétro puise dans un pool figé et ancien, donc des cartes disponibles et bon
/// marché, là où un format courant demande les raretés récentes que personne ne
/// possède par accident. Edison vient en tête pour la même raison que Pauper
/// chez Magic — c'est là qu'une collection ordinaire produit des decks complets.
const _yugiohFormats = [
  DeckFormat.edison,
  DeckFormat.goat,
  DeckFormat.redu,
  DeckFormat.hat,
];

/// Formats proposés pour un jeu.
///
/// **Un format n'appartient qu'à un jeu**, et proposer les trois formats Magic
/// en Riftbound afficherait trois onglets vides — un écran qui a l'air en panne
/// alors qu'il dit la vérité. Le pendant existe déjà pour les types de cartes
/// (`cardTypesFor`).
const _pokemonFormats = [DeckFormat.standard];

const _wankulFormats = [DeckFormat.tournament];

const _swuFormats = [DeckFormat.premier];

List<DeckFormat> deckFormatsFor(Game game) => switch (game) {
  Game.magic => _magicFormats,
  Game.riftbound => _riftboundFormats,
  Game.yugioh => _yugiohFormats,
  Game.pokemon => _pokemonFormats,
  Game.wankul => _wankulFormats,
  Game.swu => _swuFormats,
};

class DeckSuggestion {
  const DeckSuggestion({
    required this.deckId,
    required this.deckName,
    required this.tier,
    required this.sourceName,
    required this.totalCards,
    required this.ownedCards,
    required this.missingCards,
    required this.completion,
    required this.missingCostEur,
    this.attribution,
    this.colors = const [],
    this.commanderOracleId,
    this.commanderName,
    this.commanderOwned = false,
    this.basicLands = 0,
  });

  final String deckId;
  final String deckName;

  /// `accessible` (précon, deck budget) ou `competitive` (liste de tournoi).
  /// Sans cette distinction, proposer un deck à 800 € comme « presque à portée »
  /// rendrait la promesse du produit mensongère.
  final String tier;

  final String sourceName;

  /// Mention de crédit exigée par la source. Obligation contractuelle pour
  /// TopDeck.gg : elle doit rester affichée.
  final String? attribution;

  final int totalCards;
  final int ownedCards;
  final int missingCards;

  /// Part du deck déjà possédée, entre 0 et 1.
  final double completion;

  /// Coût des cartes manquantes. Les cartes sans cote comptent pour zéro.
  final double missingCostEur;

  /// Identité couleur du deck : l'union de celle de ses cartes, dans l'ordre
  /// WUBRG. Vide pour un deck incolore, qui se joue partout.
  final List<String> colors;

  /// Commandant du deck, quand le format en a un.
  ///
  /// **C'est lui qui identifie un deck Commander**, bien mieux que sa
  /// provenance : on choisit son général avant tout le reste, et deux listes
  /// portant le même nom de produit n'ont rien à voir si leurs commandants
  /// diffèrent.
  final String? commanderOracleId;

  /// Nom du commandant, en français quand la traduction existe.
  final String? commanderName;

  /// Vrai si le commandant est déjà en collection.
  ///
  /// **C'est la carte qui décide si un deck est un projet ou une liste de
  /// courses** : sans le général, les quatre-vingt-dix-neuf autres cartes ne
  /// forment pas un deck, et c'est souvent la plus chère de la liste.
  final bool commanderOwned;

  /// Terrains de base du deck, exclus de tous les autres décomptes.
  ///
  /// **On ne les achète pas, on les prend dans la boîte.** Les compter comme
  /// des cartes à acquérir donnait le même pourcentage à un deck dont on a le
  /// thème et à un deck dont on n'a rien — trente terrains suffisaient à
  /// afficher 30 % partout, et le classement n'apprenait plus rien.
  ///
  /// Leur nombre reste affiché : une liste de cent cartes annoncée sur
  /// soixante-seize se justifie d'elle-même.
  final int basicLands;

  bool get hasCommander => commanderOracleId != null && commanderName != null;

  bool get isBuildable => missingCards == 0;
  bool get isCompetitive => tier == 'competitive';

  factory DeckSuggestion.fromJson(Map<String, dynamic> json) {
    double toDouble(Object? v) => v == null ? 0 : (v as num).toDouble();
    return DeckSuggestion(
      deckId: json['deck_id'] as String,
      deckName: json['deck_name'] as String,
      tier: json['tier'] as String? ?? 'competitive',
      sourceName: json['source_name'] as String? ?? '',
      attribution: json['attribution'] as String?,
      totalCards: (json['total_cards'] as num).toInt(),
      ownedCards: (json['owned_cards'] as num).toInt(),
      missingCards: (json['missing_cards'] as num).toInt(),
      completion: toDouble(json['completion']),
      missingCostEur: toDouble(json['missing_cost_eur']),
      colors:
          (json['colors'] as List<dynamic>?)?.cast<String>().toList(
            growable: false,
          ) ??
          const [],
      commanderOracleId: json['commander_oracle_id'] as String?,
      commanderName: json['commander_name'] as String?,
      commanderOwned: json['commander_owned'] as bool? ?? false,
      basicLands: (json['basic_lands'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Une carte qu'il faut encore acquérir.
class MissingCard {
  const MissingCard({
    required this.oracleId,
    required this.name,
    required this.needed,
    required this.owned,
    required this.missing,
    this.printedName,
    this.unitPriceEur,
    this.lineCostEur,
  });

  final String oracleId;
  final String name;
  final String? printedName;
  final int needed;
  final int owned;
  final int missing;
  final double? unitPriceEur;
  final double? lineCostEur;

  String get displayName => printedName ?? name;

  factory MissingCard.fromJson(Map<String, dynamic> json) {
    double? toDouble(Object? v) => v == null ? null : (v as num).toDouble();
    return MissingCard(
      oracleId: json['oracle_id'] as String,
      name: json['name'] as String,
      printedName: json['printed_name'] as String?,
      needed: (json['needed'] as num).toInt(),
      owned: (json['owned'] as num).toInt(),
      missing: (json['missing'] as num).toInt(),
      unitPriceEur: toDouble(json['unit_price_eur']),
      lineCostEur: toDouble(json['line_cost_eur']),
    );
  }
}
