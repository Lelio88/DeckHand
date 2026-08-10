/// Tests de l'écran de recherche, centrés sur le choix d'édition.
///
/// **Le risque est qu'un choix visible ne parte jamais.** Le sélecteur affiche
/// l'édition retenue, et si l'ajout ne la transmet pas, tout paraît normal : la
/// carte entre bien en collection, simplement sans son édition — et valorisée au
/// mauvais prix. Rien à l'écran ne le signale, `flutter analyze` non plus.
///
/// Second point : ne pas choisir doit rester praticable. Ajouter sans édition est
/// le geste rapide, celui qui rend la saisie de deux mille cartes supportable ; la
/// proposition de préciser vient après, sans jamais bloquer.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/card_search/data/card_repository.dart';
import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:deckhand/src/features/card_search/presentation/card_search_screen.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

CardHit hit({String oracleId = 'oracle-1', int owned = 0}) => CardHit(
  oracleId: oracleId,
  name: 'Lightning Bolt',
  matchedName: 'Foudre',
  matchedLang: 'fr',
  typeLine: 'Éphémère',
  priceEur: 1.12,
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  owned: owned,
);

CardPrinting printing({
  String printId = 'print-mh2',
  String setCode = 'mh2',
  String? setName = 'Modern Horizons 2',
  double? price = 3.40,
}) => CardPrinting(
  printId: printId,
  setCode: setCode,
  setName: setName,
  collectorNumber: '123',
  lang: 'en',
  priceEur: price,
);

late FakeCardRepository cards;
late FakeCollectionRepository collection;
late FakePrintingRepository printings;

Future<void> pumpSearch(
  WidgetTester tester, {
  List<CardHit> results = const [],
  List<CardPrinting> availablePrintings = const [],
}) async {
  cards = FakeCardRepository()..results = results;
  collection = FakeCollectionRepository();
  printings = FakePrintingRepository()..printings = availablePrintings;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        cardRepositoryProvider.overrideWithValue(cards),
        collectionRepositoryProvider.overrideWithValue(collection),
        printingRepositoryProvider.overrideWithValue(printings),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: CardSearchScreen())),
    ),
  );
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).first, 'foudre');
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sans choix, l\'ajout n\'impose aucune édition', (tester) async {
    await pumpSearch(tester, results: [hit()]);

    expect(find.text('Toutes éditions'), findsOneWidget);

    await tester.tap(find.byTooltip('Ajouter à ma collection'));
    await tester.pumpAndSettle();

    expect(
      collection.quantities[('oracle-1', null)],
      1,
      reason: 'préciser doit rester facultatif : la saisie rapide en dépend',
    );
  });

  testWidgets('l\'édition choisie est transmise à l\'ajout', (tester) async {
    await pumpSearch(
      tester,
      results: [hit()],
      availablePrintings: [printing()],
    );

    await tester.tap(find.text('Toutes éditions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modern Horizons 2').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Ajouter à ma collection'));
    await tester.pumpAndSettle();

    expect(
      collection.quantities[('oracle-1', 'print-mh2')],
      1,
      reason: 'sans cela l\'édition serait affichée mais jamais enregistrée, '
          'et la carte valorisée au mauvais prix',
    );
  });

  testWidgets('l\'édition retenue reste affichée après le choix', (
    tester,
  ) async {
    await pumpSearch(
      tester,
      results: [hit()],
      availablePrintings: [printing()],
    );

    await tester.tap(find.text('Toutes éditions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modern Horizons 2').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('MH2 #123'), findsOneWidget);
    expect(find.text('Toutes éditions'), findsNothing);
  });

  testWidgets('le sélecteur se cherche par nom d\'extension', (tester) async {
    await pumpSearch(
      tester,
      results: [hit()],
      availablePrintings: [
        printing(),
        printing(
          printId: 'print-lea',
          setCode: 'lea',
          setName: 'Limited Edition Alpha',
          price: 400,
        ),
      ],
    );

    await tester.tap(find.text('Toutes éditions'));
    await tester.pumpAndSettle();
    expect(find.text('Limited Edition Alpha'), findsOneWidget);

    // Le champ du sélecteur est le second : le premier est celui de la recherche
    // de cartes, resté monté derrière la feuille modale.
    await tester.enterText(find.byType(TextField).last, 'alpha');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      printings.lastQuery,
      'alpha',
      reason: 'certaines cartes ont plus de mille éditions : filtrer côté écran '
          'ne suffirait pas, le serveur n\'en envoie qu\'une partie',
    );
    expect(find.text('Modern Horizons 2'), findsNothing);
  });

  testWidgets('la possession déjà connue est visible', (tester) async {
    await pumpSearch(tester, results: [hit(owned: 3)]);

    expect(find.text('Déjà 3'), findsOneWidget);
  });

  testWidgets('la notification d\'ajout s\'efface d\'elle-même', (tester) async {
    await pumpSearch(tester, results: [hit()]);

    await tester.tap(find.byTooltip('Ajouter à ma collection'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(
      find.byType(SnackBar),
      findsNothing,
      reason:
          'porteuse d\'une action, la notification attendrait sinon un '
          'balayage et recouvrirait les commandes de l\'écran suivant',
    );
  });
}
