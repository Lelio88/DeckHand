/// Tranches d'années pour retrouver une édition sans connaître son extension.
///
/// **Le sélecteur trie par sortie la plus récente**, et sur une carte
/// réimprimée un millier de fois — les terrains de base —, les plus anciennes
/// éditions n'arrivent qu'après des pages entières de réimpressions. Charger
/// la suite finit par les montrer ; la tranche y mène directement. La
/// recherche textuelle ne répare rien :
/// elle suppose de connaître le nom de l'extension, alors que ce qu'on connaît
/// souvent d'une vieille carte, c'est son époque, pas son nom exact.
///
/// Quatre tranches plutôt qu'une par année : un menu de trente ans serait plus
/// long à parcourir que la liste qu'il est censé raccourcir. Les bornes sont
/// délibérément larges — il s'agit de sortir une carte du lot, pas de la
/// dater au format près.
library;

enum PrintingEra {
  all(null, null, 'Toutes'),
  before2000(null, 1999, 'Avant 2000'),
  the2000s(2000, 2009, '2000-2009'),
  the2010s(2010, 2019, '2010-2019'),
  from2020(2020, null, '2020+');

  const PrintingEra(this.fromYear, this.toYear, this.label);

  /// Borne basse incluse, ou `null` pour une tranche ouverte vers le passé.
  final int? fromYear;

  /// Borne haute incluse, ou `null` pour une tranche ouverte vers le présent.
  final int? toYear;

  /// Ce qu'affiche le bouton une fois la tranche choisie.
  final String label;
}
