/// Une ligne de collection : une carte et le nombre d'exemplaires possédés.
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
  });

  final String oracleId;

  /// Nom oracle anglais, identité canonique de la carte.
  final String name;

  /// Nom français, quand la traduction est connue.
  final String? printedName;

  final String? typeLine;
  final int quantity;

  /// Prix de l'impression la moins chère.
  final double? unitPriceEur;

  /// Prix unitaire multiplié par la quantité. Calculé côté base pour que
  /// l'affichage et le total ne puissent pas diverger.
  final double? linePriceEur;

  final bool legalPauper;
  final bool legalModern;
  final bool legalCommander;

  /// Première fois que la carte est entrée en collection.
  final DateTime? addedAt;

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
  });

  final int totalCards;
  final int distinctCards;

  /// Valeur totale. Les cartes sans cote connue comptent pour zéro : mieux vaut
  /// sous-estimer que d'inventer un prix.
  final double totalValueEur;

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
