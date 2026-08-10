/// Les proportions d'un deck, lues dans le corpus plutôt qu'inventées.
///
/// **Aucun de ces nombres n'est une opinion.** Ils viennent de
/// `api/app/measure/deck_anatomy.py`, qui a mesuré les 190 précons Commander du
/// corpus. La sagesse populaire dit « trente-sept terrains » ; les decks réels
/// en comptent trente-huit.
///
/// **La mesure décide aussi de ce qu'on ne fait pas.** Les mêmes traits mesurés
/// sur 725 decks Pauper s'étalent de 25 à 40 % de créatures et de 23 à 43 %
/// d'éphémères : ce ne sont pas des variations autour d'un centre mais des
/// archétypes distincts — aggro, contrôle, combo — qu'une moyenne fondrait en un
/// deck qui n'existe nulle part. D'où un seul gabarit ici, celui du Commander,
/// et pas de constructeur pour les autres formats tant qu'ils n'auront pas été
/// regroupés par famille.
///
/// Les écarts interquartiles mesurés accompagnent chaque cible : ils disent
/// combien de liberté le corpus laisse, et servent à ne pas reprocher au
/// résultat un écart que les decks réels s'autorisent eux-mêmes.
library;

import 'card_role.dart';

/// Une cible, avec la marge que le corpus tolère.
///
/// [share] et [spread] sont des parts du deck, en pourcentage.
class Quota {
  const Quota(this.share, this.spread);

  /// Médiane mesurée sur le corpus.
  final double share;

  /// Écart interquartile : la moitié des decks réels tient dans cette bande
  /// autour de la médiane.
  final double spread;

  /// Nombre de cartes visé pour un deck de [size] cartes.
  int countFor(int size) => (share * size / 100).round();
}

/// Palier de coût de mana, et la part du deck qui lui revient.
class CurveStep {
  const CurveStep(this.min, this.max, this.quota);

  final int min;
  final int max;
  final Quota quota;

  bool contains(double cmc) => cmc >= min && cmc <= max;
}

/// Gabarit d'un deck Commander, mesuré sur 190 précons.
class DeckBlueprint {
  const DeckBlueprint._();

  static const commander = DeckBlueprint._();

  /// Cartes du deck, commandant compris.
  int get size => 100;

  /// Terrains, toutes sortes confondues. **C'est le trait le plus régulier du
  /// corpus** — écart interquartile de deux points sur 190 decks —, donc celui
  /// qu'on peut viser avec le plus d'assurance.
  Quota get lands => const Quota(38, 2);

  /// Rôles à doser. Ils se recouvrent : une créature qui produit du mana compte
  /// dans les deux, exactement comme dans la mesure d'où viennent ces cibles.
  Map<CardRole, Quota> get roles => const {
    CardRole.creature: Quota(29, 7),
    CardRole.draw: Quota(12, 4),
    CardRole.ramp: Quota(6, 3),
    CardRole.removal: Quota(6, 4),
  };

  /// Courbe de mana, sur les seules cartes non-terrain.
  ///
  /// Un terrain coûte zéro et gonflerait le premier palier de trente-huit
  /// cartes, ce qui rendrait la courbe illisible.
  List<CurveStep> get curve => const [
    CurveStep(0, 1, Quota(4, 2)),
    CurveStep(2, 2, Quota(13, 6)),
    CurveStep(3, 3, Quota(15, 5)),
    CurveStep(4, 4, Quota(12, 5)),
    CurveStep(5, 6, Quota(13, 5)),
    CurveStep(7, 99, Quota(4, 4)),
  ];
}
