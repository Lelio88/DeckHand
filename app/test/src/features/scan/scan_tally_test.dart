/// Tests du relevé de passe (#8).
///
/// **Un relevé faux est pire qu'un relevé absent** : il donne des pourcentages,
/// on décide dessus, et on cherche au mauvais endroit. Ces cas vérifient qu'il
/// ventile les trois pannes que « ça ne marche pas » recouvre.
library;

import 'package:deckhand/src/features/scan/domain/live_scanner.dart';
import 'package:deckhand/src/features/scan/domain/scan_tally.dart';
import 'package:flutter_test/flutter_test.dart';

LiveObservation seen(
  FrameOutcome outcome, {
  int? distance,
  bool detected = false,
  String? accepted,
}) => LiveObservation(
  outcome: outcome,
  distance: distance,
  detected: detected,
  accepted: accepted,
  located: outcome != FrameOutcome.notFound,
);

void main() {
  test('un relevé vide le dit', () {
    expect(ScanTally().describe(), 'aucune image analysée');
  });

  test('les trois pannes sont comptées séparément', () {
    // C'est tout l'objet : recadrer, vérifier le jeu saisi, ou constater que la
    // marge fait son travail ne sont pas le même geste.
    final tally = ScanTally()
      ..record(seen(FrameOutcome.notFound))
      ..record(seen(FrameOutcome.notFound))
      ..record(seen(FrameOutcome.silent, distance: 40))
      ..record(seen(FrameOutcome.unsure, distance: 9))
      ..record(seen(FrameOutcome.confident, distance: 3));

    expect(tally.count(FrameOutcome.notFound), 2);
    expect(tally.count(FrameOutcome.silent), 1);
    expect(tally.count(FrameOutcome.unsure), 1);
    expect(tally.count(FrameOutcome.confident), 1);
    expect(tally.frames, 5);
  });

  test('la part d\'images où une carte est dans le champ', () {
    final tally = ScanTally()
      ..record(seen(FrameOutcome.notFound))
      ..record(seen(FrameOutcome.confident, distance: 2))
      ..record(seen(FrameOutcome.confident, distance: 2))
      ..record(seen(FrameOutcome.confident, distance: 2));

    expect(tally.locatedShare, 0.75);
  });

  test('le refus le plus proche ignore les reconnaissances réussies', () {
    // La distance d'une carte reconnue n'apprend rien sur ce qui échoue : la
    // compter écraserait le seul chiffre qui dise si un échec est passé à un
    // cheveu ou à un kilomètre.
    final tally = ScanTally()
      ..record(seen(FrameOutcome.confident, distance: 1))
      ..record(seen(FrameOutcome.unsure, distance: 11))
      ..record(seen(FrameOutcome.silent, distance: 30));

    expect(tally.closestRejected, 11);
  });

  test('les détections et les retenues se comptent', () {
    final tally = ScanTally()
      ..record(seen(FrameOutcome.confident, distance: 2, detected: true))
      ..record(seen(FrameOutcome.confident, distance: 2))
      ..record(seen(FrameOutcome.confident, distance: 2, accepted: 'alpha'));

    expect(tally.detections, 1);
    expect(tally.accepted, 1);
  });

  test('le relevé se lit en pourcentages du total', () {
    final tally = ScanTally()
      ..record(seen(FrameOutcome.notFound))
      ..record(seen(FrameOutcome.confident, distance: 2));

    final line = tally.describe();
    expect(line, contains('2 images'));
    expect(line, contains('sans carte 50 %'));
    expect(line, contains('reconnu 50 %'));
  });

  group('ce qui bloque la passe', () {
    ScanTally passe(List<FrameOutcome> issues, {String? retenue}) {
      final tally = ScanTally();
      for (final o in issues) {
        tally.record(
          seen(o, accepted: o == FrameOutcome.confident ? retenue : null),
        );
      }
      return tally;
    }

    test('une passe trop courte ne conclut rien', () {
      // **Le silence des premières images n'est pas une panne.** La caméra
      // s'ouvre, la main approche : conclure au bout de trois images ferait
      // clignoter un reproche avant que l'utilisateur ait posé quoi que ce soit.
      expect(passe(List.filled(10, FrameOutcome.notFound)).stuckOn, isNull);
    });

    test('une passe qui a retenu une carte ne bloque sur rien', () {
      // Le bandeau ne s'affiche que pour les ennuis : une passe qui reconnaît
      // n'en a pas, même si la plupart de ses images échouent — entre deux
      // cartes, l'objectif ne voit que la table.
      final tally = passe([
        ...List.filled(minFramesBeforeAdvice, FrameOutcome.notFound),
        FrameOutcome.confident,
      ], retenue: 'alpha');

      expect(tally.stuckOn, isNull);
    });

    test('sans rien de retenu, la panne dominante ressort', () {
      final tally = passe([
        ...List.filled(minFramesBeforeAdvice, FrameOutcome.notFound),
        ...List.filled(5, FrameOutcome.unsure),
      ]);

      expect(tally.stuckOn, FrameOutcome.notFound);
    });

    test('c\'est bien la dominante, pas la première venue', () {
      final tally = passe([
        ...List.filled(10, FrameOutcome.notFound),
        ...List.filled(minFramesBeforeAdvice, FrameOutcome.silent),
      ]);

      expect(tally.stuckOn, FrameOutcome.silent);
    });
  });

  test('la remise à zéro efface tout, refus le plus proche compris', () {
    final tally = ScanTally()
      ..record(seen(FrameOutcome.silent, distance: 30))
      ..reset();

    expect(tally.frames, 0);
    expect(tally.closestRejected, isNull);
    expect(tally.describe(), 'aucune image analysée');
  });
}
