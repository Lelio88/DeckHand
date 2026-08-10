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

  // **Un écran de test plus large que le défaut.** La barre de filtres défile
  // horizontalement : sur les 800 points du gabarit par défaut, les pastilles
  // de couleur tombent hors du viewport et un appui les manque en silence.
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deckRepositoryProvider.overrideWithValue(decks),
        collectionRepositoryProvider.overrideWithValue(collection),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: DeckSuggestionsScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return decks;
}

void main() {
  group('les deux façons de répondre', () {
    // Consulter le corpus et construire depuis sa collection répondent à la
    // même question par deux chemins : un sélecteur le dit, là où un bouton
    // glissé parmi les filtres laissait croire à un filtre de plus.
    testWidgets('le corpus est montré par défaut', (tester) async {
      await pumpDecksScreen(tester, results: [fakeDeck()]);

      expect(find.text('Préconstruits'), findsOneWidget);
      expect(find.text('Construire'), findsOneWidget);
      expect(find.text('Deck de test'), findsOneWidget);
    });

    testWidgets('basculer sur « Construire » change la vue', (tester) async {
      await pumpDecksScreen(tester, results: [fakeDeck()]);

      await tester.tap(find.text('Construire'));
      await tester.pumpAndSettle();

      expect(find.text('Deck de test'), findsNothing);
    });

    testWidgets('le format reste choisi en changeant de vue', (tester) async {
      // Le format se décide avant de savoir lequel des deux chemins on prend :
      // le perdre en basculant obligerait à le rechoisir chaque fois.
      final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);

      await tester.tap(find.text('Commander'));
      await tester.pumpAndSettle();
      expect(decks.lastFormat, DeckFormat.commander);

      await tester.tap(find.text('Construire'));
      await tester.pumpAndSettle();

      expect(find.text('Commander'), findsOneWidget);
    });
  });

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
      reason:
          'le filtre affiché doit atteindre la requête, '
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

  testWidgets('une couleur retenue tamise les suggestions', (tester) async {
    // Le tamis garde les decks qui *tiennent* dans la sélection : demander du
    // rouge et recevoir un deck à cinq couleurs n'aiderait pas qui voulait
    // justement du mono-rouge.
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);

    // Le tap vise l'`InkWell` de la pastille et non son `Tooltip` : ce
    // dernier enveloppe la zone sensible sans la porter, et un appui sur son
    // centre peut manquer l'InkWell.
    await tester.tap(
      find.descendant(
        of: find.byTooltip('Rouge'),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();

    expect(decks.lastFilters?.colors, {'R'});
  });

  group('le commandant', () {
    // Il identifie un deck bien mieux que sa provenance : on choisit son
    // général avant tout le reste, et deux listes au même nom de produit n'ont
    // rien à voir si leurs commandants diffèrent.
    testWidgets('remplace la provenance sur la ligne', (tester) async {
      await pumpDecksScreen(
        tester,
        results: [
          fakeDeck(
            tier: 'accessible',
            commanderOracleId: 'oracle-cmd',
            commanderName: 'Galadriel, reine elfe',
          ),
        ],
      );

      expect(find.text('Galadriel, reine elfe'), findsOneWidget);
      expect(find.text('Tout fait'), findsNothing);
      expect(find.text('TopDeck.gg'), findsNothing);
    });

    testWidgets('un deck sans commandant garde ses étiquettes', (tester) async {
      await pumpDecksScreen(tester, results: [fakeDeck()]);

      expect(find.text('Tournoi'), findsOneWidget);
    });

    testWidgets('le nom cherché atteint le dépôt', (tester) async {
      final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);

      await tester.tap(find.text('Commander'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Chercher un commandant'),
        'galadriel',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(decks.lastFilters?.commander, 'galadriel');
    });

    testWidgets("possédé, il se distingue à l'œil", (tester) async {
      // C'est la carte qui décide si un deck est un projet ou une liste de
      // courses : la distinction se lit avant le nom, pas après.
      await pumpDecksScreen(
        tester,
        results: [
          fakeDeck(
            commanderOracleId: 'oracle-cmd',
            commanderName: 'Galadriel, reine elfe',
            commanderOwned: true,
          ),
        ],
      );

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('le filtre « possédé » atteint le dépôt', (tester) async {
      final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);

      await tester.tap(find.text('Commander'));
      await tester.pumpAndSettle();
      // Le filtre a rejoint le champ de recherche du commandant : les deux
      // commandes portent sur la même chose.
      await tester.tap(find.text('Possédé'));
      await tester.pumpAndSettle();

      expect(decks.lastFilters?.ownedCommanderOnly, isTrue);
    });

    testWidgets("le filtre « possédé » ne paraît qu'en Commander", (
      tester,
    ) async {
      await pumpDecksScreen(tester, results: [fakeDeck()]);
      expect(find.text('Possédé'), findsNothing);
    });

    testWidgets("la recherche ne paraît qu'en Commander", (tester) async {
      // En Pauper, un champ de commandant ne pourrait rien trouver.
      await pumpDecksScreen(tester, results: [fakeDeck()]);
      expect(find.text('Chercher un commandant'), findsNothing);

      await tester.tap(find.text('Commander'));
      await tester.pumpAndSettle();
      expect(find.text('Chercher un commandant'), findsOneWidget);
    });
  });

  testWidgets('les terrains de base exclus sont annoncés', (tester) async {
    // Une liste de cent cartes présentée sur soixante-seize ferait douter du
    // chiffre si rien ne disait ce qu'il ignore.
    await pumpDecksScreen(
      tester,
      results: [fakeDeck(total: 76, owned: 1, basicLands: 24)],
    );

    expect(find.textContaining('hors 24 terrains de base'), findsOneWidget);
    expect(find.textContaining('sur 76'), findsOneWidget);
  });

  testWidgets("sans terrain de base, rien n'est annoncé", (tester) async {
    await pumpDecksScreen(tester, results: [fakeDeck()]);
    expect(find.textContaining('terrains de base'), findsNothing);
  });

  testWidgets("le détail sépare ce qui manque de ce qu'on a", (tester) async {
    // Sans cette frontière, la liste de courses se prolongeait de cartes qui
    // n'étaient pas à acheter, et un deck complet ouvrait sur une liste vide.
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);
    decks.missing = const [
      MissingCard(
        oracleId: 'a',
        name: 'Sol Ring',
        needed: 1,
        owned: 0,
        missing: 1,
        lineCostEur: 2.5,
      ),
      MissingCard(
        oracleId: 'b',
        name: 'Lightning Bolt',
        needed: 1,
        owned: 1,
        missing: 0,
      ),
    ];

    await tester.tap(find.text('Deck de test'));
    await tester.pumpAndSettle();

    expect(find.text('Déjà en collection · 1'), findsOneWidget);
    expect(find.text('Lightning Bolt'), findsOneWidget);
    expect(find.text('Sol Ring'), findsOneWidget);
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

    expect(
      find.textContaining('Aucun deck ne passe ces filtres'),
      findsOneWidget,
    );
  });
}
