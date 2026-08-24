/// Le classeur qui s'ouvre, mesuré plutôt que regardé (#21).
///
/// **Ce qu'une animation cache.** Elle a l'air juste tant qu'on la regarde
/// distraitement : une carte qui sort du mauvais coin, un numéro de page qui
/// dépasse sa cible, un défilé qui s'allonge sans fin sur une grosse extension
/// — rien de tout cela ne se voit à l'œil sur un direct qui bouge. Le widget est
/// donc **pur**, piloté par un temps qu'on lui donne, et ces tests l'interrogent
/// à des instants choisis.
///
/// **Le contrôle le plus utile est celui de la trajectoire.** Toute la
/// différence entre « une carte apparaît » et « *cette* carte-là sort d'ici »
/// tient à ce que le point de départ soit la case annoncée par `!card`. Une
/// erreur d'un cran dans le calcul de ligne ou de colonne donnerait une
/// animation parfaitement fluide et parfaitement fausse.
library;

import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/domain/spotlight_card.dart';
import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:deckhand/src/features/binders/presentation/overlay_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SpotlightCard carte({int page = 3, int slot = 5, String? by = 'alice'}) =>
    SpotlightCard(
      requestId: 1,
      name: 'Ka-Zar',
      printedName: 'Ka-Zar',
      requestedBy: by,
      setCode: 'msh',
      setName: 'Marvel Super Heroes',
      collectorNumber: '185',
      priceEur: 2.4,
      copies: 1,
      page: page,
      slot: slot,
      pages: 51,
    );

List<BinderCell> pageDe(List<int> possedees) => [
  for (var i = 1; i <= 9; i++)
    BinderCell(collectorNumber: '$i', owned: possedees.contains(i) ? 1 : 0),
];

void main() {
  group('le tempo', () {
    test("l'intro laisse le temps de regarder la carte", () {
      // **La contrainte dure, et elle vient d'ailleurs.** Le calque efface la
      // carte au bout d'`overlayLinger` : une intro qui mange ce délai
      // priverait le spectateur de ce pour quoi il a tapé la commande.
      final pire = RevealTiming(500).total;
      expect(pire, lessThanOrEqualTo(2400));
      expect(pire, lessThan(overlayLinger.inMilliseconds / 4));
    });

    test('la page 1 ne feuillette pas', () {
      // Feuilleter pour rester sur place serait un mensonge, et une seconde
      // perdue.
      expect(RevealTiming(1).riffle, 0);
      expect(RevealTiming(1).riffleAt(0), 1);
    });

    test('le défilé est plafonné, pas proportionnel', () {
      // Une extension de cinq cents pages ne doit pas coûter douze secondes de
      // feuilletage. Au-delà du plafond, le flou est déjà du flou.
      expect(RevealTiming(20).riffle, lessThan(RevealTiming(51).riffle));
      expect(RevealTiming(51).riffle, RevealTiming(500).riffle);
    });

    test('le numéro monte et s_arrête sur le bon', () {
      const t = RevealTiming(46);
      expect(t.pageAt(0), 1);
      expect(t.pageAt(RevealTiming.open + t.riffle / 2), inInclusiveRange(2, 45));
      expect(t.pageAt(RevealTiming.open + t.riffle), 46);
      // **Il ne dépasse jamais.** Un compteur qui afficherait 47 une frame
      // avant de se poser rendrait tout le procédé suspect.
      expect(t.pageAt(t.total), 46);
      expect(t.pageAt(t.total * 10), 46);
    });

    test('les phases ne se chevauchent pas', () {
      const t = RevealTiming(10);
      // La carte ne bouge pas tant que la page n_est pas posée.
      expect(t.ejectAt(RevealTiming.open + t.riffle), 0);
      expect(t.ejectAt(t.total), 1);
    });
  });

  group('la trajectoire', () {
    test('la carte part de SA case', () {
      // Le contrôle qui vaut tous les autres : une erreur d_un cran donnerait
      // une animation fluide et fausse.
      for (var slot = 1; slot <= 9; slot++) {
        expect(RevealMetrics.cardRect(slot, 0), RevealMetrics.slotRect(slot));
      }
    });

    test('et finit toujours au même endroit', () {
      for (var slot = 1; slot <= 9; slot++) {
        expect(RevealMetrics.cardRect(slot, 1), RevealMetrics.heroRect);
      }
    });

    test('les neuf cases sont distinctes et en lecture occidentale', () {
      final vues = <Rect>{};
      for (var slot = 1; slot <= 9; slot++) {
        vues.add(RevealMetrics.slotRect(slot));
      }
      expect(vues.length, 9);
      // 1 2 3 sur la première ligne, 4 au début de la seconde.
      expect(RevealMetrics.slotRect(1).top, RevealMetrics.slotRect(3).top);
      expect(RevealMetrics.slotRect(1).left, RevealMetrics.slotRect(4).left);
      expect(
        RevealMetrics.slotRect(4).top,
        greaterThan(RevealMetrics.slotRect(1).top),
      );
    });

    test('la grille tient dans la planche', () {
      for (var slot = 1; slot <= 9; slot++) {
        final r = RevealMetrics.slotRect(slot);
        expect(r.right, lessThanOrEqualTo(RevealMetrics.width));
        expect(r.bottom, lessThanOrEqualTo(RevealMetrics.height));
      }
      expect(
        RevealMetrics.heroRect.right,
        lessThanOrEqualTo(RevealMetrics.width),
      );
    });
  });

  group('ce qui se dessine', () {
    Future<void> poser(
      WidgetTester tester, {
      required double elapsed,
      SpotlightCard? card,
      List<BinderCell> cells = const [],
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: BinderReveal(
              card: card ?? carte(),
              cells: cells,
              elapsed: elapsed,
            ),
          ),
        ),
      ),
    );

    testWidgets('la légende nomme la carte, sa case et son demandeur', (
      tester,
    ) async {
      await poser(tester, elapsed: RevealTiming(3).total);
      expect(find.text('Ka-Zar'), findsOneWidget);
      expect(find.textContaining('page 3'), findsOneWidget);
      expect(find.textContaining('case 5'), findsOneWidget);
      expect(find.textContaining('alice'), findsOneWidget);
      expect(find.textContaining('2,40 €'), findsOneWidget);
    });

    testWidgets('le nom ne s_affiche qu_une fois', (tester) async {
      // **Un défaut trouvé par ce test, pas à l_œil.** Le repli de
      // l_illustration affichait le nom de la carte, que la légende porte
      // déjà : deux « Ka-Zar » à l_écran, dont un dans le carton.
      await poser(tester, elapsed: RevealTiming(3).total);
      expect(find.text('Ka-Zar'), findsOneWidget);
    });

    testWidgets('le numéro de page affiché suit le défilé', (tester) async {
      const t = RevealTiming(46);
      await poser(tester, elapsed: 0, card: carte(page: 46));
      expect(find.textContaining('page 1'), findsOneWidget);

      await poser(tester, elapsed: t.total, card: carte(page: 46));
      expect(find.textContaining('page 46'), findsOneWidget);
    });

    testWidgets('la planche se dessine sans connaître les voisines', (
      tester,
    ) async {
      // La lecture de la page est un second appel : son échec ne doit pas
      // empêcher la carte de sortir.
      await poser(tester, elapsed: RevealTiming(3).total);
      expect(find.text('Ka-Zar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('et elle les montre quand elles arrivent', (tester) async {
      await poser(
        tester,
        elapsed: RevealTiming(3).total,
        cells: pageDe([1, 2, 5]),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(BinderReveal), findsOneWidget);
    });

    testWidgets('un demandeur inconnu ne s_invente pas un nom', (tester) async {
      await poser(
        tester,
        elapsed: RevealTiming(3).total,
        card: carte(by: null),
      );
      expect(find.textContaining('demandée dans le chat'), findsOneWidget);
    });

    testWidgets("l_attribution est visible, garde-fou §IV.2", (tester) async {
      await poser(tester, elapsed: RevealTiming(3).total);
      expect(find.textContaining('Scryfall'), findsOneWidget);
    });
  });
}
