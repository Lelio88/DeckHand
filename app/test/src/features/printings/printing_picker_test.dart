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
/// Le choix reste le sien : rien n'est coché, rien n'est ajouté d'office
/// (garde-fou §IV.8 du CLAUDE.md).
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

void main() {
  final catalogue = [
    printing('mkm', '12', setName: "Meurtres au manoir Karlov"),
    printing('msh', '412', setName: 'Marvel Super Heroes'),
    printing('lci', '77', setName: "Les caveaux perdus d'Ixalan"),
  ];

  testWidgets('sans lecture, l\'ordre du catalogue est conservé', (
    tester,
  ) async {
    final order = await pumpPicker(tester, printings: catalogue);

    expect(order, ['MKM', 'MSH', 'LCI']);
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

    expect(order, ['MKM', 'MSH', 'LCI']);
    expect(find.textContaining('lue sur la carte'), findsNothing);
  });

  testWidgets('rien n\'est choisi à la place de l\'utilisateur', (
    tester,
  ) async {
    await pumpPicker(
      tester,
      printings: catalogue,
      readSetCode: (codes) => 'msh',
    );

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
    expect(
      tiles.where((t) => t.selected),
      isEmpty,
      reason:
          'une édition fausse range la carte dans la mauvaise case ; '
          'l\'utilisateur confirme en tapant (§IV.8)',
    );
  });
}
