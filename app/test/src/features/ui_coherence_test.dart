/// Ce qui doit se comporter pareil d'un écran à l'autre.
///
/// **Pourquoi ces tests existent, et pourquoi ils sont réunis ici.** Chaque
/// écran a été écrit à son tour, et chacun a inventé sa réponse à des questions
/// que les précédents avaient déjà tranchées : quel geste montre une carte,
/// comment on referme l'aperçu, ce qu'on affiche quand le prix est inconnu. Les
/// divergences n'étaient pas des choix — elles tenaient à l'ordre d'écriture.
/// Un test par écran ne les aurait jamais vues : elles ne sont visibles qu'en
/// comparant les écrans entre eux, et c'est ce que fait ce fichier.
///
/// La règle du geste, qui commande la moitié du fichier :
///
/// > **Toucher agit, maintenir montre.** Un appui simple exécute l'action
/// > propre à la surface — ajouter, choisir, ouvrir. L'appui long, lui, ouvre
/// > toujours la même chose : la carte en grand. Aucune exception.
///
/// L'exception qui a motivé le chantier vivait dans `deck_suggestions_screen`,
/// où la ligne du général agrandissait à l'appui **simple** — le seul du dépôt,
/// et le seul à porter un pictogramme, si bien que c'était la surface aberrante
/// qui enseignait la règle.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/card_search/data/card_repository.dart';
import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/decks/data/deck_repository.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:deckhand/src/features/decks/presentation/deck_suggestions_screen.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/card_search/presentation/card_search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../helpers/fakes.dart';

CardHit fakeHit() => const CardHit(
  oracleId: 'oracle-1',
  name: 'Agent of Atlas',
  matchedName: 'Agent d\'Atlas',
  matchedLang: 'fr',
  typeLine: 'Créature',
  priceEur: 1.12,
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  owned: 0,
  artUrl: 'https://exemple/reference.jpg',
);

/// Monte un écran avec les doublures partagées par tous les écrans de cartes.
Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  FakeDeckRepository? decks,
  FakeCardRepository? cards,
  FakePrintingRepository? printings,
  FakeCollectionRepository? collection,
}) async {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deckRepositoryProvider.overrideWithValue(decks ?? FakeDeckRepository()),
        cardRepositoryProvider.overrideWithValue(cards ?? FakeCardRepository()),
        printingRepositoryProvider.overrideWithValue(
          printings ?? FakePrintingRepository(),
        ),
        collectionRepositoryProvider.overrideWithValue(
          collection ?? FakeCollectionRepository(),
        ),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: screen)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('toucher agit, maintenir montre', () {
    testWidgets('la tuile de deck ouvre sa liste au toucher et montre son '
        'général au maintien', (tester) async {
      // C'était l'incohérence d'origine : la ligne du général captait le
      // toucher pour agrandir la carte, seule surface du dépôt à le faire.
      // Toucher devait donc ouvrir la liste des cartes manquantes — sauf sur
      // cette ligne-là, au milieu de la tuile.
      final decks = FakeDeckRepository()
        ..results = [
          fakeDeck(
            commanderOracleId: 'oracle-general',
            commanderName: 'Galadriel',
          ),
        ];

      await pumpScreen(tester, const DeckSuggestionsScreen(), decks: decks);
      await tester.tap(find.text('Commander'));
      await tester.pumpAndSettle();

      // Toucher le nom du général ouvre la feuille du deck, comme toucher
      // n'importe quel autre point de la tuile.
      await tester.tap(find.text('Galadriel'));
      await tester.pumpAndSettle();

      expect(
        find.byType(BottomSheet),
        findsOneWidget,
        reason:
            'toucher agit : la tuile ouvre sa liste de cartes manquantes, '
            'y compris sur la ligne du général',
      );
    });

    testWidgets('aucun pictogramme n\'annonce plus un geste que les autres '
        'surfaces ne partagent pas', (tester) async {
      // L'icône d'image ne figurait que sur la ligne du général, pour annoncer
      // un appui simple que huit autres surfaces ne connaissaient pas. Elle
      // enseignait donc une règle fausse — et son glyphe sert par ailleurs à
      // « Importer » dans l'écran de visée.
      final decks = FakeDeckRepository()
        ..results = [
          fakeDeck(
            commanderOracleId: 'oracle-general',
            commanderName: 'Galadriel',
          ),
        ];

      await pumpScreen(tester, const DeckSuggestionsScreen(), decks: decks);
      await tester.tap(find.text('Commander'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.image_outlined), findsNothing);
    });

    testWidgets('maintenir une carte de la recherche ouvre son aperçu', (
      tester,
    ) async {
      // L'onglet Ajouter est l'écran d'entrée et le point où l'on décide
      // d'écrire une carte en collection : il n'offrait aucun chemin vers la
      // carte en grand, alors qu'il affiche une vignette de 56 × 42 qui
      // ressemble à toutes les vignettes touchables du reste de l'app.
      final cards = FakeCardRepository()..results = [fakeHit()];

      await pumpScreen(tester, const CardSearchScreen(), cards: cards);
      await tester.enterText(find.byType(TextField).last, 'agent');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Agent d\'Atlas'));
      await tester.pumpAndSettle();

      expect(
        find.byType(Dialog),
        findsOneWidget,
        reason:
            'maintenir montre : le geste est le même que dans le classeur, '
            'le sélecteur d\'édition, les scans et les decks',
      );
    });

    testWidgets('l\'aperçu se referme en tapant la carte', (tester) async {
      // Le classeur enseignait « je tape, ça se referme » ; le même réflexe
      // laissait le dialogue ouvert partout ailleurs, où il fallait viser une
      // marge de douze pixels autour d'une image qui remplit l'écran.
      final cards = FakeCardRepository()..results = [fakeHit()];

      await pumpScreen(tester, const CardSearchScreen(), cards: cards);
      await tester.enterText(find.byType(TextField).last, 'agent');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Agent d\'Atlas'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);

      await tester.tap(find.byType(Dialog));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
    });
  });

  group('un prix inconnu se dit toujours de la même façon', () {
    testWidgets('une carte manquante sans cote s\'écrit « — » et non 0,00 €', (
      tester,
    ) async {
      // Dans le seul écran où l'on décide d'un achat, « 0.00 € » se lit
      // « gratuite ». Le tiret dit « je ne sais pas », comme sur les quatre
      // autres écrans — dont le sélecteur d'édition qu'on vient de quitter.
      final decks = FakeDeckRepository()
        ..results = [fakeDeck()]
        ..missing = const [
          MissingCard(
            oracleId: 'oracle-sans-cote',
            name: 'Carte sans cote',
            needed: 2,
            owned: 0,
            missing: 2,
          ),
        ];

      await pumpScreen(tester, const DeckSuggestionsScreen(), decks: decks);
      await tester.tap(find.text('Deck de test'));
      await tester.pumpAndSettle();

      expect(find.text('—'), findsOneWidget);
      expect(
        find.text('0.00 €'),
        findsNothing,
        reason: 'zéro euro veut dire gratuit, pas « prix inconnu »',
      );
    });

    testWidgets('une carte cotée affiche bien son coût de ligne', (
      tester,
    ) async {
      // Le garde-fou du test précédent : le test doit porter sur le prix
      // unitaire et non sur `line_cost_eur`, coalescé côté SQL et donc jamais
      // nul — un correctif écrit sur lui compilerait sans rien changer.
      final decks = FakeDeckRepository()
        ..results = [fakeDeck()]
        ..missing = const [
          MissingCard(
            oracleId: 'oracle-cote',
            name: 'Carte cotée',
            needed: 2,
            owned: 0,
            missing: 2,
            unitPriceEur: 1.25,
            lineCostEur: 2.5,
          ),
        ];

      await pumpScreen(tester, const DeckSuggestionsScreen(), decks: decks);
      await tester.tap(find.text('Deck de test'));
      await tester.pumpAndSettle();

      expect(find.text('2.50 €'), findsOneWidget);
    });
  });
}
