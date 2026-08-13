/// Le panier d'un lot scanné au fil de la caméra (#8).
///
/// **Il existe parce que le §IV.8 l'exige.** Rien n'entre en collection sans
/// confirmation ; le flux reconnaît, le panier accumule, l'utilisateur valide à
/// la fin d'un booster. C'est la forme de la liste à cocher de l'étalement,
/// déjà éprouvée, et elle a précisément pour rôle de rendre **décochable** la
/// carte que le seuil a laissé passer.
///
/// **Il est séparé de l'écran, et c'est délibéré.** Un panier logé dans l'état
/// d'un widget ne se teste qu'avec une caméra ouverte, c'est-à-dire pas du
/// tout. Ici, la même logique s'éprouve avec une liste d'identifiants.
///
/// **Une carte vue deux fois est deux exemplaires**, pas une ligne dupliquée.
/// C'est [CardTracker] qui a déjà décidé qu'il s'agissait de deux passages
/// distincts — le panier ne fait que compter ce qu'on lui donne, et n'a aucune
/// raison de remettre cette décision en cause.
library;

/// Une ligne du panier : une carte, ses exemplaires, et si on la garde.
class BasketLine {
  BasketLine(this.oracleId);

  final String oracleId;

  /// Exemplaires vus au fil du flux.
  int quantity = 1;

  /// **Gardée par défaut.** Décocher est le geste rare ; l'inverse obligerait à
  /// cocher quinze lignes après chaque booster, et le mode perdrait son intérêt.
  bool keep = true;
}

/// Ce que le flux a retenu, en attente de confirmation.
class ScanBasket {
  final List<BasketLine> _lines = [];

  /// Les lignes, dans l'ordre où les cartes sont passées devant l'objectif.
  ///
  /// **L'ordre d'arrivée, et non l'alphabet.** Un booster se dépouille dans un
  /// ordre ; retrouver la dernière carte vue en haut de liste est ce qui permet
  /// de vérifier d'un coup d'oeil que le flux suit.
  List<BasketLine> get lines => List.unmodifiable(_lines);

  bool get isEmpty => _lines.isEmpty;

  /// Exemplaires retenus, cases décochées exclues.
  int get keptCount =>
      _lines.where((l) => l.keep).fold(0, (sum, l) => sum + l.quantity);

  /// Lignes retenues, dans l'ordre.
  List<BasketLine> get kept => _lines.where((l) => l.keep).toList();

  /// Ajoute un passage. Rend la ligne touchée, nouvelle ou non.
  ///
  /// **Une carte déjà décochée puis revue redevient gardée.** Repasser la même
  /// carte devant l'objectif est un geste délibéré : le lire comme « je la veux
  /// finalement » est la seule interprétation qui ne perde pas l'intention.
  BasketLine add(String oracleId) {
    for (final line in _lines) {
      if (line.oracleId != oracleId) continue;
      line.quantity++;
      line.keep = true;
      return line;
    }
    final line = BasketLine(oracleId);
    _lines.insert(0, line);
    return line;
  }

  /// Retire une ligne entière — la carte n'aurait jamais dû entrer.
  void remove(String oracleId) =>
      _lines.removeWhere((l) => l.oracleId == oracleId);

  void clear() => _lines.clear();
}
