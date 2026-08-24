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
    this.fromBoosterPrice = false,
  });

  /// Le nombre, déjà mis en forme — l'écran ne décide pas des décimales.
  final String value;

  /// Ce que le nombre compte : « cartes », « euros ».
  final String label;

  /// Ce qui empêche de le lire de travers : une nuance, une réserve, une
  /// précision d'assiette.
  final String detail;

  /// Vrai quand ce chiffre repose sur le prix d'un booster, donc sur une valeur
  /// que l'utilisateur peut corriger.
  ///
  /// **C'est le seul chiffre du profil dont l'utilisateur est la source.** Tous
  /// les autres se déduisent de la collection et des cotes ; celui-ci dépend de
  /// ce qu'il paie en boutique, que rien ne publie. L'écran s'en sert pour
  /// ouvrir le réglage depuis la ligne qui affiche le prix — le rendre
  /// modifiable ailleurs obligerait à le chercher.
  final bool fromBoosterPrice;
}

/// Les chiffres de gauche : ce que la collection contient.
///
/// N'utilise que la **taille** du booster, qui est un fait publié : ces trois
/// chiffres ne dépendent d'aucun réglage.
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
    if (totals.distinctSets > 0)
      CollectionFigure(
        value: '${totals.distinctSets}',
        label: totals.distinctSets > 1 ? 'extensions' : 'extension',
        // Le mot « entamées » plutôt que « possédées » : on ne possède pas une
        // extension, on l'ouvre — et c'est justement ce que dit le chiffre
        // suivant, qui mesure combien on l'a avancée.
        detail: 'entamées, jetons compris',
      ),
    if (booster != null)
      CollectionFigure(
        // Arrondi vers le bas : c'est un nombre de boosters ouverts, et un
        // booster entamé n'existe pas.
        value: '${totals.totalCards ~/ booster.cards}',
        label: 'boosters',
        detail: 'à ${booster.cards} cartes le booster',
      ),
    // **Le seul chiffre qui désigne une action.** Compléter un classeur déjà
    // bien avancé coûte moins cher que d'en ouvrir un neuf ; les autres
    // chiffres décrivent, celui-ci suggère où aller.
    if (totals.bestSetName != null && totals.bestSetTotal > 0)
      CollectionFigure(
        value: '${(100 * totals.bestSetOwned / totals.bestSetTotal).round()} %',
        label: 'au mieux',
        detail:
            '${totals.bestSetName}, '
            '${totals.bestSetOwned}/${totals.bestSetTotal} cases',
      ),
  ];
}

/// Les chiffres de droite : ce que la collection vaut.
///
/// [unspecifiedPrints] nuance la première : une valorisation fondée sur des
/// éditions inconnues est un plancher, pas une estimation.
///
/// [boosterPrices] porte ce que l'utilisateur a déclaré payer, par jeu. Une
/// clef absente laisse le prix de repère s'appliquer ; **un zéro déclaré est
/// respecté**, et l'indicateur annonce alors zéro euro plutôt que d'inventer
/// des dépenses.
List<CollectionFigure> valueFigures(
  CollectionSummary totals,
  String game, {
  Map<String, double> boosterPrices = const {},
}) {
  final booster = boosterFactsFor(game);
  final prix = boosterPriceFor(game, boosterPrices);
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
    // **Rien à demander au serveur** : c'est une division entre deux chiffres
    // déjà là. Elle dit ce qu'aucun total ne dit — une collection de mille
    // communes et une de dix rares peuvent valoir la même chose.
    if (totals.totalCards > 0)
      CollectionFigure(
        value: (totals.totalValueEur / totals.totalCards).toStringAsFixed(2),
        label: 'euros',
        detail: 'en moyenne par carte',
      ),
    if (booster != null && prix != null)
      CollectionFigure(
        // Ce que la collection aurait coûté si chaque carte était sortie d'un
        // booster acheté — la question posée est bien « combien j'aurais
        // dépensé », et non « combien je pourrais racheter ».
        value: (totals.totalCards / booster.cards * prix).toStringAsFixed(2),
        label: 'euros',
        detail: 'en boosters, à ${prix.toStringAsFixed(2)} € pièce',
        fromBoosterPrice: true,
      ),
    if (totals.topCardName != null)
      CollectionFigure(
        value: totals.topCardEur.toStringAsFixed(2),
        label: 'euros',
        detail: totals.topCardName!,
      ),
  ];
}
