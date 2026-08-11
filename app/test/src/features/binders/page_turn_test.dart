/// Tests du retournement de feuille.
///
/// **Ce qui se teste ici est le geste, pas l'esthétique.** Qu'une feuille soit
/// jolie en pivotant ne se vérifie qu'à l'œil ; qu'elle tourne dans le bon sens,
/// qu'un frôlement ne la tourne pas, et qu'un geste franc l'emporte, se vérifie
/// et doit le rester.
///
/// Le second volet est la **géométrie de la courbure** : dix facettes qui
/// cessent de se rejoindre laissent passer le jour entre elles, et l'on voit
/// alors la page du dessous à travers une feuille pourtant opaque.
///
/// Le point le plus facile à casser est le **sens** : la reliure étant à gauche,
/// glisser vers la gauche avance. L'inverser ne casse aucun test d'affichage et
/// rend le classeur incompréhensible.
library;

import 'dart:math' as math;

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

/// Bord droit d'une lamelle, déduit de sa pose et de sa longueur.
({double x, double z}) rightEdge(StripePlacement p, double length) =>
    (x: p.x + length * math.cos(p.angle), z: p.z - length * math.sin(p.angle));

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

  const width = 360.0;
  const stripes = 10;
  const stripeWidth = width / stripes;

  group('les lamelles restent jointes', () {
    // Tout au long du geste, et pas seulement à plat : l'écart s'ouvrait avec
    // la courbure, donc au milieu du mouvement.
    for (final t in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]) {
      test('à t = $t, chacune commence où la précédente finit', () {
        final placements = stripePlacements(t: t, width: width);
        expect(placements, hasLength(stripes));

        for (var i = 0; i < placements.length - 1; i++) {
          final end = rightEdge(placements[i], stripeWidth);
          final next = placements[i + 1];

          expect(
            end.x,
            closeTo(next.x, 1e-9),
            reason: 'fente horizontale entre les lamelles $i et ${i + 1}',
          );
          expect(
            end.z,
            closeTo(next.z, 1e-9),
            reason: 'décrochement en profondeur entre $i et ${i + 1}',
          );
        }
      });
    }
  });

  group('la courbure', () {
    test('est nulle au repos, aux deux extrémités du geste', () {
      // Une page posée est plate : elle n'a aucune raison d'arriver pliée sur
      // la pile, ni d'en repartir courbée.
      for (final t in [0.0, 1.0]) {
        final angles = stripePlacements(
          t: t,
          width: width,
        ).map((p) => p.angle).toSet();
        expect(angles, hasLength(1), reason: 'toutes les facettes alignées');
      }
    });

    test('se concentre vers le bord libre', () {
      // Le profil pince la page vers son extrémité plutôt que de l'enrouler en
      // tuyau : l'angle croît d'une lamelle à l'autre, et de plus en plus vite.
      final placements = stripePlacements(t: 0.5, width: width);
      final steps = [
        for (var i = 0; i < placements.length - 1; i++)
          placements[i + 1].angle - placements[i].angle,
      ];

      expect(steps.every((s) => s > 0), isTrue, reason: 'angle croissant');
      for (var i = 0; i < steps.length - 1; i++) {
        expect(steps[i + 1], greaterThan(steps[i]));
      }
    });

    test('emmène la feuille vers l\'œil, jamais dans le classeur', () {
      // Une profondeur positive donnerait l'impression de pousser la page au
      // fond de la reliure au lieu de la soulever.
      final placements = stripePlacements(t: 0.5, width: width);
      expect(placements.every((p) => p.z <= 0), isTrue);
      expect(placements.last.z, lessThan(0));
    });
  });
}
