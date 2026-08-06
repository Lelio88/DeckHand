/// Tests de l'écran de collection.
///
/// Les agrégats affichés — nombre de cartes, références distinctes, valeur
/// totale — sont ce sur quoi l'utilisateur juge sa collection. Une erreur de
/// calcul y est invisible : le chiffre paraît toujours plausible.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:deckhand/src/features/collection/presentation/collection_screen.dart';
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
);

Future<FakeCollectionRepository> pumpCollection(
  WidgetTester tester, {
  List<CollectionEntry> entries = const [],
}) async {
  final repository = FakeCollectionRepository()
    ..summary = CollectionSummary(entries: entries);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        collectionRepositoryProvider.overrideWithValue(repository),
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

void main() {
  testWidgets('une collection vide invite à commencer', (tester) async {
    await pumpCollection(tester);
    expect(find.textContaining('collection est vide'), findsOneWidget);
  });

  testWidgets('les exemplaires comptent, pas seulement les références', (
    tester,
  ) async {
    await pumpCollection(
      tester,
      entries: [
        entry(oracleId: 'a', quantity: 4),
        entry(oracleId: 'b', name: 'Sol Ring', printedName: null, quantity: 1),
      ],
    );

    expect(find.text('5 cartes'), findsOneWidget);
    expect(find.textContaining('2 références distinctes'), findsOneWidget);
  });

  testWidgets('la valeur totale additionne les lignes', (tester) async {
    await pumpCollection(
      tester,
      entries: [
        entry(oracleId: 'a', quantity: 2, unitPrice: 1.12), // 2.24
        entry(oracleId: 'b', quantity: 1, unitPrice: 0.79), // 0.79
      ],
    );

    expect(find.text('3.03 €'), findsOneWidget);
  });

  testWidgets('une carte sans cote ne fausse pas le total', (tester) async {
    // Deux cartes cotées, pour que le total diffère de chaque ligne prise
    // isolément — sans quoi l'assertion ne distinguerait pas les deux.
    await pumpCollection(
      tester,
      entries: [
        entry(oracleId: 'a', quantity: 1, unitPrice: 2.00),
        entry(oracleId: 'b', quantity: 1, unitPrice: 0.50),
        entry(oracleId: 'c', quantity: 3, unitPrice: null),
      ],
    );

    expect(
      find.text('2.50 €'),
      findsOneWidget,
      reason:
          'les cartes sans cote comptent pour zéro : '
          'mieux vaut sous-estimer que d\'inventer un prix',
    );
    expect(find.text('Prix inconnu'), findsOneWidget);
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

  testWidgets('ajouter un exemplaire passe par le dépôt', (tester) async {
    final repository = await pumpCollection(tester, entries: [entry()]);

    await tester.tap(find.byTooltip('Ajouter un exemplaire'));
    await tester.pumpAndSettle();

    expect(repository.quantities['oracle-1'], 1);
  });

  testWidgets('retirer un exemplaire passe par le dépôt', (tester) async {
    final repository = await pumpCollection(tester, entries: [entry()]);
    await repository.add('oracle-1', quantity: 2);

    await tester.tap(find.byTooltip('Retirer un exemplaire'));
    await tester.pumpAndSettle();

    expect(repository.quantities['oracle-1'], 1);
  });
}
