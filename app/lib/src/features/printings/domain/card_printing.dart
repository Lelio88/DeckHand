/// Une édition précise d'une carte — ce qu'on tient physiquement en main.
///
/// Magic réédite sans cesse : une même carte existe en dizaines d'impressions, et
/// jusqu'à plus d'un millier pour les terrains de base. Elles diffèrent par le prix
/// (d'un facteur cent parfois), l'illustration et la langue, mais partagent le même
/// `oracle_id`, c'est-à-dire les mêmes règles.
///
/// Distinguer l'édition sert deux choses : valoriser la collection au prix réel plutôt
/// qu'à celui de la réimpression la moins chère, et retrouver sa carte dans une boîte
/// rangée par extension.
library;

class CardPrinting {
  const CardPrinting({
    required this.printId,
    required this.setCode,
    required this.lang,
    this.setName,
    this.collectorNumber,
    this.rarity,
    this.printedName,
    this.priceEur,
    this.releasedAt,
    this.owned = 0,
    this.artCropUrl,
    this.priceEurFoil,
    this.hasNonfoil = true,
    this.hasFoil = false,
  });

  /// Identifiant Scryfall de l'impression.
  final String printId;

  /// Code d'extension, tel qu'imprimé sur la carte (`LEA`, `MH2`…).
  final String setCode;

  final String? setName;
  final String? collectorNumber;
  final String? rarity;

  /// Langue de l'impression : `en` ou `fr`. Une même édition existe dans les deux,
  /// et ce n'est pas le même objet dans une collection.
  final String lang;

  /// Nom tel qu'imprimé — français sur une impression française.
  final String? printedName;

  final double? priceEur;
  final DateTime? releasedAt;

  /// Exemplaires de **cette** édition déjà en collection.
  final int owned;

  /// Cote de la version brillante, souvent le double ou le triple de l'autre.
  final double? priceEurFoil;

  /// Finitions réellement imprimées. Une carte de bundle n'existe qu'en
  /// brillant : lui proposer « normal » n'aurait aucun sens.
  final bool hasNonfoil;
  final bool hasFoil;

  /// Prix dans la finition demandée.
  double? priceFor({required bool foil}) => foil ? priceEurFoil : priceEur;

  /// Illustration de cette impression.
  ///
  /// C'est le seul repère fiable entre deux éditions d'une même extension : le
  /// numéro de collection ne figure pas toujours en évidence sur la carte, alors
  /// que l'illustration saute aux yeux quand on la compare à celle qu'on tient.
  final String? artCropUrl;

  /// Ce qui identifie l'édition à l'œil : « Modern Horizons 2 · MH2 #123 ».
  String get label {
    final number = collectorNumber == null ? '' : ' #$collectorNumber';
    return '${setName ?? setCode.toUpperCase()} · ${setCode.toUpperCase()}$number';
  }

  factory CardPrinting.fromJson(Map<String, dynamic> json) => CardPrinting(
    printId: json['print_id'] as String,
    setCode: json['set_code'] as String,
    setName: json['set_name'] as String?,
    collectorNumber: json['collector_number'] as String?,
    rarity: json['rarity'] as String?,
    lang: json['lang'] as String? ?? 'en',
    printedName: json['printed_name'] as String?,
    priceEur: (json['price_eur'] as num?)?.toDouble(),
    releasedAt: json['released_at'] == null
        ? null
        : DateTime.tryParse(json['released_at'] as String),
    owned: (json['owned'] as num?)?.toInt() ?? 0,
    artCropUrl: json['art_crop_url'] as String?,
    priceEurFoil: (json['price_eur_foil'] as num?)?.toDouble(),
    hasNonfoil: json['has_nonfoil'] as bool? ?? true,
    hasFoil: json['has_foil'] as bool? ?? false,
  );
}
