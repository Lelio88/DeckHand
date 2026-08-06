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
    );
  }
}

/// Collection complète, avec ses agrégats.
class CollectionSummary {
  const CollectionSummary({required this.entries});

  final List<CollectionEntry> entries;

  /// Nombre total de cartes, exemplaires compris — 4 Foudre comptent pour 4.
  int get totalCards =>
      entries.fold(0, (sum, entry) => sum + entry.quantity);

  /// Nombre de cartes distinctes.
  int get distinctCards => entries.length;

  /// Valeur totale. Les cartes sans cote connue comptent pour zéro : mieux vaut
  /// sous-estimer que d'inventer un prix.
  double get totalValueEur =>
      entries.fold(0, (sum, entry) => sum + (entry.linePriceEur ?? 0));

  bool get isEmpty => entries.isEmpty;
}
