/// Les chiffres que la page de profil sait dire d'une collection.
///
/// **Pourquoi plusieurs plutôt qu'un.** « 617 cartes » et « 167 € » répondent à
/// « qu'est-ce que je possède ? ». Ce ne sont pas les seules questions qu'on se
/// pose devant sa collection : combien de cartes *différentes*, ce que vaudrait
/// une de chaque, ce que tout cela aurait coûté en boosters, quelle est la plus
/// chère. Les afficher toutes tiendrait de l'inventaire ; on en montre une, et
/// les autres viennent d'une pression.
///
/// **Le calcul vit ici, pas dans l'écran.** Une valeur qui se lit dans un widget
/// ne se teste qu'en dessinant l'écran, et une règle métier qui n'a pas de test
/// simple finit par diverger de ce qu'on croit qu'elle fait.
///
/// **Ce qui manque ne s'invente pas.** Les deux chiffres exprimés en boosters
/// demandent de savoir ce qu'un booster contient et coûte ; pour un jeu absent
/// de `boosterFacts`, ils sont simplement absents de la liste, et l'écran ne
/// propose alors que les autres.
library;

import '../../collection/domain/booster_size.dart';
import '../../collection/domain/collection_entry.dart';

/// Un chiffre à afficher : sa valeur, ce qu'elle compte, et ce qu'elle nuance.
class CollectionFigure {
  const CollectionFigure({
    required this.value,
    required this.label,
    required this.detail,
  });

  /// Le nombre, déjà mis en forme — l'écran ne décide pas des décimales.
  final String value;

  /// Ce que le nombre compte : « cartes », « euros ».
  final String label;

  /// Ce qui empêche de le lire de travers : une nuance, une réserve, une
  /// précision d'assiette.
  final String detail;
}

/// Les chiffres de gauche : ce que la collection contient.
List<CollectionFigure> countFigures(CollectionSummary totals, String game) {
  final booster = boosterFactsFor(game);
  return [
    CollectionFigure(
      value: '${totals.totalCards}',
      label: totals.totalCards > 1 ? 'cartes' : 'carte',
      detail:
          '${totals.distinctCards} référence'
          '${totals.distinctCards > 1 ? 's' : ''}',
    ),
    CollectionFigure(
      value: '${totals.distinctCards}',
      label: totals.distinctCards > 1 ? 'références' : 'référence',
      detail: 'une de chaque, éditions comprises',
    ),
    if (booster != null)
      CollectionFigure(
        // Arrondi vers le bas : c'est un nombre de boosters ouverts, et un
        // booster entamé n'existe pas.
        value: '${totals.totalCards ~/ booster.cards}',
        label: 'boosters',
        detail: 'à ${booster.cards} cartes le booster',
      ),
  ];
}

/// Les chiffres de droite : ce que la collection vaut.
///
/// [unspecifiedPrints] nuance la première : une valorisation fondée sur des
/// éditions inconnues est un plancher, pas une estimation.
List<CollectionFigure> valueFigures(CollectionSummary totals, String game) {
  final booster = boosterFactsFor(game);
  return [
    CollectionFigure(
      value: totals.totalValueEur.toStringAsFixed(2),
      label: 'euros',
      detail: totals.unspecifiedPrints > 0
          ? '${totals.unspecifiedPrints} sans édition'
          : 'toutes éditions connues',
    ),
    CollectionFigure(
      value: totals.uniqueValueEur.toStringAsFixed(2),
      label: 'euros',
      detail: 'une de chaque, sans les doublons',
    ),
    if (booster != null)
      CollectionFigure(
        // Ce que la collection aurait coûté si chaque carte était sortie d'un
        // booster acheté — la question posée est bien « combien j'aurais
        // dépensé », et non « combien je pourrais racheter ».
        value: (totals.totalCards / booster.cards * booster.priceEur)
            .toStringAsFixed(2),
        label: 'euros',
        detail: 'en boosters, à ${booster.priceEur.toStringAsFixed(2)} € pièce',
      ),
    if (totals.topCardName != null)
      CollectionFigure(
        value: totals.topCardEur.toStringAsFixed(2),
        label: 'euros',
        detail: totals.topCardName!,
      ),
  ];
}
