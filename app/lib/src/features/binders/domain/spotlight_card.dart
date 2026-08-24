/// Une carte qu'un spectateur a fait monter sur l'overlay (#21).
///
/// **Ce que la désignation ajoute au calque.** L'overlay montrait ce que le
/// diffuseur scanne ; il montre désormais aussi ce qu'on lui demande de sortir
/// du classeur. C'est la seule interaction du chantier qui aille du chat vers
/// l'écran, et donc la seule qui **écrive** — voir la migration
/// `collection_spotlight`, qui explique ce qu'un inconnu peut au pire.
///
/// **Le calque n'arbitre rien qu'il ne puisse voir.** La carte rendue ici est
/// déjà passée par le filtre de portée côté base : une extension retirée du
/// partage disparaît du calque, même si la demande est antérieure au retrait.
/// Cette classe n'a donc aucune règle de visibilité à porter, et ne doit pas en
/// gagner — ce serait un second endroit où se tromper.
///
/// **`requestId` dit qu'une demande est neuve**, exactement comme `movementId`
/// côté journal : deux spectateurs qui désignent la même carte sont deux
/// événements, et le calque doit rejouer pour le second.
library;

class SpotlightCard {
  const SpotlightCard({
    required this.requestId,
    required this.name,
    this.printedName,
    this.requestedBy,
    this.setCode,
    this.collectorNumber,
    this.artCropUrl,
    this.priceEur,
    this.copies = 0,
  });

  /// Identifiant de la demande. Neuf à chaque désignation acceptée, y compris
  /// quand la carte ne change pas.
  final int requestId;

  final String name;
  final String? printedName;

  /// Le pseudonyme du demandeur, borné côté base. `null` quand il manque : la
  /// bannière s'en passe plutôt que d'inventer « anonyme ».
  final String? requestedBy;

  final String? setCode;
  final String? collectorNumber;
  final String? artCropUrl;
  final double? priceEur;

  /// Exemplaires possédés de cette case. Une désignation ne peut porter que sur
  /// une carte possédée — la base le vérifie — donc ce nombre est au moins un.
  final int copies;

  String get displayName => printedName ?? name;

  factory SpotlightCard.fromJson(Map<String, dynamic> json) => SpotlightCard(
    requestId: (json['request_id'] as num).toInt(),
    name: json['name'] as String? ?? '',
    printedName: json['printed_name'] as String?,
    requestedBy: json['requested_by'] as String?,
    setCode: json['set_code'] as String?,
    collectorNumber: json['collector_number'] as String?,
    artCropUrl: json['art_crop_url'] as String?,
    priceEur: (json['price_eur'] as num?)?.toDouble(),
    copies: (json['copies'] as num?)?.toInt() ?? 0,
  );
}
