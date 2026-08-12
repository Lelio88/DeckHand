/// Les proportions d'un deck, lues dans le corpus plutôt qu'inventées.
///
/// **Aucun de ces nombres n'est une opinion.** Ils viennent de
/// `api/app/measure/deck_anatomy.py`, qui a mesuré les 1 028 decks du corpus par
/// format. La sagesse populaire dit « trente-sept terrains » en Commander ; les
/// decks réels en comptent trente-huit.
///
/// **Les trois formats ne se valent pas, et la mesure le dit.** Les 190 précons
/// Commander se ressemblent — écart interquartile de deux points sur les
/// terrains, de trois à sept sur les rôles : ils sortent du même atelier, et
/// leur médiane décrit un deck qui existe. Les 725 decks Pauper et les 113
/// Modern, eux, s'étalent de 25 à 40 % de créatures et de 23 à 43 % de sorts :
/// ce sont des **archétypes distincts** — aggro, contrôle, combo — dont la
/// médiane décrit un deck qui n'existe nulle part.
///
/// Leurs gabarits sont donc fournis, puisqu'un deck moyen reste jouable et vaut
/// mieux qu'un tas de cartes, mais [reliability] dit ce qu'il faut en penser et
/// l'interface le répète à l'utilisateur. Les couvrir vraiment demanderait de
/// regrouper les decks par famille avant de moyenner — un travail de
/// classification, pas un réglage.
///
/// Les écarts interquartiles accompagnent chaque cible : ils disent combien de
/// liberté le corpus laisse, et servent à ne pas reprocher au résultat un écart
/// que les decks réels s'autorisent eux-mêmes.
library;

import '../../decks/domain/deck_suggestion.dart';
import 'card_role.dart';

/// Ce que vaut un gabarit, mesuré par la dispersion du corpus dont il sort.
enum BlueprintReliability {
  /// Les decks du format se ressemblent : la médiane décrit un deck réel.
  tight,

  /// Le format mêle des archétypes incompatibles : la médiane décrit un deck
  /// moyen, jouable mais qui ne ressemble à aucun deck du corpus.
  averaged,
}

/// Une cible, avec la marge que le corpus tolère.
class Quota {
  const Quota(this.share, this.spread);

  /// Médiane mesurée sur le corpus, en pourcentage du deck.
  final double share;

  /// Écart interquartile : la moitié des decks réels tient dans cette bande.
  final double spread;

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

class DeckBlueprint {
  const DeckBlueprint({
    required this.size,
    required this.maxCopies,
    required this.needsCommander,
    required this.lands,
    required this.roles,
    required this.curve,
    required this.reliability,
  });

  /// Cartes du deck, commandant compris quand il y en a un.
  final int size;

  /// Exemplaires autorisés d'une même carte, hors terrains de base.
  final int maxCopies;

  final bool needsCommander;

  /// Terrains, toutes sortes confondues.
  final Quota lands;

  /// Rôles à doser. Ils se recouvrent : une créature qui produit du mana compte
  /// dans les deux, exactement comme dans la mesure d'où viennent ces cibles.
  final Map<CardRole, Quota> roles;

  /// Courbe de mana, sur les seules cartes non-terrain — un terrain coûte zéro
  /// et gonflerait le premier palier de tous les terrains du deck.
  final List<CurveStep> curve;

  final BlueprintReliability reliability;

  /// Gabarit d'un format, ou `null` quand aucun n'a été mesuré.
  ///
  /// **Nul plutôt qu'un gabarit par défaut.** Les trois gabarits Magic viennent
  /// chacun de la médiane de son propre corpus ; le format construit de
  /// Riftbound n'en a pas — ses notions ne sont pas celles de Magic (ni
  /// terrains, ni rampe, mais des runes et des champs de bataille), et lui
  /// prêter des proportions mesurées ailleurs produirait un deck faux avec
  /// l'assurance d'un deck mesuré. La vue le dit plutôt que de le deviner.
  static DeckBlueprint? of(DeckFormat format) => switch (format) {
    DeckFormat.commander => commander,
    DeckFormat.pauper => pauper,
    DeckFormat.modern => modern,
    // Yu-Gi-Oh partage la raison de Riftbound : ses notions — Main, Extra,
    // Side — n'ont pas de pendant Magic, et ses proportions se mesureraient sur
    // son propre corpus. Celui-ci existe désormais (3 935 decks), mais le
    // gabarit reste à mesurer : le déclarer d'avance referait l'erreur que le
    // choix du format a déjà coûtée une fois à ce jeu.
    DeckFormat.constructed ||
    DeckFormat.edison ||
    DeckFormat.goat ||
    DeckFormat.redu ||
    DeckFormat.hat => null,
  };

  /// Mesuré sur 190 précons. Le format le plus régulier du corpus.
  static const commander = DeckBlueprint(
    size: 100,
    maxCopies: 1,
    needsCommander: true,
    lands: Quota(38, 2),
    roles: {
      CardRole.creature: Quota(29, 7),
      CardRole.draw: Quota(12, 4),
      CardRole.ramp: Quota(6, 3),
      CardRole.removal: Quota(6, 4),
    },
    curve: [
      CurveStep(0, 1, Quota(4, 2)),
      CurveStep(2, 2, Quota(13, 6)),
      CurveStep(3, 3, Quota(15, 5)),
      CurveStep(4, 4, Quota(12, 5)),
      CurveStep(5, 6, Quota(13, 5)),
      CurveStep(7, 99, Quota(4, 4)),
    ],
    reliability: BlueprintReliability.tight,
  );

  /// Mesuré sur 725 decks de tournoi. Seuls les terrains y sont réguliers
  /// (écart de 3 points) ; tout le reste mêle des archétypes.
  static const pauper = DeckBlueprint(
    size: 60,
    maxCopies: 4,
    needsCommander: false,
    lands: Quota(30, 3),
    roles: {
      CardRole.creature: Quota(30, 15),
      CardRole.draw: Quota(25, 23),
      CardRole.ramp: Quota(7, 7),
      CardRole.removal: Quota(5, 10),
    },
    curve: [
      CurveStep(0, 1, Quota(22, 12)),
      CurveStep(2, 2, Quota(25, 17)),
      CurveStep(3, 3, Quota(7, 12)),
      CurveStep(4, 4, Quota(7, 10)),
      CurveStep(5, 6, Quota(7, 12)),
      CurveStep(7, 99, Quota(0, 3)),
    ],
    reliability: BlueprintReliability.averaged,
  );

  /// Mesuré sur 113 decks de tournoi. Ses terrains sont presque tous
  /// spéciaux — 5 % de terrains de base contre 30 % — ce qu'une collection
  /// ordinaire ne peut pas fournir.
  static const modern = DeckBlueprint(
    size: 60,
    maxCopies: 4,
    needsCommander: false,
    lands: Quota(35, 7),
    roles: {
      CardRole.creature: Quota(27, 17),
      CardRole.draw: Quota(15, 10),
      CardRole.ramp: Quota(2, 2),
      CardRole.removal: Quota(7, 7),
    },
    curve: [
      CurveStep(0, 1, Quota(23, 18)),
      CurveStep(2, 2, Quota(18, 13)),
      CurveStep(3, 3, Quota(8, 7)),
      CurveStep(4, 4, Quota(2, 7)),
      CurveStep(5, 6, Quota(3, 8)),
      CurveStep(7, 99, Quota(0, 7)),
    ],
    reliability: BlueprintReliability.averaged,
  );
}
