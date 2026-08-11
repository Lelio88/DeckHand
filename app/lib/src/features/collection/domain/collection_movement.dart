/// Un mouvement de collection : ce qui est entré ou sorti, et quand.
///
/// **Une quantité et une date ne racontent pas une histoire.** La collection
/// porte « ×3 » et une seule estampille, qu'un ajout écrase : une ligne
/// alimentée trois jours de suite n'en garde qu'un seul. « Quand ai-je acquis
/// cette carte » n'avait donc aucune réponse — constaté sur une Cavalerie
/// atlante possédée en trois exemplaires dont on ne pouvait dire combien
/// dataient de la veille.
///
/// Le journal répond à cette question, et à elle seule : il ne remplace pas la
/// collection, il en garde la trace.
library;

/// Ce qu'un mouvement dit du geste qui l'a produit.
enum MovementKind {
  /// Des exemplaires sont entrés en collection.
  acquired,

  /// Des exemplaires en sont sortis.
  released,

  /// Des exemplaires ont changé d'impression — ni perte ni acquisition.
  ///
  /// Préciser l'édition d'une carte produit deux mouvements opposés ; les
  /// compter comme une sortie puis une entrée ferait mentir le journal sur ce
  /// qui s'est réellement passé.
  moved,

  /// Le report d'ouverture : la collection telle qu'elle était quand le journal
  /// a commencé.
  ///
  /// **Le journal ne réécrit pas le passé.** Ces lignes sont datées de la
  /// dernière entrée connue de chaque ligne de collection, ce qui est faux au
  /// détail près — ces ×3 sont peut-être trois gestes — et honnête à l'échelle.
  opening,
}

class CollectionMovement {
  const CollectionMovement({
    required this.happenedAt,
    required this.delta,
    required this.oracleId,
    required this.name,
    required this.kind,
    this.printedName,
    this.setCode,
    this.collectorNumber,
    this.lang,
    this.isFoil = false,
    this.artCropUrl,
  });

  final DateTime happenedAt;

  /// Positif à l'entrée, négatif à la sortie. Jamais nul.
  final int delta;

  final String oracleId;
  final String name;
  final String? printedName;

  /// L'édition concernée, `null` quand elle n'était pas précisée.
  final String? setCode;
  final String? collectorNumber;
  final String? lang;

  final bool isFoil;
  final String? artCropUrl;
  final MovementKind kind;

  String get shownName => printedName ?? name;

  /// Ce que ce mouvement a fait, en toutes lettres.
  String get label => switch (kind) {
    MovementKind.opening => 'Déjà là',
    MovementKind.moved => delta > 0 ? 'Rangée ici' : 'Déplacée',
    MovementKind.acquired => 'Ajoutée',
    MovementKind.released => 'Retirée',
  };

  /// L'édition, dite comme sur la carte — ou son absence.
  String get editionLabel {
    if (setCode == null) return 'Édition non précisée';
    final number = collectorNumber == null ? '' : ' #$collectorNumber';
    return '${setCode!.toUpperCase()}$number'
        '${lang == null ? '' : ' · ${lang!.toUpperCase()}'}'
        '${isFoil ? ' · brillante' : ''}';
  }

  factory CollectionMovement.fromJson(Map<String, dynamic> json) {
    final delta = (json['delta'] as num?)?.toInt() ?? 0;
    final opening = (json['is_opening'] as bool?) ?? false;
    final move = (json['is_move'] as bool?) ?? false;

    return CollectionMovement(
      happenedAt:
          DateTime.tryParse(json['happened_at'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
      delta: delta,
      oracleId: json['oracle_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      printedName: json['printed_name'] as String?,
      setCode: json['set_code'] as String?,
      collectorNumber: json['collector_number'] as String?,
      lang: json['lang'] as String?,
      isFoil: (json['is_foil'] as bool?) ?? false,
      artCropUrl: json['art_crop_url'] as String?,
      // L'ordre compte : un report est d'abord un report, et un rangement n'est
      // ni une acquisition ni une perte quel que soit son signe.
      kind: opening
          ? MovementKind.opening
          : move
          ? MovementKind.moved
          : delta > 0
          ? MovementKind.acquired
          : MovementKind.released,
    );
  }
}
