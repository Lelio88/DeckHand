/// Tests du bandeau d'ennui (#8).
///
/// **Ce que ces cas protègent.** Un bandeau qui parle tout le temps n'est plus
/// lu, et il masquait la carte qu'on filmait. Un bandeau qui se tait quand rien
/// ne marche laisse chercher au mauvais endroit. Les deux erreurs se valent, et
/// c'est la frontière entre elles que ces cas tiennent.
library;

import 'package:deckhand/src/features/scan/domain/live_scanner.dart';
import 'package:deckhand/src/features/scan/domain/scan_tally.dart';
import 'package:deckhand/src/features/scan/presentation/scan_trouble_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

LiveObservation seen(FrameOutcome outcome, {String? accepted}) =>
    LiveObservation(
      outcome: outcome,
      accepted: accepted,
      located: outcome != FrameOutcome.notFound,
    );

ScanTally passe(FrameOutcome issue, {int images = minFramesBeforeAdvice}) {
  final tally = ScanTally();
  for (var i = 0; i < images; i++) {
    tally.record(seen(issue));
  }
  return tally;
}

Future<void> pump(WidgetTester tester, ScanTally tally) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: ScanTroubleBar(tally: tally, onReset: () {}),
    ),
  ),
);

void main() {
  testWidgets('une passe qui va bien n\'affiche rien du tout', (tester) async {
    final tally = ScanTally();
    for (var i = 0; i < minFramesBeforeAdvice; i++) {
      tally.record(seen(FrameOutcome.notFound));
    }
    tally.record(seen(FrameOutcome.confident, accepted: 'alpha'));

    await pump(tester, tally);

    // Pas un pixel : le bandeau est en surimpression sur le retour vidéo, et
    // ce qu'il masque vaut plus que ce qu'il dirait.
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('une passe trop jeune ne reproche rien', (tester) async {
    await pump(tester, passe(FrameOutcome.notFound, images: 5));

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('sans détection, il dit de recadrer', (tester) async {
    await pump(tester, passe(FrameOutcome.notFound));

    expect(find.text('La carte n\'est pas repérée'), findsOneWidget);
    expect(find.textContaining('changez de fond'), findsOneWidget);
  });

  testWidgets('index muet, il envoie vers le jeu sélectionné', (tester) async {
    // C'est le geste qui corrige la panne la plus fréquente après un
    // changement de jeu : l'index chargé est celui du jeu courant.
    await pump(tester, passe(FrameOutcome.silent));

    expect(find.text('Illustration inconnue'), findsOneWidget);
    expect(find.textContaining('jeu sélectionné'), findsOneWidget);
  });

  testWidgets('marge insuffisante, il dit que le refus protège', (
    tester,
  ) async {
    await pump(tester, passe(FrameOutcome.unsure));

    expect(find.text('Deux cartes se ressemblent trop'), findsOneWidget);
  });

  testWidgets('le relevé chiffré reste sous le conseil', (tester) async {
    // Le conseil se lit sur le terrain, les chiffres se relisent au poste de
    // travail : une passe qu'on ne peut pas relire est une passe perdue.
    await pump(tester, passe(FrameOutcome.notFound));

    expect(find.textContaining('sans carte 100 %'), findsOneWidget);
  });
}
