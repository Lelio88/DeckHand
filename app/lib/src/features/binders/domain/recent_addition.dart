/// Une carte qui vient d'entrer dans une collection publiée.
///
/// **Ce que l'overlay montre, et d'où ça vient.** DeckHand ne touche jamais la
/// vidéo : OBS filme, DeckHand publie ce qu'il a vu, et une *browser source*
/// lit ça. La source de l'événement est le **journal des mouvements**, déjà
/// tenu par la collection — la carte annoncée est donc celle qui vient d'y
/// entrer, c'est-à-dire celle que l'utilisateur a confirmée (`CLAUDE.md`
/// §IV.8). Rien n'est publié qu'il n'ait validé.
///
/// **C'est l'illustration du catalogue qui s'affiche, pas la carte filmée** :
/// nette, droite, avec le nom et le prix, plus lisible qu'un carton sous une
/// lampe — et gratuite, la donnée étant déjà là.
library;

class RecentAddition {
  const RecentAddition({
    required this.movementId,
    required this.name,
    this.printedName,
    this.setCode,
    this.collectorNumber,
    this.artCropUrl,
    this.priceEur,
    this.isFoil = false,
    this.copiesBefore = 0,
  });

  /// Identifiant du mouvement. **C'est lui qui dit qu'une carte est nouvelle**,
  /// et non le nom : deux exemplaires successifs de la même carte doivent
  /// relancer l'animation, ce qu'une comparaison par nom manquerait.
  final int movementId;

  final String name;
  final String? printedName;
  final String? setCode;
  final String? collectorNumber;
  final String? artCropUrl;
  final double? priceEur;
  final bool isFoil;

  /// Exemplaires déjà possédés **avant** ce mouvement.
  ///
  /// C'est l'information qui a de la valeur pour un spectateur : zéro veut dire
  /// que la carte comble une case vide, davantage qu'elle est un doublon.
  final int copiesBefore;

  String get displayName => printedName ?? name;

  bool get fillsEmptySlot => copiesBefore == 0;

  factory RecentAddition.fromJson(Map<String, dynamic> json) => RecentAddition(
    movementId: (json['movement_id'] as num).toInt(),
    name: json['name'] as String? ?? '',
    printedName: json['printed_name'] as String?,
    setCode: json['set_code'] as String?,
    collectorNumber: json['collector_number'] as String?,
    artCropUrl: json['art_crop_url'] as String?,
    priceEur: (json['price_eur'] as num?)?.toDouble(),
    isFoil: json['is_foil'] as bool? ?? false,
    copiesBefore: (json['copies_before'] as num?)?.toInt() ?? 0,
  );
}
