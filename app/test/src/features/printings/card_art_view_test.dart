/// Tests de l'aperçu plein écran, centrés sur le bandeau de repli.
///
/// **Ce qu'ils protègent.** Quand l'édition reconnue n'a pas d'illustration
/// au catalogue, l'aperçu en montre une autre plutôt qu'un cadre vide — mais
/// sans bandeau, rien ne distingue ce repli d'une carte correctement
/// identifiée. Le silence serait un mensonge par omission : l'utilisateur
/// validerait « en bloc » (§IV.8) en croyant regarder sa propre édition.
library;

import 'package:deckhand/src/common/card_image.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:deckhand/src/features/printings/presentation/card_art_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

const _bandeau = "Illustration d'une autre édition — celle-ci n'en a pas";

CardPrinting printing({
  required String printId,
  String? artCropUrl,
}) => CardPrinting(
  printId: printId,
  setCode: 'mh2',
  setName: 'Modern Horizons 2',
  collectorNumber: '123',
  lang: 'en',
  artCropUrl: artCropUrl,
);

Future<void> pumpArt(
  WidgetTester tester, {
  required List<CardPrinting> printings,
  String? printId,
}) async {
  final repository = FakePrintingRepository()..printings = printings;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [printingRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showCardArt(
                context,
                oracleId: 'oracle-1',
                title: 'Foudre',
                printId: printId,
              ),
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ),
  );

  // Ni `pump` ni `pumpAndSettle` seuls ne conviennent ici : le dialogue
  // s'ouvre en s'animant, et l'illustration en grand porte elle-même un
  // indicateur de chargement indéterminé tant que l'image réseau ne répond
  // pas — ce qui n'arrive jamais dans un test, sans quoi `pumpAndSettle`
  // boucle jusqu'au délai d'attente. Ce que ce test regarde (le bandeau, et
  // l'URL retenue par `CardImage`) est déjà posé dès que le dialogue est
  // ouvert et que les éditions ont résolu, sans attendre l'image elle-même.
  await tester.tap(find.text('ouvrir'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  testWidgets(
    "l'édition demandée sans illustration montre le bandeau de repli",
    (tester) async {
      await pumpArt(
        tester,
        printId: 'print-sans-image',
        printings: [
          printing(printId: 'print-sans-image', artCropUrl: null),
          printing(
            printId: 'print-avec-image',
            artCropUrl: 'https://exemple/mh2.jpg',
          ),
        ],
      );

      expect(find.text(_bandeau), findsOneWidget);
      expect(
        tester.widget<CardImage>(find.byType(CardImage)).url,
        'https://exemple/mh2.jpg',
        reason: 'à défaut de la sienne, une autre illustration doit '
            'tout de même être montrée plutôt qu\'un cadre vide',
      );
    },
  );

  testWidgets(
    "l'édition demandée avec son illustration ne montre aucun bandeau",
    (tester) async {
      await pumpArt(
        tester,
        printId: 'print-avec-image',
        printings: [
          printing(
            printId: 'print-avec-image',
            artCropUrl: 'https://exemple/mh2.jpg',
          ),
        ],
      );

      expect(find.text(_bandeau), findsNothing);
    },
  );

  testWidgets(
    "sans édition connue, montrer la première illustration n'est pas un "
    'repli à signaler',
    (tester) async {
      await pumpArt(
        tester,
        printId: null,
        printings: [
          printing(
            printId: 'print-avec-image',
            artCropUrl: 'https://exemple/mh2.jpg',
          ),
        ],
      );

      expect(find.text(_bandeau), findsNothing);
    },
  );
}
