/// Ce que coûte une image du calque `!montre`, en widgets et en millisecondes.
///
/// **Pourquoi un banc plutôt qu'un œil.** « Ça lag » ne dit pas *où* : le calque
/// dessine, à chaque image, une planche entière, neuf cases avec leurs
/// illustrations, et jusqu'à trois feuilles en vol découpées en dix lamelles
/// chacune. La lamelle est le multiplicateur qu'on oublie — elle **reconstruit
/// la face entière** pour n'en garder qu'une tranche, si bien qu'une page de
/// neuf cases posée dans une feuille est bâtie trente fois par image.
///
/// **Deux chiffres, pas un.** Le temps de `pump` mesure construction, mise en
/// page et peinture — il varie d'une machine à l'autre et ne vaut que comparé à
/// lui-même. Le **nombre de widgets** ne varie pas : c'est la mesure qui se cite
/// et qui se compare d'un jour à l'autre.
///
/// Il est **sauté par `flutter test`** — un banc n'a rien à dire dans une suite
/// de non-régression, et son temps dépend de la machine. Pour le jouer :
///
///     cd app && DECKHAND_BENCH=1 flutter test test/bench_montre_test.dart
library;

import 'dart:io';

import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/domain/spotlight_request.dart';
import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _cases = <BinderCell>[
  for (var i = 1; i <= 9; i++)
    BinderCell(
      collectorNumber: '${423 + i}',
      owned: i == 7 || i == 8 ? 1 : 0,
      hasFoil: i == 7,
      artCropUrl: 'https://cards.scryfall.io/art_crop/front/a/b/carte-$i.jpg',
    ),
];

const _carte = SpotlightCard(
  requestId: 1,
  name: 'Daredevil, Man Without Fear',
  requestedBy: 'alice',
  setCode: 'msh',
  setName: 'Marvel Super Heroes',
  collectorNumber: '431',
  priceEur: 0.39,
  copies: 1,
  page: 48,
  slot: 8,
  pages: 51,
);

void main() {
  testWidgets(
    'le coût d_une image du calque',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1600, 1240);
      addTearDown(tester.view.reset);

      const t = RevealTiming(48);

      Future<void> poser(double elapsed) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BinderReveal(
                request: _carte,
                cells: _cases,
                elapsed: elapsed,
              ),
            ),
          ),
        ),
      );

      // Une image en plein feuilletage : c'est là que le coût est maximal.
      await poser(RevealTiming.open + t.riffle * 0.3);
      final enVol = tester.allWidgets.length;

      // Une image posée, sans feuille : la planche seule, pour la référence.
      await poser(t.total);
      final posee = tester.allWidgets.length;

      Future<double> chronometrer(double Function(int) instant) async {
        await poser(instant(0));
        final horloge = Stopwatch()..start();
        for (var k = 1; k <= 60; k++) {
          await poser(instant(k));
        }
        horloge.stop();
        return horloge.elapsedMicroseconds / 60 / 1000;
      }

      // Le feuilletage, puis la planche seule : deux budgets à distinguer, faute
      // de quoi on réglerait les feuilles alors que le coût est ailleurs.
      final enFeuilletage = await chronometrer(
        (k) => RevealTiming.open + t.riffle * k / 60,
      );
      final sansFeuille = await chronometrer((k) => t.total + k * 0.01);

      stdout.writeln(
        [
          '',
          '  widgets en vol   : $enVol',
          '  widgets posée    : $posee',
          '  coût des feuilles: ${enVol - posee} widgets',
          '  pump feuilletage : ${enFeuilletage.toStringAsFixed(2)} ms',
          '  pump planche     : ${sansFeuille.toStringAsFixed(2)} ms',
          '  dont feuilles    : '
              '${(enFeuilletage - sansFeuille).toStringAsFixed(2)} ms',
          '',
        ].join('\n'),
      );
    },
    skip: Platform.environment['DECKHAND_BENCH'] == null,
  );
}
