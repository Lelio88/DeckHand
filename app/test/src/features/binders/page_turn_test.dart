/// Tests du retournement de feuille.
///
/// **Ce qui se teste ici est le geste, pas l'esthétique.** Qu'une feuille soit
/// jolie en pivotant ne se vérifie qu'à l'œil ; qu'elle tourne dans le bon sens,
/// qu'un frôlement ne la tourne pas, et qu'un geste franc l'emporte, se vérifie
/// et doit le rester.
///
/// Le point le plus facile à casser est le **sens** : la reliure étant à gauche,
/// glisser vers la gauche avance. L'inverser ne casse aucun test d'affichage et
/// rend le classeur incompréhensible.
library;

import 'package:deckhand/src/features/binders/presentation/page_turn.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<int>> pumpTurner(
  WidgetTester tester, {
  int page = 5,
  int pageCount = 10,
}) async {
  final turned = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PageTurner(
          page: page,
          pageCount: pageCount,
          onTurned: turned.add,
          builder: (context, p) => ColoredBox(
            color: Colors.white,
            child: Center(child: Text('page $p')),
          ),
        ),
      ),
    ),
  );
  return turned;
}

void main() {
  testWidgets('glisser vers la gauche avance', (tester) async {
    // La reliure est à gauche : on tourne la feuille vers elle pour avancer,
    // comme sur un classeur ouvert à plat.
    final turned = await pumpTurner(tester);

    await tester.fling(find.byType(PageTurner), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    expect(turned, [6]);
  });

  testWidgets('glisser vers la droite revient en arrière', (tester) async {
    final turned = await pumpTurner(tester);

    await tester.fling(find.byType(PageTurner), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();

    expect(turned, [4]);
  });

  testWidgets('un frôlement ne tourne rien', (tester) async {
    // Sous le tiers de la largeur et sans élan, la feuille retombe : sinon le
    // moindre effleurement en faisant défiler tournerait une page.
    final turned = await pumpTurner(tester);

    final centre = tester.getCenter(find.byType(PageTurner));
    final gesture = await tester.startGesture(centre);
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(turned, isEmpty);
  });

  testWidgets('la dernière feuille ne se tourne pas', (tester) async {
    final turned = await pumpTurner(tester, page: 10, pageCount: 10);

    await tester.fling(find.byType(PageTurner), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();

    expect(turned, isEmpty);
  });

  testWidgets('la première feuille ne recule pas', (tester) async {
    final turned = await pumpTurner(tester, page: 1, pageCount: 10);

    await tester.fling(find.byType(PageTurner), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();

    expect(turned, isEmpty);
  });

  testWidgets('la feuille du dessous se découvre pendant le mouvement', (
    tester,
  ) async {
    // C'est ce qui distingue un retournement d'un fondu : la page suivante est
    // déjà là, on la découvre à mesure que l'autre se soulève.
    await pumpTurner(tester);

    final centre = tester.getCenter(find.byType(PageTurner));
    final gesture = await tester.startGesture(centre);
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump();

    // La feuille en mouvement est découpée en lamelles pour se courber : sa
    // face est donc construite plusieurs fois, une par tranche.
    expect(find.text('page 5'), findsWidgets);
    expect(find.text('page 6'), findsWidgets);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('au repos, une seule feuille est construite', (tester) async {
    // Neuf cartes entières par feuille : en garder deux à l'écran hors
    // mouvement doublerait la charge pour rien.
    await pumpTurner(tester);

    expect(find.text('page 5'), findsOneWidget);
    expect(find.text('page 6'), findsNothing);
    expect(find.text('page 4'), findsNothing);
  });
}
