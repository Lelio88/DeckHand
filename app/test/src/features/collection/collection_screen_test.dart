/// Tests de l'écran de collection.
///
/// **Ce que ces tests surveillent a changé avec la pagination.** Le calcul des
/// agrégats est passé en SQL ; le risque n'est plus une addition fausse mais un
/// critère qui n'atteint pas la base — l'écran affiche « trié par valeur », le
/// dépôt reçoit « par nom », et rien ne le signale : la liste est plausible.
/// C'est le défaut déjà rencontré sur les filtres de decks, invisible à
/// `flutter analyze` comme à l'œil.
///
/// Second point de vigilance : le bandeau de totaux porte sur la collection
/// entière. Filtrer la liste ne doit pas le faire varier, sans quoi chercher une
/// carte donnerait l'impression d'en avoir perdu mille.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:deckhand/src/features/collection/presentation/collection_screen.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

CollectionEntry entry({
  String oracleId = 'oracle-1',
  String name = 'Lightning Bolt',
  String? printedName = 'Foudre',
  int quantity = 2,
  double? unitPrice = 1.12,
  String? printId,
  String? setCode,
  String? setName,
  String? collectorNumber,
}) => CollectionEntry(
  oracleId: oracleId,
  name: name,
  printedName: printedName,
  typeLine: 'Instant',
  quantity: quantity,
  unitPriceEur: unitPrice,
  linePriceEur: unitPrice == null ? null : unitPrice * quantity,
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  printId: printId,
  setCode: setCode,
  setName: setName,
  collectorNumber: collectorNumber,
);

CardPrinting printing({
  String printId = 'print-mh2',
  String setCode = 'mh2',
  String? setName = 'Modern Horizons 2',
  String? collectorNumber = '123',
  double? price = 3.40,
  int owned = 0,
}) => CardPrinting(
  printId: printId,
  setCode: setCode,
  setName: setName,
  collectorNumber: collectorNumber,
  lang: 'en',
  priceEur: price,
  owned: owned,
);

/// Dernier faux dépôt d'éditions posé, pour les tests qui ouvrent le sélecteur.
late FakePrintingRepository printings;

Future<FakeCollectionRepository> pumpCollection(
  WidgetTester tester, {
  List<CollectionEntry> entries = const [],
  CollectionSummary? totals,
  List<CardPrinting> availablePrintings = const [],
}) async {
  final repository = FakeCollectionRepository()
    ..entries = entries
    ..totals =
        totals ??
        (entries.isEmpty
            ? CollectionSummary.empty
            : CollectionSummary(
                totalCards: entries.fold(0, (sum, e) => sum + e.quantity),
                distinctCards: entries.length,
                totalValueEur: entries.fold(
                  0.0,
                  (sum, e) => sum + (e.linePriceEur ?? 0),
                ),
              ));

  printings = FakePrintingRepository()..printings = availablePrintings;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        collectionRepositoryProvider.overrideWithValue(repository),
        printingRepositoryProvider.overrideWithValue(printings),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: CollectionScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

/// Saisit une recherche et laisse passer l'anti-rebond.
Future<void> search(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('une collection vide invite à commencer', (tester) async {
    await pumpCollection(tester);
    expect(find.textContaining('collection est vide'), findsOneWidget);
  });

  testWidgets('les totaux affichés sont ceux de la collection entière', (
    tester,
  ) async {
    // La page ne porte qu'une carte, la collection en compte 54 : c'est le
    // serveur qui fait foi, pas ce qui est affiché.
    await pumpCollection(
      tester,
      entries: [entry()],
      totals: const CollectionSummary(
        totalCards: 54,
        distinctCards: 20,
        totalValueEur: 49.40,
      ),
    );

    expect(find.text('54 cartes'), findsOneWidget);
    expect(find.textContaining('20 références distinctes'), findsOneWidget);
    expect(find.text('49.40 €'), findsOneWidget);
  });

  testWidgets('le nom français prime, le nom oracle reste visible', (
    tester,
  ) async {
    await pumpCollection(tester, entries: [entry()]);

    expect(find.text('Foudre'), findsOneWidget);
    expect(find.text('Lightning Bolt'), findsOneWidget);
  });

  testWidgets(
    'le nom oracle n\'est pas répété quand il n\'y a pas de traduction',
    (tester) async {
      await pumpCollection(
        tester,
        entries: [entry(name: 'Sol Ring', printedName: null)],
      );

      expect(find.text('Sol Ring'), findsOneWidget);
    },
  );

  testWidgets('une carte sans cote s\'affiche sans prix inventé', (
    tester,
  ) async {
    await pumpCollection(
      tester,
      entries: [entry(quantity: 3, unitPrice: null)],
    );

    expect(find.text('Prix inconnu'), findsOneWidget);
  });

  testWidgets('ajouter un exemplaire passe par le dépôt', (tester) async {
    final repository = await pumpCollection(tester, entries: [entry()]);

    await tester.tap(find.byTooltip('Ajouter un exemplaire'));
    await tester.pumpAndSettle();

    expect(repository.quantities[('oracle-1', null)], 1);
  });

  testWidgets('retirer un exemplaire passe par le dépôt', (tester) async {
    final repository = await pumpCollection(tester, entries: [entry()]);
    await repository.add('oracle-1', quantity: 2);

    await tester.tap(find.byTooltip('Retirer un exemplaire'));
    await tester.pumpAndSettle();

    expect(repository.quantities[('oracle-1', null)], 1);
  });

  group('la consultation atteint le dépôt', () {
    testWidgets('la recherche est transmise, pas seulement affichée', (
      tester,
    ) async {
      final repository = await pumpCollection(tester, entries: [entry()]);

      await search(tester, 'foudre');

      expect(
        repository.lastQuery,
        'foudre',
        reason: 'filtrer côté écran seulement afficherait une liste non filtrée',
      );
    });

    testWidgets('le tri est transmis au dépôt', (tester) async {
      final repository = await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valeur').last);
      await tester.pumpAndSettle();

      expect(repository.lastSort, CollectionSort.price);
    });

    testWidgets('le tri choisi reste affiché', (tester) async {
      await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quantité').last);
      await tester.pumpAndSettle();

      expect(find.text('Quantité'), findsOneWidget);
    });

    testWidgets('une recherche sans résultat le dit', (tester) async {
      final repository = await pumpCollection(tester, entries: [entry()]);
      repository.entries = const [];

      await search(tester, 'zzzz');

      expect(find.textContaining('Aucune carte ne correspond'), findsOneWidget);
    });

    testWidgets('filtrer ne modifie pas les totaux de la collection', (
      tester,
    ) async {
      final repository = await pumpCollection(
        tester,
        entries: [entry()],
        totals: const CollectionSummary(
          totalCards: 54,
          distinctCards: 20,
          totalValueEur: 49.40,
        ),
      );
      repository.entries = const [];

      await search(tester, 'zzzz');

      expect(
        find.text('54 cartes'),
        findsOneWidget,
        reason:
            'le bandeau porte sur la collection entière : le voir tomber à zéro '
            'en cherchant donnerait l\'impression d\'avoir tout perdu',
      );
    });
  });

  group('les éditions', () {
    testWidgets('une édition connue est affichée sur la ligne', (tester) async {
      await pumpCollection(
        tester,
        entries: [
          entry(
            printId: 'print-mh2',
            setCode: 'mh2',
            setName: 'Modern Horizons 2',
            collectorNumber: '123',
          ),
        ],
      );

      expect(find.textContaining('Modern Horizons 2'), findsOneWidget);
      expect(find.textContaining('MH2 #123'), findsOneWidget);
    });

    testWidgets('une édition inconnue invite à la préciser', (tester) async {
      await pumpCollection(tester, entries: [entry()]);

      expect(find.text('Édition non précisée'), findsOneWidget);
    });

    testWidgets('choisir une édition la transmet au dépôt', (tester) async {
      final repository = await pumpCollection(
        tester,
        entries: [entry()],
        availablePrintings: [printing()],
      );

      await tester.tap(find.text('Édition non précisée'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Modern Horizons 2').last);
      await tester.pumpAndSettle();

      expect(
        repository.lastPrintingMove,
        (
          oracleId: 'oracle-1',
          from: null,
          to: 'print-mh2',
          quantity: null,
        ),
        reason: 'sans ce déplacement, le choix resterait affiché mais non enregistré',
      );
    });

    testWidgets('ajouter un exemplaire vise la bonne édition', (tester) async {
      final repository = await pumpCollection(
        tester,
        entries: [entry(printId: 'print-mh2', setCode: 'mh2')],
      );

      await tester.tap(find.byTooltip('Ajouter un exemplaire'));
      await tester.pumpAndSettle();

      expect(
        repository.quantities[('oracle-1', 'print-mh2')],
        1,
        reason: 'ajouter depuis une ligne d\'édition ne doit pas créer une '
            'ligne sans édition',
      );
    });

    testWidgets('les exemplaires sans édition sont signalés dans les totaux', (
      tester,
    ) async {
      await pumpCollection(
        tester,
        entries: [entry()],
        totals: const CollectionSummary(
          totalCards: 54,
          distinctCards: 20,
          totalValueEur: 49.40,
          unspecifiedPrints: 12,
        ),
      );

      expect(find.textContaining('12 sans édition'), findsOneWidget);
    });
  });
}
