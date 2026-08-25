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
/// **Le label dit ce qu'on regarde, pas l'unité.** Écrire « euros » sous chacun
/// des cinq nombres de droite gaspillait la seule ligne capable de les
/// distinguer : ils s'annonçaient tous pareil, et le dernier — la carte la plus
/// chère — ne se laissait deviner que par le nom en légende, au point qu'on
/// pouvait ouvrir la page sans savoir ce qu'il comptait. Le symbole rejoint donc
/// le nombre ([euros]), et le label dit « au total », « dépensé », « la plus
/// chère ».
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
    this.fromBoosterSettings = false,
  });

  /// Le nombre, déjà mis en forme — l'écran ne décide ni des décimales ni de
  /// l'unité.
  final String value;

  /// Ce que le nombre dit : « cartes », « au total », « la plus chère ».
  final String label;

  /// Ce qui empêche de le lire de travers : une nuance, une réserve, une
  /// précision d'assiette.
  final String detail;

  /// Vrai quand ce chiffre repose sur ce qu'un booster contient ou coûte, donc
  /// sur des valeurs que l'utilisateur peut corriger.
  ///
  /// **Ce sont les seuls chiffres du profil dont l'utilisateur est la source.**
  /// Tous les autres se déduisent de la collection et des cotes ; ceux-ci
  /// dépendent du produit qu'il achète et de son prix, que rien ne publie au
  /// singulier. L'écran s'en sert pour ouvrir le réglage depuis la ligne qui
  /// affiche ces valeurs — le rendre modifiable ailleurs obligerait à le
  /// chercher.
  final bool fromBoosterSettings;
}

/// Une somme en euros, écrite à la française.
///
/// **L'espace avant le symbole est insécable.** Sur une tuile qui occupe une
/// demi-largeur d'écran, une espace ordinaire laisserait « 167,45 » et « € »
/// tomber sur deux lignes, et le chiffre principal de la page se lirait en
/// escalier.
String euros(num value) =>
    '${value.toStringAsFixed(2).replaceAll('.', ',')} €';

/// Les chiffres de gauche : ce que la collection contient.
///
/// [boosterSizes] porte le nombre de cartes par booster déclaré par
/// l'utilisateur, par jeu ; une clef absente laisse le repère de `boosterFacts`
/// s'appliquer.
List<CollectionFigure> countFigures(
  CollectionSummary totals,
  String game, {
  Map<String, int> boosterSizes = const {},
}) {
  final cards = boosterSizeFor(game, boosterSizes);
  return [
    CollectionFigure(
      value: '${totals.totalCards}',
      label: totals.totalCards > 1 ? 'cartes' : 'carte',
      // **Ne pas renvoyer au chiffre suivant.** Ce détail annonçait « 266
      // références », qui est mot pour mot le chiffre d'après : la première
      // pression ne montrait alors rien de neuf. Il dit désormais ce que ce
      // nombre-ci compte, et le contraste avec « références » porte le reste.
      detail: 'doublons compris',
    ),
    CollectionFigure(
      value: '${totals.distinctCards}',
      label: totals.distinctCards > 1 ? 'références' : 'référence',
      detail: 'éditions comprises',
    ),
    if (totals.distinctSets > 0)
      CollectionFigure(
        value: '${totals.distinctSets}',
        label: totals.distinctSets > 1 ? 'extensions' : 'extension',
        // Le mot « entamées » plutôt que « possédées » : on ne possède pas une
        // extension, on l'ouvre — et c'est justement ce que dit le chiffre
        // suivant, qui mesure combien on l'a avancée.
        //
        // « hors jetons » se dit, et ne se tait pas : le compte écarte les
        // extensions de jetons comme le fait le chiffre de complétion, et un
        // total qui exclut quelque chose sans le dire se lit comme un bug.
        detail: 'entamées, hors jetons',
      ),
    if (cards != null)
      CollectionFigure(
        // Arrondi vers le bas : c'est un nombre de boosters ouverts, et un
        // booster entamé n'existe pas.
        value: '${totals.totalCards ~/ cards}',
        label: 'boosters',
        detail: 'à $cards cartes le booster',
        fromBoosterSettings: true,
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
///
/// [boosterSizes] porte ce qu'il a déclaré ouvrir, même discipline — à ceci
/// près qu'un zéro y est refusé, faute de décrire un produit qui existe.
List<CollectionFigure> valueFigures(
  CollectionSummary totals,
  String game, {
  Map<String, double> boosterPrices = const {},
  Map<String, int> boosterSizes = const {},
}) {
  final cards = boosterSizeFor(game, boosterSizes);
  final prix = boosterPriceFor(game, boosterPrices);
  return [
    CollectionFigure(
      value: euros(totals.totalValueEur),
      label: 'au total',
      detail: totals.unspecifiedPrints > 0
          ? '${totals.unspecifiedPrints} sans édition'
          : 'toutes éditions connues',
    ),
    CollectionFigure(
      value: euros(totals.uniqueValueEur),
      label: 'sans doublons',
      detail: 'une de chaque référence',
    ),
    // **Rien à demander au serveur** : c'est une division entre deux chiffres
    // déjà là. Elle dit ce qu'aucun total ne dit — une collection de mille
    // communes et une de dix rares peuvent valoir la même chose.
    if (totals.totalCards > 0)
      CollectionFigure(
        value: euros(totals.totalValueEur / totals.totalCards),
        label: 'par carte',
        detail: 'en moyenne',
      ),
    if (cards != null && prix != null)
      CollectionFigure(
        // Ce que la collection aurait coûté si chaque carte était sortie d'un
        // booster acheté — la question posée est bien « combien j'aurais
        // dépensé », et non « combien je pourrais racheter ».
        value: euros(totals.totalCards / cards * prix),
        label: 'dépensé',
        detail: 'en boosters, à ${euros(prix)} pièce',
        fromBoosterSettings: true,
      ),
    if (totals.topCardName != null)
      CollectionFigure(
        value: euros(totals.topCardEur),
        label: 'la plus chère',
        detail: totals.topCardName!,
      ),
  ];
}
