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
import 'package:deckhand/src/features/decks/presentation/color_wheel.dart';
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

/// Choisit une entrée du menu de budget.
///
/// Un seul contrôle porte désormais « jusqu'où suis-je prêt à aller » : la puce
/// « Constructibles » et le plafond y ont fondu.
Future<void> chooseBudget(WidgetTester tester, String entry) async {
  await tester.tap(find.text('Budget'));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining(entry).last);
  await tester.pumpAndSettle();
}

void main() {
  group('les deux façons de répondre', () {
    // Le choix entre consulter le corpus et construire depuis sa collection
    // vit désormais dans la barre du haut, hors de cet écran : ces tests le
    // pilotent donc par son état, et non par un geste.
    Future<void> switchToBuilding(WidgetTester tester) async {
      final element = tester.element(find.byType(DeckSuggestionsScreen));
      ProviderScope.containerOf(element)
          .read(deckModeProvider.notifier)
          .select(DeckMode.building);
      await tester.pumpAndSettle();
    }

    // Consulter le corpus et construire depuis sa collection répondent à la
    // même question par deux chemins : un sélecteur le dit, là où un bouton
    // glissé parmi les filtres laissait croire à un filtre de plus.
    testWidgets('le corpus est montré par défaut', (tester) async {
      await pumpDecksScreen(tester, results: [fakeDeck()]);

      expect(find.text('Deck de test'), findsOneWidget);
    });

    testWidgets('basculer sur « Construire » change la vue', (tester) async {
      await pumpDecksScreen(tester, results: [fakeDeck()]);

      await switchToBuilding(tester);
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

      await switchToBuilding(tester);
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

  testWidgets('le budget choisi atteint la requête', (tester) async {
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);
    expect(decks.lastFilters?.budget, DeckBudget.any);

    await chooseBudget(tester, 'Moins de 10 €');

    expect(
      decks.lastFilters?.budget.maxCostEur,
      10,
      reason:
          'le filtre affiché doit atteindre la requête, '
          "faute de quoi la liste contredit l'interface",
    );
  });

  testWidgets("« rien à acheter » n'autorise aucune carte manquante", (
    tester,
  ) async {
    // « Constructible » n'est pas « zéro euro » : une carte manquante sans cote
    // coûte zéro et manque quand même. Le premier exige qu'il ne manque rien,
    // les autres plafonnent une dépense — d'où une entrée à part, en tête du
    // même menu plutôt qu'une puce séparée qui pouvait le contredire.
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);

    await chooseBudget(tester, 'rien à acheter');

    expect(decks.lastFilters?.budget.maxMissing, 0);
    expect(decks.lastFilters?.budget.maxCostEur, isNull);
  });


  testWidgets('les couleurs choisies atteignent le serveur', (tester) async {
    // Le tamis vit côté serveur : le sens exact du filtre — couleurs voulues,
    // couleurs bannies — est éprouvé sur la roue elle-même. Ce qui compte ici
    // est qu'il parvienne au dépôt.
    final decks = await pumpDecksScreen(tester, results: [fakeDeck()]);

    await tester.tap(find.byType(ColorWheelButton));
    await tester.pumpAndSettle();
    // La pastille se désigne par sa sémantique : la lettre a cédé la place au
    // symbole de mana imprimé, et une image ne se trouve pas par son texte.
    await tester.tap(find.bySemanticsLabel(RegExp('^Rouge —')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appliquer'));
    await tester.pumpAndSettle();

    expect(decks.lastFilters?.colors, {'R'});
    expect(decks.lastFilters?.bannedColors, isEmpty);
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

    testWidgets('aucune tuile ne porte sa provenance, commandant ou non', (
      tester,
    ) async {
      // Mesuré sur les 1 028 decks du corpus, la provenance est parfaitement
      // corrélée au format : 190 Commander de MTGJSON, 838 Pauper et Modern de
      // TopDeck.gg. Les deux mêmes étiquettes se répétaient donc sur les 838
      // tuiles d'une liste sans rien y distinguer — et le crédit contractuel,
      // lui, vit dans le bandeau d'attribution.
      await pumpDecksScreen(tester, results: [fakeDeck()]);

      expect(find.text('Tournoi'), findsNothing);
      expect(find.text('Tout fait'), findsNothing);
      expect(
        find.text('TopDeck.gg'),
        findsNothing,
        reason: 'la pastille disparaît ; le bandeau porte le crédit en toutes '
            'lettres',
      );
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

    await chooseBudget(tester, 'rien à acheter');
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

    // **Le texte entier, et non le seul nom de la source.** Les tuiles ne
    // portent plus de pastille « TopDeck.gg » : si ce test se contentait de
    // trouver ce nom quelque part, il aurait continué de passer alors même que
    // le crédit contractuel avait disparu de l'écran.
    expect(
      find.text('Données de tournoi fournies par TopDeck.gg'),
      findsOneWidget,
      reason: 'le crédit est une obligation contractuelle envers la source',
    );
  });

  testWidgets('une liste vide distingue le filtrage de l\'absence de deck', (
    tester,
  ) async {
    await pumpDecksScreen(tester);
    expect(find.textContaining('Aucun deck dans ce format'), findsOneWidget);

    await chooseBudget(tester, 'rien à acheter');

    expect(
      find.textContaining('Aucun deck ne passe ces filtres'),
      findsOneWidget,
    );
  });
}
