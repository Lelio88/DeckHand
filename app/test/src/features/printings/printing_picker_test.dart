/// Tests du sélecteur d'éditions, côté « extension lue sur la carte ».
///
/// **Ce que ces tests protègent.** Une carte rééditée quarante fois ouvre un
/// sélecteur de quarante lignes ; c'est précisément ce qui fait renoncer à
/// préciser l'édition, et donc ce qui laisse les classeurs vides. Remonter en
/// tête l'extension lue sur la photo est la seule chose qui rende le geste
/// tenable — mais un réordonnancement silencieux serait pire que rien : quand
/// la lecture se trompe, l'utilisateur doit voir pourquoi les mauvaises
/// éditions sont en haut.
///
/// **Le code lu tranche quand il ne laisse qu'une case, et seulement là.** Une
/// carte existe en moyenne dans plusieurs éditions d'une même extension —
/// versions étendues, promotionnelles — et le code seul ne dit alors pas
/// laquelle : l'utilisateur choisit. Quand il n'en reste qu'une, la lui faire
/// désigner revient à faire ouvrir une liste d'un seul élément, et c'est ce qui
/// laissait les cartes « à trier ».
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
  SetCodeReader? readSetCode,
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
                readSetCode: readSetCode,
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

/// Ouvre le sélecteur et rend ce qu'il a choisi — `null` s'il reste ouvert.
///
/// Distinct de [pumpPicker], qui lit l'ordre affiché : quand le code lu tranche
/// seul, il n'y a plus rien à afficher, et c'est le choix rendu qu'on observe.
Future<PrintingChoice?> pumpPickerForChoice(
  WidgetTester tester, {
  required List<CardPrinting> printings,
  SetCodeReader? readSetCode,
  String? currentPrintId,
}) async {
  final repository = FakePrintingRepository()..printings = printings;
  PrintingChoice? chosen;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [printingRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                chosen = await showPrintingPicker(
                  context,
                  oracleId: 'oracle-1',
                  cardName: 'Agent Phil Coulson',
                  currentPrintId: currentPrintId,
                  readSetCode: readSetCode,
                );
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
  return chosen;
}

void main() {
  // **Deux éditions dans `msh`** — la carte et sa version étendue, cas courant
  // des sorties récentes. Le code lu ne tranche donc pas, et le sélecteur reste
  // ouvert : c'est ce catalogue qui permet d'observer l'ordre et le bandeau.
  final catalogue = [
    printing('mkm', '12', setName: "Meurtres au manoir Karlov"),
    printing('msh', '412', setName: 'Marvel Super Heroes'),
    printing('msh', '598', setName: 'Marvel Super Heroes'),
    printing('lci', '77', setName: "Les caveaux perdus d'Ixalan"),
  ];

  /// Le même catalogue, où l'extension lue ne compte qu'une seule case.
  final soleInSet = [
    printing('mkm', '12', setName: "Meurtres au manoir Karlov"),
    printing('msh', '412', setName: 'Marvel Super Heroes'),
    printing('lci', '77', setName: "Les caveaux perdus d'Ixalan"),
  ];

  testWidgets('sans lecture, l\'ordre du catalogue est conservé', (
    tester,
  ) async {
    final order = await pumpPicker(tester, printings: catalogue);

    expect(order, ['MKM', 'MSH', 'MSH', 'LCI']);
    expect(find.textContaining('lue sur la carte'), findsNothing);
  });

  testWidgets('l\'extension lue remonte en tête', (tester) async {
    final order = await pumpPicker(
      tester,
      printings: catalogue,
      readSetCode: (codes) => codes.contains('msh') ? 'msh' : null,
    );

    expect(
      order.first,
      'MSH',
      reason:
          'chercher son extension parmi quarante lignes est ce qui fait '
          'renoncer à préciser l\'édition',
    );
  });

  testWidgets('ce qui a été lu est annoncé, pas seulement appliqué', (
    tester,
  ) async {
    await pumpPicker(
      tester,
      printings: catalogue,
      readSetCode: (codes) => 'msh',
    );

    expect(
      find.textContaining('Extension lue sur la carte : MSH'),
      findsOneWidget,
    );
  });

  testWidgets('la fonction reçoit les extensions réellement proposées', (
    tester,
  ) async {
    Set<String>? seen;
    await pumpPicker(
      tester,
      printings: catalogue,
      readSetCode: (codes) {
        seen = codes;
        return null;
      },
    );

    expect(
      seen,
      {'mkm', 'msh', 'lci'},
      reason:
          'chercher un code hors des extensions de la carte reviendrait à '
          'accepter qu\'un nom d\'illustrateur en désigne une',
    );
  });

  testWidgets('une lecture infructueuse ne change rien', (tester) async {
    final order = await pumpPicker(
      tester,
      printings: catalogue,
      readSetCode: (codes) => null,
    );

    expect(order, ['MKM', 'MSH', 'MSH', 'LCI']);
    expect(find.textContaining('lue sur la carte'), findsNothing);
  });

  testWidgets(
    'plusieurs cases dans l\'extension lue : l\'utilisateur choisit',
    (tester) async {
      // Le code désigne une extension, pas une case. Tant qu'il en reste
      // plusieurs — la carte et sa version étendue —, trancher à la place de
      // l'utilisateur rangerait une carte sur deux dans la mauvaise.
      await pumpPicker(
        tester,
        printings: catalogue,
        readSetCode: (codes) => 'msh',
      );

      expect(find.byType(ListTile), findsWidgets);
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
      expect(tiles.where((t) => t.selected), isEmpty);
    },
  );

  testWidgets('une seule case dans l\'extension lue : elle est retenue', (
    tester,
  ) async {
    // Ce qui laissait les cartes « à trier » : faire désigner l'unique
    // candidat, vingt fois de suite, sur des cartes rééditées treize fois.
    final chosen = await pumpPickerForChoice(
      tester,
      printings: soleInSet,
      readSetCode: (codes) => 'msh',
    );

    expect(chosen?.printing.setCode, 'msh');
    expect(chosen?.printing.collectorNumber, '412');
    expect(
      find.byType(ListTile),
      findsNothing,
      reason: 'la feuille se referme : il n\'y avait rien à choisir',
    );
  });

  testWidgets('corriger une édition laisse toujours choisir', (tester) async {
    // Rouvrir le sélecteur sur une carte déjà précisée sert à changer d'avis :
    // le refermer d'office rendrait la correction impossible.
    final chosen = await pumpPickerForChoice(
      tester,
      printings: soleInSet,
      readSetCode: (codes) => 'msh',
      currentPrintId: 'lci-77',
    );

    expect(chosen, isNull);
    expect(find.byType(ListTile), findsWidgets);
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
