/// Le classeur : une édition rangée case par case, vides comprises.
///
/// **Un classeur est une édition, une case est un numéro.** Rien n'est stocké :
/// la case est le couple `(set_code, collector_number)`, que `card_prints` porte
/// déjà. Le classeur se dérive de la collection, il ne s'y ajoute pas — on ne
/// peut donc pas le désynchroniser, puisqu'il n'en est qu'une lecture.
///
/// **Une case n'est pas une impression.** Le #412 anglais et le #412 français
/// partagent la même case : la langue est une propriété de ce qu'on y range. Le
/// brillant non plus ne dédouble pas la case — deux cases pour le même numéro
/// casseraient la grille physique ; il est signalé sur celle qu'il occupe.
///
/// **Ce que le classeur montre vraiment, ce sont les cases vides.** C'est une
/// vue de complétion d'édition, et c'est ce qui la rend intéressante à regarder :
/// une liste de possessions dit ce qu'on a, un classeur dit ce qui manque.
library;

import '../../printings/domain/scryfall_image.dart';

/// Neuf cases par page, comme une feuille de classeur physique.
const int binderPageSize = 9;

/// Comment lire un classeur.
///
/// **Deux régimes, et la différence porte sur les cases vides.** Par
/// [number], le classeur range : les cases vides figurent, parce que la question
/// posée est « que me manque-t-il ». Par [price] ou [name], il inventorie — « mes
/// cartes, de la plus chère à la moins chère » — et une case vide n'a alors ni
/// valeur, ni nom, ni place dans un ordre qui ignore les numéros. Elle disparaît,
/// et c'est ce que la demande implique : on ne regarde plus ce qui manque, on
/// regarde ce qu'on a.
///
/// Le filtre de finition, lui, ne change pas de régime : restreindre au brillant
/// laisse les trous, car « je n'ai pas cette carte en brillant » reste une
/// complétion.
enum BinderSort {
  number('number', 'Numéro'),
  price('price', 'Valeur'),
  name('name', 'Nom');

  const BinderSort(this.id, this.label);

  final String id;
  final String label;

  /// Vrai quand les cases vides ont un sens — donc quand une page peut être
  /// entièrement creuse, et qu'il faut savoir où commencer.
  bool get keepsEmptyCells => this == BinderSort.number;
}

/// Une édition sur l'étagère, avec ce qu'on en possède.
class BinderShelfEntry {
  const BinderShelfEntry({
    required this.setCode,
    required this.setName,
    required this.totalCells,
    required this.ownedCells,
    required this.ownedCopies,
    this.releasedAt,
  });

  final String setCode;
  final String setName;

  /// Nombre de cases de l'édition entière — la taille du classeur, et non ce
  /// qu'on en possède. C'est ce qui rend la complétion lisible.
  final int totalCells;

  /// Cases occupées par au moins un exemplaire.
  final int ownedCells;

  /// Exemplaires rangés, doublons compris. Diffère de [ownedCells] dès qu'on
  /// possède une carte en plusieurs exemplaires.
  final int ownedCopies;

  final DateTime? releasedAt;

  /// Part de l'édition possédée, entre 0 et 1.
  double get completion => totalCells == 0 ? 0 : ownedCells / totalCells;

  /// Nombre de pages de neuf cases, arrondi au supérieur.
  int get pages => totalCells == 0 ? 0 : (totalCells + binderPageSize - 1) ~/ binderPageSize;

  factory BinderShelfEntry.fromJson(Map<String, dynamic> json) => BinderShelfEntry(
    setCode: json['set_code'] as String,
    setName: (json['set_name'] as String?) ?? (json['set_code'] as String).toUpperCase(),
    totalCells: (json['total_cells'] as num?)?.toInt() ?? 0,
    ownedCells: (json['owned_cells'] as num?)?.toInt() ?? 0,
    ownedCopies: (json['owned_copies'] as num?)?.toInt() ?? 0,
    releasedAt: json['released_at'] == null
        ? null
        : DateTime.tryParse(json['released_at'] as String),
  );
}

/// Une carte de la pile à trier : possédée, mais sans case.
///
/// **Ce n'est pas une case et la classe le dit** — aucun numéro de collection,
/// aucune extension. Une carte dont l'édition n'est pas précisée n'est rangeable
/// nulle part, et c'est précisément ce qui la rend invisible dans un classeur.
/// La pile existe pour qu'elle cesse de l'être.
///
/// L'illustration est celle d'une impression **représentative**, faute
/// d'impression désignée. C'est faux au sens strict et sans conséquence : cette
/// vue sert à reconnaître une carte pour lui donner son édition.
class UnsortedCard {
  const UnsortedCard({
    required this.oracleId,
    required this.name,
    required this.owned,
    this.printedName,
    this.artCropUrl,
    this.priceEur,
    this.hasFoil = false,
  });

  final String oracleId;
  final String name;
  final String? printedName;
  final int owned;
  final String? artCropUrl;
  final double? priceEur;
  final bool hasFoil;

  String get shownName => printedName ?? name;

  String? get imageUrl => fullCardImage(artCropUrl);

  factory UnsortedCard.fromJson(Map<String, dynamic> json) => UnsortedCard(
    oracleId: json['oracle_id'] as String,
    name: (json['name'] as String?) ?? '',
    printedName: json['printed_name'] as String?,
    owned: (json['owned'] as num?)?.toInt() ?? 0,
    artCropUrl: json['art_crop_url'] as String?,
    priceEur: (json['price_eur'] as num?)?.toDouble(),
    hasFoil: (json['has_foil'] as bool?) ?? false,
  );
}

/// Une case de classeur, occupée ou non.
class BinderCell {
  const BinderCell({
    required this.collectorNumber,
    required this.owned,
    this.oracleId,
    this.printId,
    this.name,
    this.printedName,
    this.rarity,
    this.artCropUrl,
    this.priceEur,
    this.hasFoil = false,
  });

  final String collectorNumber;

  /// Exemplaires possédés, toutes langues et finitions confondues. Zéro pour
  /// une case vide — qui existe malgré tout, et occupe sa place.
  final int owned;

  final String? oracleId;
  final String? printId;

  /// Nom oracle anglais.
  final String? name;

  /// Nom imprimé, français quand le catalogue le connaît.
  final String? printedName;

  final String? rarity;
  final String? artCropUrl;
  final double? priceEur;

  /// Vrai si au moins un des exemplaires rangés ici est brillant.
  final bool hasFoil;

  bool get isEmpty => owned == 0;

  /// Nom à afficher : le français d'abord, l'oracle sinon.
  String get shownName => printedName ?? name ?? '#$collectorNumber';

  /// La carte entière — cadre, nom et texte compris —, déduite de l'URL de son
  /// illustration. C'est ce qu'on range dans un classeur : une carte, pas un
  /// détail d'illustration.
  String? get imageUrl => fullCardImage(artCropUrl);

  factory BinderCell.fromJson(Map<String, dynamic> json) => BinderCell(
    collectorNumber: json['collector_number'] as String,
    owned: (json['owned'] as num?)?.toInt() ?? 0,
    oracleId: json['oracle_id'] as String?,
    printId: json['print_id'] as String?,
    name: json['name'] as String?,
    printedName: json['printed_name'] as String?,
    rarity: json['rarity'] as String?,
    artCropUrl: json['art_crop_url'] as String?,
    priceEur: (json['price_eur'] as num?)?.toDouble(),
    hasFoil: (json['has_foil'] as bool?) ?? false,
  );
}
