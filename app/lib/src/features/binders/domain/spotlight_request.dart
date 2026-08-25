/// Ce qu'un spectateur a fait monter sur l'overlay (#21).
///
/// **Trois genres, une seule place.** `!montre <nom>` fait sortir une carte de
/// sa case ; `!page <ext> <n>` ouvre le classeur sur une page et s'y arrête ;
/// `!card <nom>` pose sur un tapis toutes les versions possédées d'une carte.
/// La base n'a qu'une ligne par collection — l'écran n'a qu'une place —, et la
/// colonne `kind` dit lequel des trois est demandé. D'où une hiérarchie
/// **scellée** : chaque `switch` est exhaustif, et le compilateur montre
/// chaque endroit à compléter quand un genre s'ajoute.
///
/// **Et deux niveaux, parce que deux des trois vivent dans un classeur.**
/// [BinderRequest] est ce que `BinderReveal` sait dessiner : une carte, une
/// page. Un tapis n'est pas un classeur — pas de reliure, pas de page, pas de
/// case —, et lui faire traverser le même widget aurait fait de celui-ci deux
/// choses sans rapport. Le type le dit, et le compilateur l'impose.
///
/// **Ce que la désignation ajoute au calque.** L'overlay montrait ce que le
/// diffuseur scanne ; il montre désormais aussi ce qu'on lui demande de sortir
/// du classeur. C'est la seule interaction du chantier qui aille du chat vers
/// l'écran, et donc la seule qui **écrive** — voir la migration
/// `collection_spotlight`, qui explique ce qu'un inconnu peut au pire.
///
/// **Le calque n'arbitre rien qu'il ne puisse voir.** Ce qui est rendu ici est
/// déjà passé par le filtre de portée côté base : une extension retirée du
/// partage disparaît du calque, même si la demande est antérieure au retrait.
/// Ces classes n'ont donc aucune règle de visibilité à porter, et ne doivent pas
/// en gagner — ce serait un second endroit où se tromper.
///
/// **`requestId` dit qu'une demande est neuve**, exactement comme `movementId`
/// côté journal : deux spectateurs qui désignent la même carte sont deux
/// événements, et le calque doit rejouer pour le second.
///
/// **`page`, `slot` et `pages` viennent de la base, pas d'un calcul local.**
/// Le calque ouvre le classeur à la bonne page et fait sortir la carte de la
/// bonne case ; refaire ce classement en Dart y porterait l'ordre des numéros,
/// le repli quand le numéro n'est pas un nombre et le choix de l'impression
/// représentative — un jumeau de plus sur exactement le genre de règle qui
/// dérive en silence. Vérifié : sur 25 cartes, `public_spotlight` et
/// `binder_locate` nomment la même case, zéro désaccord.
library;

import '../../printings/domain/scryfall_image.dart';

/// Une demande d'affichage, quel qu'en soit le genre.
sealed class SpotlightRequest {
  const SpotlightRequest({
    required this.requestId,
    this.requestedBy,
    this.setCode,
    this.setName,
    this.page = 1,
    this.pages = 1,
  });

  /// Identifiant de la demande. Neuf à chaque désignation acceptée, y compris
  /// quand la carte ne change pas.
  final int requestId;

  /// Le pseudonyme du demandeur, borné côté base. `null` quand il manque : la
  /// bannière s'en passe plutôt que d'inventer « anonyme ».
  final String? requestedBy;

  final String? setCode;
  final String? setName;

  /// Page du classeur, à partir de 1 — la même que celle que `!card` annonce.
  final int page;

  /// Nombre total de pages de l'extension. **Le défilé en a besoin** : sans lui
  /// on ne saurait pas si la page 46 est au milieu du classeur ou à sa fin.
  final int pages;

  /// **Le genre décide, et son absence vaut « carte ».** Une base antérieure à
  /// la migration ne rend pas la colonne ; la lire comme une carte est le seul
  /// repli qui ne casse rien.
  ///
  /// **Plusieurs lignes pour une seule demande.** Un tapis en rend une par
  /// version, toutes sous le même `request_id` ; les deux autres genres n'en
  /// rendent qu'une. C'est donc la liste entière qui se lit, pas sa première
  /// ligne — la lire aurait montré une seule version d'un tapis, sans erreur ni
  /// signal.
  static SpotlightRequest? fromRows(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return null;
    return switch (rows.first['kind'] as String?) {
      'page' => SpotlightPage.fromJson(rows.first),
      'strip' => SpotlightStrip.fromRows(rows),
      _ => SpotlightCard.fromJson(rows.first),
    };
  }
}

/// Ce qui se montre **dans un classeur** : une carte, ou une page.
///
/// Le tapis n'en est pas — il n'a ni reliure, ni page, ni case —, et ce type
/// est ce qui empêche de le donner à `BinderReveal` par mégarde.
sealed class BinderRequest extends SpotlightRequest {
  const BinderRequest({
    required super.requestId,
    super.requestedBy,
    super.setCode,
    super.setName,
    super.page,
    super.pages,
  });
}

/// Une carte, qui sortira de sa case.
final class SpotlightCard extends BinderRequest {
  const SpotlightCard({
    required super.requestId,
    required this.name,
    this.printedName,
    super.requestedBy,
    super.setCode,
    super.setName,
    this.collectorNumber,
    this.artCropUrl,
    this.priceEur,
    this.copies = 0,
    super.page,
    this.slot = 1,
    super.pages,
  });

  final String name;
  final String? printedName;
  final String? collectorNumber;
  final String? artCropUrl;
  final double? priceEur;

  /// Exemplaires possédés de cette case. Une désignation ne peut porter que sur
  /// une carte possédée — la base le vérifie — donc ce nombre est au moins un.
  final int copies;

  /// Case dans la page, de 1 à 9, en lecture occidentale.
  final int slot;

  String get displayName => printedName ?? name;

  /// La carte entière — cadre, nom et texte compris —, déduite de l'URL de son
  /// illustration. C'est ce qui sort d'un classeur : une carte, pas un détail.
  String? get imageUrl => fullCardImage(artCropUrl);

  factory SpotlightCard.fromJson(Map<String, dynamic> json) => SpotlightCard(
    requestId: (json['request_id'] as num).toInt(),
    name: json['name'] as String? ?? '',
    printedName: json['printed_name'] as String?,
    requestedBy: json['requested_by'] as String?,
    setCode: json['set_code'] as String?,
    setName: json['set_name'] as String?,
    collectorNumber: json['collector_number'] as String?,
    artCropUrl: json['art_crop_url'] as String?,
    priceEur: (json['price_eur'] as num?)?.toDouble(),
    copies: (json['copies'] as num?)?.toInt() ?? 0,
    page: (json['page'] as num?)?.toInt() ?? 1,
    slot: (json['slot'] as num?)?.toInt() ?? 1,
    pages: (json['pages'] as num?)?.toInt() ?? 1,
  );
}

/// Une page, sur laquelle le classeur s'ouvre et s'arrête.
///
/// **Rien n'en sort, et c'est tout ce qui la distingue.** Le classeur s'ouvre,
/// feuillette jusqu'à elle, la pose — et se tait. Faire sortir quelque chose
/// supposerait de choisir une carte parmi neuf ; or ce que `!page` répond, c'est
/// justement l'état de la page **entière**, ses trous compris.
final class SpotlightPage extends BinderRequest {
  const SpotlightPage({
    required super.requestId,
    super.requestedBy,
    super.setCode,
    super.setName,
    super.page,
    super.pages,
  });

  factory SpotlightPage.fromJson(Map<String, dynamic> json) => SpotlightPage(
    requestId: (json['request_id'] as num).toInt(),
    requestedBy: json['requested_by'] as String?,
    setCode: json['set_code'] as String?,
    setName: json['set_name'] as String?,
    page: (json['page'] as num?)?.toInt() ?? 1,
    pages: (json['pages'] as num?)?.toInt() ?? 1,
  );
}

/// Toutes les versions possédées d'une même carte, posées sur un tapis.
///
/// **Ce que `!card` ne peut pas dire.** La commande répond « 3 cases
/// (+5 autres) » ; les cinq autres, personne ne saura jamais à quoi elles
/// ressemblent — et c'est précisément la question qu'on se pose devant une
/// carte qu'on possède en plusieurs dessins. Le tapis les montre côte à côte.
///
/// **Une entrée par illustration, pas par impression.** Le dédoublonnage se
/// fait en base, sur `illustration_id` : deux extensions au même dessin ne font
/// qu'une carte à montrer.
///
/// **Rien n'est trié ni recompté ici.** L'ordre vient de la base, comme le
/// choix de l'impression représentative ; le refaire en Dart en ferait un
/// second endroit où se tromper.
final class SpotlightStrip extends SpotlightRequest {
  const SpotlightStrip({
    required super.requestId,
    required this.entries,
    super.requestedBy,
  });

  /// Les versions, dans l'ordre où la base les rend. Au moins une — la base
  /// refuse de monter un tapis pour une carte tenue en un seul dessin, mais la
  /// portée peut en retirer après coup.
  final List<SpotlightCard> entries;

  /// Le nom de la carte, pris à la première version.
  String get displayName => entries.isEmpty ? '' : entries.first.displayName;

  factory SpotlightStrip.fromRows(List<Map<String, dynamic>> rows) =>
      SpotlightStrip(
        requestId: (rows.first['request_id'] as num).toInt(),
        requestedBy: rows.first['requested_by'] as String?,
        entries: [for (final row in rows) SpotlightCard.fromJson(row)],
      );
}
