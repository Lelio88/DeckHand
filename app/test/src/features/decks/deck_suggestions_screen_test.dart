/// Tests de l'écran des decks.
///
/// **Pourquoi ces tests existent.** Un changement de filtre n'était pas transmis
/// au dépôt : l'interface affichait fidèlement « ≤ 10 € » pendant que la liste
/// montrait des decks à 18 €. `flutter analyze` était propre et les 46 tests
/// passaient — le défaut vivait dans le câblage entre l'état et la requête,
/// exactement l'endroit qu'aucun test unitaire ne couvrait.
///
/// Les assertions portent donc sur **ce que le dépôt a reçu**, pas sur ce que
/// l'écran affiche : c'est le maillon qui avait cédé.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/decks/data/deck_repository.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:deckhand/src/features/decks/presentation/deck_suggestions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

/// Monte l'écran avec des doublures, et rend le dépôt pour inspection.
Future<FakeDeckRepository> pumpDecksScreen(
  WidgetTester tester, {
  List<DeckSuggestion> results = const [],
}) async {
  final decks = FakeDeckRepository()..results = results;
  final collection = FakeCollectionRepository();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deckRepositoryProvider.overrideWithValue(decks),
        collectionRepositoryProvider.overrideWithValue(collection),
        sessionProvider.overrideWith((ref) => Stream<Session?>.value(fakeSession())),
      ],
      child: const MaterialApp(home: Scaffold(body: DeckSuggestionsScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return decks;
}

void main() {
  testWidgets('le format sélectionné est transmis au dépôt', (tester) async {
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);
    expect(decks.lastFormat, DeckFormat.pauper);

    await tester.tap(find.text('Commander'));
    await tester.pumpAndSettle();

    expect(decks.lastFormat, DeckFormat.commander);
  });

  testWidgets('le plafond de budget atteint bien la requête', (tester) async {
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);
    expect(decks.lastFilters?.maxCostEur, isNull);

    await tester.tap(find.text('Tous budgets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('≤ 10 €').last);
    await tester.pumpAndSettle();

    expect(
      decks.lastFilters?.maxCostEur,
      10,
      reason: 'le filtre affiché doit atteindre la requête, '
          'faute de quoi la liste contredit l\'interface',
    );
  });

  testWidgets('« Constructibles » n\'autorise aucune carte manquante', (
    tester,
  ) async {
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);
    expect(decks.lastFilters?.buildableOnly, isFalse);

    await tester.tap(find.text('Constructibles'));
    await tester.pumpAndSettle();

    expect(decks.lastFilters?.buildableOnly, isTrue);
  });

  testWidgets('« Accessibles » restreint aux précons', (tester) async {
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);

    await tester.tap(find.text('Accessibles'));
    await tester.pumpAndSettle();

    expect(decks.lastFilters?.accessibleOnly, isTrue);
  });

  testWidgets('remettre à zéro efface tous les filtres', (tester) async {
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);

    await tester.tap(find.text('Constructibles'));
    await tester.pumpAndSettle();
    expect(find.text('Tout afficher'), findsOneWidget);

    await tester.tap(find.text('Tout afficher'));
    await tester.pumpAndSettle();

    expect(decks.lastFilters?.isActive, isFalse);
    expect(find.text('Tout afficher'), findsNothing);
  });

  testWidgets('un deck affiche sa complétion, son manque et son coût', (
    tester,
  ) async {
    await pumpDecksScreen(
      tester,
      results: [fakeDeck(name: 'Mon deck', total: 60, owned: 51, cost: 7.59)],
    );

    expect(find.text('Mon deck'), findsOneWidget);
    expect(find.text('85 %'), findsOneWidget);
    expect(find.textContaining('Il manque 9 cartes'), findsOneWidget);
    expect(find.text('7.59 €'), findsOneWidget);
  });

  testWidgets('un deck complet est annoncé comme constructible', (
    tester,
  ) async {
    await pumpDecksScreen(
      tester,
      results: [fakeDeck(total: 60, owned: 60, cost: 0)],
    );

    expect(find.textContaining('Constructible dès maintenant'), findsOneWidget);
  });

  testWidgets('l\'attribution de la source reste affichée', (tester) async {
    await pumpDecksScreen(tester, results: [fakeDeck()]);

    expect(
      find.textContaining('TopDeck.gg'),
      findsWidgets,
      reason: 'le crédit est une obligation contractuelle envers la source',
    );
  });

  testWidgets('une liste vide distingue le filtrage de l\'absence de deck', (
    tester,
  ) async {
    await pumpDecksScreen(tester);
    expect(find.textContaining('Aucun deck dans ce format'), findsOneWidget);

    await tester.tap(find.text('Constructibles'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Aucun deck ne passe ces filtres'), findsOneWidget);
  });
}
