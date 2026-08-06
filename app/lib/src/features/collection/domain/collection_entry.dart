/// Une ligne de collection : une carte, une édition, et le nombre d'exemplaires.
///
/// **Une carte possédée en deux éditions donne deux lignes.** C'est voulu : elles
/// n'ont ni le même prix ni la même place dans une boîte. `printId` nul signifie
/// « je possède cette carte, je n'ai pas dit laquelle » — un état de plein droit,
/// puisqu'on saisit vite et qu'on précise plus tard.
library;

class CollectionEntry {
  const CollectionEntry({
    required this.oracleId,
    required this.name,
    required this.quantity,
    required this.legalPauper,
    required this.legalModern,
    required this.legalCommander,
    this.printedName,
    this.typeLine,
    this.unitPriceEur,
    this.linePriceEur,
    this.addedAt,
    this.printId,
    this.setCode,
    this.setName,
    this.collectorNumber,
  });

  final String oracleId;

  /// Nom oracle anglais, identité canonique de la carte.
  final String name;

  /// Nom français, quand la traduction est connue.
  final String? printedName;

  final String? typeLine;
  final int quantity;

  /// Prix unitaire : celui de l'édition possédée quand elle est connue, celui de
  /// l'impression la moins chère sinon.
  final double? unitPriceEur;

  /// Prix unitaire multiplié par la quantité. Calculé côté base pour que
  /// l'affichage et le total ne puissent pas diverger.
  final double? linePriceEur;

  final bool legalPauper;
  final bool legalModern;
  final bool legalCommander;

  /// Première fois que la carte est entrée en collection.
  final DateTime? addedAt;

  /// Édition possédée. Nul tant qu'elle n'a pas été précisée.
  final String? printId;
  final String? setCode;
  final String? setName;
  final String? collectorNumber;

  bool get hasPrinting => printId != null;

  /// Édition telle qu'affichée : « Modern Horizons 2 · MH2 #123 ».
  String? get printingLabel {
    if (setCode == null) return null;
    final number = collectorNumber == null ? '' : ' #$collectorNumber';
    return '${setName ?? setCode!.toUpperCase()} · ${setCode!.toUpperCase()}$number';
  }

  /// Nom à afficher : le français s'il existe, l'anglais sinon.
  String get displayName => printedName ?? name;

  factory CollectionEntry.fromJson(Map<String, dynamic> json) {
    double? toDouble(Object? v) => v == null ? null : (v as num).toDouble();
    return CollectionEntry(
      oracleId: json['oracle_id'] as String,
      name: json['name'] as String,
      printedName: json['printed_name'] as String?,
      typeLine: json['type_line'] as String?,
      quantity: (json['quantity'] as num).toInt(),
      unitPriceEur: toDouble(json['unit_price_eur']),
      linePriceEur: toDouble(json['line_price_eur']),
      legalPauper: json['legal_pauper'] as bool? ?? false,
      legalModern: json['legal_modern'] as bool? ?? false,
      legalCommander: json['legal_commander'] as bool? ?? false,
      addedAt: json['added_at'] == null
          ? null
          : DateTime.tryParse(json['added_at'] as String),
      printId: json['print_id'] as String?,
      setCode: json['set_code'] as String?,
      setName: json['set_name'] as String?,
      collectorNumber: json['collector_number'] as String?,
    );
  }
}

/// Agrégats de la collection **entière**.
///
/// Calculés par le serveur, jamais depuis la page affichée : une page ne porte
/// qu'une partie des cartes, et en déduire un total afficherait « 50 cartes »
/// en première page puis « 30 » en seconde.
class CollectionSummary {
  const CollectionSummary({
    required this.totalCards,
    required this.distinctCards,
    required this.totalValueEur,
    this.unspecifiedPrints = 0,
  });

  final int totalCards;
  final int distinctCards;

  /// Valeur totale. Les cartes sans cote connue comptent pour zéro : mieux vaut
  /// sous-estimer que d'inventer un prix.
  final double totalValueEur;

  /// Exemplaires dont l'édition n'a pas été précisée. Sert à proposer de la
  /// renseigner plutôt qu'à le reprocher : ne pas préciser reste légitime.
  final int unspecifiedPrints;

  bool get isEmpty => totalCards == 0;

  static const empty = CollectionSummary(
    totalCards: 0,
    distinctCards: 0,
    totalValueEur: 0,
  );

  factory CollectionSummary.fromJson(Map<String, dynamic> json) =>
      CollectionSummary(
        totalCards: (json['total_cards'] as num?)?.toInt() ?? 0,
        distinctCards: (json['distinct_cards'] as num?)?.toInt() ?? 0,
        totalValueEur: (json['total_value_eur'] as num?)?.toDouble() ?? 0,
        unspecifiedPrints: (json['unspecified_prints'] as num?)?.toInt() ?? 0,
      );
}

/// Critères de consultation de la collection.
enum CollectionSort {
  name('name', 'Nom'),
  price('price', 'Valeur'),
  quantity('quantity', 'Quantité'),
  recent('recent', 'Récent');

  const CollectionSort(this.id, this.label);

  final String id;
  final String label;
}
