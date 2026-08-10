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
    this.isFoil = false,
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

  /// Exemplaire brillant. Fait partie de l'identité de la ligne : la même
  /// carte en normal et en brillant occupe deux lignes distinctes.
  final bool isFoil;

  bool get hasPrinting => printId != null;

  /// Édition telle qu'affichée : « Modern Horizons 2 · MH2 ».
  ///
  /// Le numéro n'y figure pas : il accompagne le nom de la carte, là où on le
  /// cherche pour ranger. Le répéter ici allongerait une ligne qui doit tenir
  /// sur la largeur d'un téléphone.
  String? get printingLabel {
    if (setCode == null) return null;
    return '${setName ?? setCode!.toUpperCase()} · ${setCode!.toUpperCase()}';
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
      isFoil: json['is_foil'] as bool? ?? false,
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

  /// Références distinctes : le couple (extension, numéro) fait foi, une carte
  /// sans édition précisée en valant une.
  ///
  /// **Ce n'est pas le nombre de cartes au sens des règles.** Scryfall donne un
  /// identifiant oracle unique à tous les terrains de base d'un même type :
  /// compter les cartes ferait de 871 éditions de Plaine une seule ligne, alors
  /// que deux illustrations différentes occupent deux cases d'un classeur. Le
  /// deckbuilding, lui, garde l'autre lecture — posséder deux Plaines, c'est
  /// pouvoir en jouer deux exemplaires de la même carte.
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
///
/// Certains répondent à des questions d'inventaire — ce qui vaut le plus, ce
/// qu'on a en double, ce qui vient d'entrer. `binder`, `number` et `rarity`
/// répondent à celle qu'on se pose une carte à la main devant une boîte : où
/// va-t-elle ? Les cartes sans édition précisée n'ayant ni extension, ni numéro,
/// ni rareté, elles ferment la marche.
///
/// `binder` est le rangement complet — l'extension désigne le classeur, le
/// numéro la case — là où `number` ne connaît que la case et mêle donc les
/// classeurs. Les deux coexistent : le numéro seul reste le moyen de retrouver
/// une carte dont on ne sait plus de quelle extension elle vient.
///
/// [startsDescending] est le sens dans lequel on veut voir le critère la
/// première fois : on cherche d'abord ses cartes les plus chères, mais ses noms
/// de A à Z. Le re-sélectionner inverse ce sens.
enum CollectionSort {
  name('name', 'Nom', startsDescending: false),
  binder('binder', 'Classeur', startsDescending: false),
  number('number', 'Numéro', startsDescending: false),
  rarity('rarity', 'Rareté', startsDescending: false),
  price('price', 'Valeur', startsDescending: true),
  quantity('quantity', 'Quantité', startsDescending: true),
  recent('recent', 'Récent', startsDescending: true);

  const CollectionSort(this.id, this.label, {required this.startsDescending});

  final String id;
  final String label;
  final bool startsDescending;
}

/// Finition à laquelle restreindre la collection affichée.
///
/// Le brillant et le normal cohabitent avec des prix qui vont du simple au
/// triple : les isoler est le moyen de vérifier ce qu'on possède de chaque.
enum FinishFilter {
  all(null, 'Toutes finitions'),
  nonfoil('nonfoil', 'Normales'),
  foil('foil', 'Brillantes');

  const FinishFilter(this.id, this.label);

  /// Valeur attendue par le serveur. Nulle pour « ne pas filtrer ».
  final String? id;
  final String label;
}
