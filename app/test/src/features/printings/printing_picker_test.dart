/// Tests du sélecteur d'éditions : l'ordre du catalogue, le filtre par époque,
/// la suite des éditions.
///
/// **Le sélecteur ne lit rien sur la photo** : c'est l'écran photo qui précise
/// l'édition, par la ligne basse (issue n°50). Ici, l'utilisateur choisit.
library;

import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:deckhand/src/features/printings/domain/printing_era.dart';
import 'package:deckhand/src/features/printings/presentation/printing_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';
import '../../helpers/finders.dart';

CardPrinting printing(
  String setCode,
  String number, {
  String? setName,
  DateTime? releasedAt,
}) => CardPrinting(
  printId: '$setCode-$number',
  setCode: setCode,
  setName: setName ?? setCode.toUpperCase(),
  collectorNumber: number,
  lang: 'fr',
  priceEur: 1.0,
  hasNonfoil: true,
  releasedAt: releasedAt,
);

/// Ouvre le sélecteur et rend l'ordre des extensions tel qu'il est affiché.
Future<List<String>> pumpPicker(
  WidgetTester tester, {
  required List<CardPrinting> printings,
}) async {
  final repository = FakePrintingRepository()..printings = printings;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [printingRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showPrintingPicker(
                context,
                oracleId: 'oracle-1',
                cardName: 'Agent Phil Coulson',
              ),
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();

  return tester
      .widgetList<ListTile>(find.byType(ListTile))
      .map((tile) => ((tile.subtitle! as Text).data)!.split(' · ').first)
      .toList(growable: false);
}

void main() {
  final catalogue = [
    printing('mkm', '12', setName: "Meurtres au manoir Karlov"),
    printing('msh', '412', setName: 'Marvel Super Heroes'),
    printing('msh', '598', setName: 'Marvel Super Heroes'),
    printing('lci', '77', setName: "Les caveaux perdus d'Ixalan"),
  ];

  testWidgets('l\'ordre du catalogue est conservé', (
    tester,
  ) async {
    final order = await pumpPicker(tester, printings: catalogue);

    expect(order, ['MKM', 'MSH', 'MSH', 'LCI']);
  });

  group('le filtre par époque', () {
    // Trois éditions largement espacées dans le temps : c'est le cas d'un
    // terrain de base, où le tri par sortie la plus récente enterre les plus
    // anciennes derrière des centaines de réimpressions.
    final byYear = [
      printing('lea', '1', setName: 'Alpha', releasedAt: DateTime(1993, 8, 5)),
      printing(
        'm10',
        '1',
        setName: 'Magic 2010',
        releasedAt: DateTime(2009, 7, 17),
      ),
      printing(
        'm21',
        '1',
        setName: 'Magic 2021',
        releasedAt: DateTime(2020, 7, 3),
      ),
    ];

    Future<FakePrintingRepository> pumpPickerOpen(WidgetTester tester) async {
      final repository = FakePrintingRepository()..printings = byYear;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [printingRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showPrintingPicker(
                    context,
                    oracleId: 'oracle-1',
                    cardName: 'Agent Phil Coulson',
                  ),
                  child: const Text('ouvrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('sans choix, toutes les époques sont visibles', (tester) async {
      await pumpPickerOpen(tester);

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Magic 2010'), findsOneWidget);
      expect(find.text('Magic 2021'), findsOneWidget);
    });

    testWidgets('choisir une tranche ne garde que les éditions qui y tombent', (
      tester,
    ) async {
      final repository = await pumpPickerOpen(tester);

      await tester.tap(find.text('Année'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Avant 2000'));
      await tester.pumpAndSettle();

      expect(repository.lastEra, PrintingEra.before2000);
      expect(find.text('Alpha'), findsOneWidget);
      expect(
        find.text('Magic 2010'),
        findsNothing,
        reason: '2009 tombe hors de la tranche « avant 2000 »',
      );
      expect(find.text('Magic 2021'), findsNothing);
    });

    testWidgets('le bouton affiche la tranche choisie', (tester) async {
      await pumpPickerOpen(tester);

      await tester.tap(find.text('Année'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('2020+'));
      await tester.pumpAndSettle();

      expect(
        find.text('Année'),
        findsNothing,
        reason:
            'le bouton porte maintenant la tranche choisie, pas son nom '
            'générique',
      );
      expect(find.text('2020+'), findsOneWidget);
    });

    testWidgets('brillante et période : le message nomme la période', (
      tester,
    ) async {
      // Aucune de ces éditions n'existe en brillant. Dire seulement « aucune
      // édition brillante » laisserait croire que la carte n'en a nulle part,
      // alors que c'est la période choisie qui vide aussi la liste.
      await pumpPickerOpen(tester);

      await tester.tap(find.text('Brillante'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Année'));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('Avant 2000'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Aucune édition brillante connue pour cette carte sur cette période '
          '(Avant 2000).',
        ),
        findsOneWidget,
      );
    });
  });

  group('la suite des éditions', () {
    // Dix éditions de plus qu'une page : le cas des cartes réimprimées plus de
    // soixante fois, terrains de base en tête.
    final many = [
      for (var i = 0; i < printingsPageSize + 10; i++)
        printing('s${i.toString().padLeft(3, '0')}', '1'),
    ];

    Future<FakePrintingRepository> open(
      WidgetTester tester,
      List<CardPrinting> printings,
    ) async {
      final repository = FakePrintingRepository()..printings = printings;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [printingRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showPrintingPicker(
                    context,
                    oracleId: 'oracle-1',
                    cardName: 'Forêt',
                  ),
                  child: const Text('ouvrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      return repository;
    }

    testWidgets('une page pleine propose la suite, qui s\'ajoute à la liste', (
      tester,
    ) async {
      final repository = await open(tester, many);
      final more = find.text('Charger la suite');
      final list = find.byType(Scrollable).last;

      await tester.scrollUntilVisible(more, 400, scrollable: list);
      await tester.tap(more);
      await tester.pumpAndSettle();

      expect(repository.lastOffset, printingsPageSize);
      await tester.scrollUntilVisible(find.text('S069'), 400, scrollable: list);
      expect(find.text('S069'), findsOneWidget);
      expect(
        find.text('Charger la suite'),
        findsNothing,
        reason: 'la seconde page est incomplète : il ne reste rien à charger',
      );
    });

    testWidgets('une page incomplète ne propose aucune suite', (tester) async {
      await open(tester, many.take(3).toList());

      expect(find.text('Charger la suite'), findsNothing);
    });

    testWidgets('la finition part au serveur et ramène à la première page', (
      tester,
    ) async {
      final repository = await open(tester, many);
      final list = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.text('Charger la suite'),
        400,
        scrollable: list,
      );
      await tester.tap(find.text('Charger la suite'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Brillante'));
      await tester.pumpAndSettle();

      expect(repository.lastFoil, isTrue);
      expect(
        repository.lastOffset,
        0,
        reason: 'la suite d\'une autre finition ne dit rien de celle-ci',
      );
    });
  });
}
