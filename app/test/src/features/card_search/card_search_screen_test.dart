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
import 'package:deckhand/src/features/printings/presentation/card_art_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

CardHit hit({
  String oracleId = 'oracle-1',
  int owned = 0,
  String? artUrl = 'https://exemple/reference.jpg',
}) => CardHit(
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
  artUrl: artUrl,
);

CardPrinting printing({
  String printId = 'print-mh2',
  String setCode = 'mh2',
  String? setName = 'Modern Horizons 2',
  double? price = 3.40,
  String? artCropUrl = 'https://exemple/mh2.jpg',
}) => CardPrinting(
  printId: printId,
  setCode: setCode,
  setName: setName,
  collectorNumber: '123',
  lang: 'en',
  priceEur: price,
  artCropUrl: artCropUrl,
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

  testWidgets('choisir une édition ajoute la carte sans autre geste', (
    tester,
  ) async {
    // Désigner une édition, c'est avoir la carte en main : exiger ensuite un
    // appui sur « + » ajoutait un geste après la décision, et sur deux mille
    // cartes ce geste se paie deux mille fois.
    await pumpSearch(
      tester,
      results: [hit()],
      availablePrintings: [printing()],
    );

    await tester.tap(find.text('Toutes éditions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modern Horizons 2').last);
    await tester.pumpAndSettle();

    expect(
      collection.quantities[('oracle-1', 'print-mh2')],
      1,
      reason: 'sans cela l\'édition serait affichée mais jamais enregistrée, '
          'et la carte valorisée au mauvais prix',
    );
  });

  testWidgets('« ne pas préciser » n\'ajoute rien', (tester) async {
    // C'est un réglage qu'on annule, pas une carte qu'on tient. Ajouter ici
    // ferait entrer un exemplaire fantôme à chaque fois qu'on se ravise.
    await pumpSearch(
      tester,
      results: [hit()],
      availablePrintings: [printing()],
    );

    await tester.tap(find.text('Toutes éditions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modern Horizons 2').last);
    await tester.pumpAndSettle();
    expect(collection.quantities.values.single, 1);

    // « MH2 #123 » désigne le sélecteur de la ligne ; la notification d'ajout
    // affiche « MH2 » elle aussi, sans le numéro.
    await tester.tap(find.textContaining('MH2 #123'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ne pas préciser l\'édition'));
    await tester.pumpAndSettle();

    expect(
      collection.quantities.values.fold<int>(0, (sum, q) => sum + q),
      1,
      reason: 'se raviser sur l\'édition ne doit pas ajouter d\'exemplaire',
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

  group("la ligne décrit l'édition retenue", () {
    // **L'illustration est ce qui permet de vérifier son choix.** Une édition
    // désignée mais illustrée par une autre laisse croire à une erreur de
    // sélection là où il n'y en a pas — et masque les vraies. Le prix a le même
    // devoir : le plancher affiché à côté d'une édition qui vaut six fois plus
    // faisait douter du sélecteur lui-même.

    Future<void> chooseMh2(WidgetTester tester) async {
      await tester.tap(find.text('Toutes éditions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Modern Horizons 2').last);
      await tester.pumpAndSettle();
    }

    String? shownArt(WidgetTester tester) => tester
        .widget<CardArtThumbnail>(find.byType(CardArtThumbnail).first)
        .url;

    testWidgets("l'illustration suit l'édition choisie", (tester) async {
      await pumpSearch(
        tester,
        results: [hit()],
        availablePrintings: [printing()],
      );

      expect(shownArt(tester), 'https://exemple/reference.jpg');
      await chooseMh2(tester);
      expect(shownArt(tester), 'https://exemple/mh2.jpg');
    });

    testWidgets("le prix suit l'édition choisie", (tester) async {
      await pumpSearch(
        tester,
        results: [hit()],
        availablePrintings: [printing()],
      );

      expect(find.text('1.12 €'), findsOneWidget);
      await chooseMh2(tester);
      expect(find.text('3.40 €'), findsOneWidget);
      expect(find.text('1.12 €'), findsNothing);
    });

    testWidgets('une édition sans illustration garde celle de référence', (
      tester,
    ) async {
      await pumpSearch(
        tester,
        results: [hit()],
        availablePrintings: [printing(artCropUrl: null)],
      );

      await chooseMh2(tester);
      expect(
        shownArt(tester),
        'https://exemple/reference.jpg',
        reason: 'un cadre vide se lirait comme une panne, alors que rien '
            "n'a échoué",
      );
    });

    testWidgets('une édition sans cote retombe sur le prix plancher', (
      tester,
    ) async {
      await pumpSearch(
        tester,
        results: [hit()],
        availablePrintings: [printing(price: null)],
      );

      await chooseMh2(tester);
      expect(
        find.text('1.12 €'),
        findsOneWidget,
        reason: "c'est ce que la collection comptera pour elle : le prix de "
            "l'édition, ou le moins cher connu à défaut",
      );
    });
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

  testWidgets('les types retenus atteignent le catalogue', (tester) async {
    // **Le filtrage vit côté serveur.** Restreindre après coup ne garderait que
    // les créatures des vingt premiers résultats, soit souvent aucune : ce qui
    // se vérifie ici est donc que le geste traverse l'écran jusqu'à la requête.
    await pumpSearch(tester, results: [hit()]);
    await tester.enterText(find.byType(TextField), 'agent');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(cards.lastTypes, isEmpty);

    await tester.tap(find.byType(TypeFilter));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Créature'),
    );
    await tester.pumpAndSettle();

    expect(cards.lastTypes, ['Creature']);
  });
}
