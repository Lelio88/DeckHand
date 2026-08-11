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
import 'package:deckhand/src/features/printings/presentation/printing_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

CardPrinting printing(String setCode, String number, {String? setName}) =>
    CardPrinting(
      printId: '$setCode-$number',
      setCode: setCode,
      setName: setName ?? setCode.toUpperCase(),
      collectorNumber: number,
      lang: 'fr',
      priceEur: 1.0,
      hasNonfoil: true,
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

  testWidgets('plusieurs cases dans l\'extension lue : l\'utilisateur choisit', (
    tester,
  ) async {
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
  });

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
}
