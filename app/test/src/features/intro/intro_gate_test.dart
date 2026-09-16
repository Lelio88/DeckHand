/// L'intro recouvre-t-elle l'accueil, ou le retarde-t-elle ?
///
/// **C'est toute la question, et elle se tranche par un test.** Une intro qui
/// précède l'accueil ajoute ses 2,2 s à une attente déjà mesurée jusqu'à 7,4 s
/// au premier appel d'une session froide. Une intro qui le recouvre les en
/// retranche. Les deux se ressemblent à l'écran — on voit une animation puis
/// l'application — et rien ne les distingue sinon le moment où les requêtes
/// partent.
///
/// Ces tests affirment donc ce qu'on ne peut pas voir : que l'accueil est bâti
/// **dès le premier frame**, sous l'animation.
library;

import 'package:deckhand/src/features/intro/presentation/intro_gate.dart';
import 'package:deckhand/src/features/intro/presentation/intro_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un faux accueil qui dit quand il a été bâti, et combien de fois.
class AccueilTemoin extends StatefulWidget {
  const AccueilTemoin({super.key, required this.journal});

  final List<String> journal;

  @override
  State<AccueilTemoin> createState() => _AccueilTemoinState();
}

class _AccueilTemoinState extends State<AccueilTemoin> {
  @override
  void initState() {
    super.initState();
    widget.journal.add('monté');
  }

  @override
  Widget build(BuildContext context) {
    widget.journal.add('bâti');
    return const Center(child: Text('accueil'));
  }
}

/// Monte la porte avec le témoin. Le son est coupé : il n'existe pas en test.
Future<List<String>> monter(WidgetTester tester) async {
  final journal = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: IntroGate(
        playSound: false,
        child: AccueilTemoin(journal: journal),
      ),
    ),
  );
  return journal;
}

void main() {
  testWidgets("l'accueil est monté dès le premier frame, sous l'intro", (
    tester,
  ) async {
    final journal = await monter(tester);

    // **Le point du dispositif.** Si l'accueil n'était bâti qu'à la fin, ses
    // requêtes ne partiraient qu'après l'animation et celle-ci coûterait deux
    // secondes au lieu d'en faire gagner.
    expect(journal, contains('monté'));
    expect(find.byType(IntroScreen), findsOneWidget);

    // Il est dans l'arbre, et l'intro le couvre : les deux coexistent.
    expect(find.text('accueil'), findsOneWidget);
  });

  testWidgets("passé le plancher, l'intro s'efface", (tester) async {
    await monter(tester);
    expect(find.byType(IntroScreen), findsOneWidget);

    await tester.pump(introFloor + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.byType(IntroScreen), findsNothing);
    expect(find.text('accueil'), findsOneWidget);
  });

  testWidgets("une touche saute l'attente", (tester) async {
    await monter(tester);

    await tester.tap(find.byType(IntroScreen));
    await tester.pumpAndSettle();

    expect(find.byType(IntroScreen), findsNothing);
  });

  testWidgets("l'accueil n'est pas reconstruit quand l'intro s'efface", (
    tester,
  ) async {
    // **Ce qui serait perdu s'il l'était** : les requêtes en vol. Une
    // reconstruction les relancerait, et le temps couvert par l'animation
    // serait payé deux fois — le contraire exact de ce qu'on cherche.
    final journal = await monter(tester);
    final montagesAvant = journal.where((e) => e == 'monté').length;

    await tester.pump(introFloor + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(journal.where((e) => e == 'monté').length, montagesAvant);
    expect(montagesAvant, 1);
  });

  testWidgets("l'animation dure ce que dure celle de DewDrop", (tester) async {
    // Contrainte (a) : la même durée, à la centaine de millisecondes près qui
    // laisse voir la dernière image.
    expect(introDuration, const Duration(milliseconds: 2200));
    expect(introFloor.inMilliseconds - introDuration.inMilliseconds, 100);
  });

  testWidgets("démontée en cours de route, elle ne réveille personne", (
    tester,
  ) async {
    await monter(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const MaterialApp(home: Text('ailleurs')));
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('ailleurs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
