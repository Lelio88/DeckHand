/// Le tapis de présentation, mesuré plutôt que regardé (#21).
///
/// **Ce qu'une capture ne dit pas.** Elle montre que quatre cartes tiennent ;
/// elle ne dit pas qu'à dix elles tiennent encore, qu'à quatorze on tronque en
/// le disant, ni qu'une seule reste centrée. Ces trois-là sont exactement les
/// cas qu'on ne pense pas à regarder.
library;

import 'package:deckhand/src/features/binders/domain/spotlight_request.dart';
import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:deckhand/src/features/binders/presentation/card_mat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SpotlightStrip unTapis(int n, {String? by = 'carol'}) => SpotlightStrip(
  requestId: 3,
  requestedBy: by,
  entries: [
    for (var i = 0; i < n; i++)
      SpotlightCard(
        requestId: 3,
        name: 'Forest',
        printedName: 'Forêt',
        setCode: 'msh',
        setName: 'Marvel Super Heroes',
        collectorNumber: '${285 + i}',
        artCropUrl: 'https://cards.scryfall.io/art_crop/front/a/b/f$i.jpg',
        copies: 2,
      ),
  ],
);

void main() {
  group('la géométrie', () {
    test('jusqu_à six, une carte garde la taille d_une case de classeur', () {
      for (var n = 1; n <= 6; n++) {
        expect(
          MatMetrics.cardSize(n).width,
          RevealMetrics.cellWidth,
          reason: '$n cartes',
        );
      }
    });

    test('au-delà, elle rétrécit — et dix tiennent encore', () {
      expect(MatMetrics.cardSize(8).width, lessThan(RevealMetrics.cellWidth));
      expect(
        MatMetrics.cardSize(10).width,
        lessThan(MatMetrics.cardSize(8).width),
      );
      // Le plafond est mesuré : à dix, une carte fait encore 57 points de large.
      expect(MatMetrics.cardSize(10).width, greaterThan(50));
      // Et rien ne déborde de la planche.
      for (var n = 1; n <= MatMetrics.maxCards; n++) {
        final total =
            MatMetrics.cardSize(n).width * n +
            MatMetrics.gap * (n - 1) +
            2 * MatMetrics.pad;
        expect(
          total,
          lessThanOrEqualTo(MatMetrics.maxWidth + 1e-9),
          reason: '$n',
        );
      }
    });

    test('les cartes gardent le rapport d_une carte', () {
      for (final n in [1, 4, 10]) {
        final t = MatMetrics.cardSize(n);
        expect(
          t.width / t.height,
          closeTo(RevealMetrics.cellWidth / RevealMetrics.cellHeight, 1e-9),
        );
      }
    });

    test('le tapis suit son contenu, entre deux bornes', () {
      // Sa seule raison d_exister est de tenir peu de place : un panneau de
      // pleine largeur pour quatre cartes serait un grand rectangle sombre.
      expect(MatMetrics.width(1), MatMetrics.minWidth);
      expect(MatMetrics.width(4), greaterThan(MatMetrics.width(1)));
      expect(MatMetrics.width(4), lessThan(MatMetrics.maxWidth));
      expect(MatMetrics.width(10), MatMetrics.maxWidth);
    });
  });

  group('le tempo', () {
    test('les cartes se posent l_une après l_autre', () {
      const t = MatTiming(4);
      // À l_instant zéro, la première commence et les autres n_ont pas bougé.
      expect(t.at(0, 0), 0);
      expect(t.at(3, 0), 0);
      expect(t.at(0, MatTiming.arrival), 1);
      expect(t.at(3, MatTiming.arrival), lessThan(1));
      // Et tout est posé à la fin.
      for (var i = 0; i < 4; i++) {
        expect(t.at(i, t.total), 1, reason: 'carte $i');
      }
    });

    test('dix cartes tiennent dans le délai d_affichage', () {
      // **La contrainte vient d_ailleurs** : le calque efface au bout
      // d_`overlayLinger`. Une arrivée qui mangerait ce délai priverait le
      // spectateur de ce pour quoi il a tapé la commande.
      expect(const MatTiming(10).total, lessThan(2000));
    });
  });

  group('ce qui se dessine', () {
    Future<void> poser(WidgetTester tester, SpotlightStrip tapis) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: CardMat(
                  strip: tapis,
                  elapsed: MatTiming(tapis.entries.length).total,
                ),
              ),
            ),
          ),
        );

    testWidgets('il nomme la carte, compte les versions et son demandeur', (
      tester,
    ) async {
      await poser(tester, unTapis(4));
      expect(find.textContaining('Forêt'), findsOneWidget);
      expect(find.textContaining('4 versions'), findsOneWidget);
      expect(find.textContaining('demandée par carol'), findsOneWidget);
      // Garde-fou §IV.2 : le crédit est visible de qui regarde.
      expect(find.text('Scryfall'), findsOneWidget);
    });

    testWidgets('une seule version s_accorde au singulier', (tester) async {
      await poser(tester, unTapis(1));
      expect(find.textContaining('1 version'), findsOneWidget);
      expect(find.textContaining('1 versions'), findsNothing);
    });

    testWidgets('au-delà de dix, il tronque **en le disant**', (tester) async {
      // Tronquer en silence se lirait « j_en ai dix ».
      await poser(tester, unTapis(14));
      expect(find.textContaining('10 des 14 versions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('un demandeur inconnu ne s_invente pas un nom', (tester) async {
      await poser(tester, unTapis(2, by: null));
      expect(find.textContaining('demandée dans le chat'), findsOneWidget);
    });

    testWidgets('un tapis vide ne dessine rien', (tester) async {
      // La portée peut avoir retiré toutes les versions après coup.
      await poser(tester, unTapis(0));
      expect(find.text('Scryfall'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('la lecture des lignes', () {
    test('plusieurs lignes ne font qu_une demande', () {
      // **Le défaut que ce test empêche** : lire `rows.first` montrerait une
      // seule version d_un tapis, sans erreur ni signal.
      final lu = SpotlightRequest.fromRows([
        for (var i = 0; i < 3; i++)
          {
            'request_id': 7,
            'kind': 'strip',
            'requested_by': 'carol',
            'name': 'Forest',
            'set_code': 'msh',
            'collector_number': '${285 + i}',
          },
      ]);
      expect(lu, isA<SpotlightStrip>());
      expect((lu! as SpotlightStrip).entries, hasLength(3));
      expect(lu.requestId, 7);
    });

    test('un genre absent se lit comme une carte', () {
      // Une base antérieure à la migration ne rend pas la colonne.
      final lu = SpotlightRequest.fromRows([
        {'request_id': 1, 'name': 'Ka-Zar', 'set_code': 'msh'},
      ]);
      expect(lu, isA<SpotlightCard>());
    });
  });
}
