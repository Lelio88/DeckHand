/// Tests de la vue classeur.
///
/// **Ce que ces tests protègent est la raison d'être de la vue : les cases
/// vides.** Une liste de collection dit ce qu'on possède ; un classeur dit ce
/// qui manque, à sa place, dans l'ordre des numéros. Si les cases vides
/// disparaissaient — parce qu'on partirait de la collection au lieu du
/// catalogue — il ne resterait qu'une liste en grille, et l'intérêt de la vue
/// avec elles.
///
/// Le second point est l'étagère : elle ne doit montrer que les éditions où
/// quelque chose est rangé. Le catalogue en compte 695, dont 690 seraient des
/// classeurs vides.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/presentation/binder_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

BinderShelfEntry shelfEntry({
  String setCode = 'msh',
  String setName = 'Marvel Super Heroes',
  int total = 453,
  int owned = 216,
  int copies = 300,
}) => BinderShelfEntry(
  setCode: setCode,
  setName: setName,
  totalCells: total,
  ownedCells: owned,
  ownedCopies: copies,
);

BinderCell cell({
  required String number,
  int owned = 0,
  String? name,
  bool hasFoil = false,
}) => BinderCell(
  collectorNumber: number,
  owned: owned,
  name: name ?? (owned > 0 ? 'Agent d\'Atlas' : null),
  hasFoil: hasFoil,
);

class FakeBinderRepository implements BinderRepository {
  FakeBinderRepository({this.entries = const [], this.cells = const []});

  List<BinderShelfEntry> entries;
  List<BinderCell> cells;

  /// Pages demandées, pour vérifier que la navigation atteint le serveur.
  final requested = <({String setCode, int page})>[];

  @override
  Future<List<BinderShelfEntry>> shelf({Game game = Game.magic}) async => entries;

  @override
  Future<List<BinderCell>> pageOf(
    String setCode, {
    int page = 1,
    int perPage = binderPageSize,
  }) async {
    requested.add((setCode: setCode, page: page));
    return cells;
  }
}

Future<FakeBinderRepository> pumpBinder(
  WidgetTester tester, {
  List<BinderShelfEntry> entries = const [],
  List<BinderCell> cells = const [],
}) async {
  final repository = FakeBinderRepository(entries: entries, cells: cells);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [binderRepositoryProvider.overrideWithValue(repository)],
      child: const MaterialApp(home: Scaffold(body: BinderView())),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  group('l\'étagère', () {
    testWidgets('ne montre que les éditions où quelque chose est rangé', (
      tester,
    ) async {
      await pumpBinder(
        tester,
        entries: [
          shelfEntry(),
          shelfEntry(
            setCode: 'msc',
            setName: 'Marvel Super Heroes Commander',
            total: 866,
            owned: 12,
            copies: 12,
          ),
        ],
      );

      expect(find.text('Marvel Super Heroes'), findsOneWidget);
      expect(find.text('Marvel Super Heroes Commander'), findsOneWidget);
    });

    testWidgets('annonce la complétion, pas seulement le nombre de cartes', (
      tester,
    ) async {
      // C'est le taux qui fait regarder un classeur : « 216 cartes » ne dit pas
      // s'il est presque plein ou à peine entamé.
      await pumpBinder(tester, entries: [shelfEntry()]);

      expect(find.textContaining('216 / 453 cases'), findsOneWidget);
      expect(find.text('48 %'), findsOneWidget);
    });

    testWidgets('sans classeur, explique pourquoi plutôt que rester vide', (
      tester,
    ) async {
      // Une carte sans édition précisée n'a pas de case. Le dire évite de
      // laisser croire à une collection vide.
      await pumpBinder(tester);

      expect(find.text('Aucun classeur'), findsOneWidget);
      expect(find.textContaining('Précisez l\'édition'), findsOneWidget);
    });
  });

  group('une page de classeur', () {
    testWidgets('les cases vides occupent leur place', (tester) async {
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [
          cell(number: '1', owned: 1),
          cell(number: '2'),
          cell(number: '3', owned: 2),
        ],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      // Les trois numéros sont affichés, y compris celui qu'on ne possède pas :
      // c'est toute la différence avec une liste de collection.
      expect(find.textContaining('#1'), findsWidgets);
      expect(
        find.textContaining('#2'),
        findsWidgets,
        reason: 'une case vide est ce que le classeur a de plus à dire',
      );
      expect(find.textContaining('#3'), findsWidgets);
    });

    testWidgets('le brillant se signale sans prendre de case', (tester) async {
      // Deux cases pour le même numéro casseraient la grille physique.
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1, hasFoil: true)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    });

    testWidgets('tourner la page atteint le serveur', (tester) async {
      // Un classeur de 453 cases fait 51 pages : les charger toutes pour n'en
      // montrer neuf serait aussi lent qu'inutile.
      final repository = await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Page suivante'));
      await tester.pumpAndSettle();

      expect(repository.requested.last, (setCode: 'msh', page: 2));
    });

    testWidgets('la première page n\'a pas de précédente', (tester) async {
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      final previous = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.chevron_left),
          matching: find.byType(IconButton),
        ),
      );
      expect(previous.onPressed, isNull);
    });

    testWidgets('on revient à l\'étagère', (tester) async {
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Retour à l\'étagère'));
      await tester.pumpAndSettle();

      expect(find.textContaining('216 / 453 cases'), findsOneWidget);
    });
  });

  group('le compte des pages', () {
    test('une édition se découpe en feuilles de neuf', () {
      expect(shelfEntry(total: 453).pages, 51);
      expect(shelfEntry(total: 866).pages, 97);
      expect(shelfEntry(total: 9).pages, 1);
      expect(shelfEntry(total: 10).pages, 2);
      expect(shelfEntry(total: 0).pages, 0);
    });

    test('la complétion est une part, pas un compte', () {
      expect(shelfEntry(total: 100, owned: 25).completion, 0.25);
      expect(shelfEntry(total: 0, owned: 0).completion, 0);
    });
  });
}
