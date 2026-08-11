/// Tests du journal des mouvements.
///
/// **Ce qu'ils protègent : qu'un rangement ne passe pas pour une acquisition.**
/// Préciser l'édition d'une carte produit deux mouvements opposés — un retrait
/// sur l'impression quittée, un ajout sur celle qui la reçoit. Les lire comme
/// une perte suivie d'un gain ferait mentir le journal sur la seule question
/// qu'on lui pose : quand ai-je acquis cette carte.
///
/// Le second point est le **report d'ouverture**. Le journal ne réécrit pas le
/// passé : ce qui précède sa création est une reprise en bloc, et doit se dire
/// comme telle plutôt que de se faire passer pour un achat du jour.
library;

import 'package:deckhand/src/features/collection/domain/collection_movement.dart';
import 'package:deckhand/src/features/collection/presentation/history_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';

import '../../helpers/fakes.dart';

/// Un mouvement tel que le serveur le rend.
CollectionMovement movement({
  required int delta,
  required DateTime at,
  String name = 'Cavalerie atlante',
  String? setCode = 'msh',
  bool opening = false,
  bool move = false,
}) => CollectionMovement.fromJson({
  'happened_at': at.toUtc().toIso8601String(),
  'delta': delta,
  'oracle_id': 'oracle-1',
  'name': name,
  'set_code': setCode,
  'collector_number': '45',
  'lang': 'fr',
  'is_foil': false,
  'is_opening': opening,
  'is_move': move,
});

Future<FakeCollectionRepository> pumpHistory(
  WidgetTester tester, {
  required List<CollectionMovement> movements,
  String? oracleId,
}) async {
  final collection = FakeCollectionRepository()..movements = movements;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        collectionRepositoryProvider.overrideWithValue(collection),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  showCollectionHistory(context, oracleId: oracleId),
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
  return collection;
}

void main() {
  final now = DateTime.now();

  group('ce qu\'un mouvement raconte', () {
    test('un ajout est une acquisition', () {
      final m = movement(delta: 2, at: now);
      expect(m.kind, MovementKind.acquired);
      expect(m.label, 'Ajoutée');
    });

    test('un retrait est une sortie', () {
      expect(movement(delta: -1, at: now).kind, MovementKind.released);
    });

    test('un rangement n\'est ni l\'un ni l\'autre', () {
      // Les deux faces d'un changement d'édition : le signe ne doit pas
      // décider, sinon la moitié d'un rangement compte comme un achat.
      final sortie = movement(delta: -3, at: now, move: true);
      final entree = movement(delta: 3, at: now, move: true);
      expect(sortie.kind, MovementKind.moved);
      expect(entree.kind, MovementKind.moved);
      expect(entree.label, 'Rangée ici');
      expect(sortie.label, 'Déplacée');
    });

    test('un report d\'ouverture le reste, quel que soit son signe', () {
      // Il précède le journal : le présenter comme un ajout du jour ferait
      // croire à une acquisition qui n'a pas eu lieu ce jour-là.
      final m = movement(delta: 3, at: now, opening: true, move: true);
      expect(m.kind, MovementKind.opening);
      expect(m.label, 'Déjà là');
    });

    test('une édition non précisée se dit, plutôt que de rester vide', () {
      final m = movement(delta: 1, at: now, setCode: null);
      expect(m.editionLabel, 'Édition non précisée');
    });
  });

  group('le journal à l\'écran', () {
    testWidgets('les jours se distinguent, du plus récent au plus ancien', (
      tester,
    ) async {
      // C'est l'échelle à laquelle on se souvient : « j'ai vidé une boîte hier
      // soir », pas « il était 21 h 14 ».
      await pumpHistory(
        tester,
        movements: [
          movement(delta: 1, at: now),
          movement(delta: 2, at: now.subtract(const Duration(days: 1))),
          movement(delta: 3, at: now.subtract(const Duration(days: 9))),
        ],
      );

      expect(find.text("Aujourd'hui"), findsOneWidget);
      expect(find.text('Hier'), findsOneWidget);
      expect(find.textContaining('/'), findsWidgets);
    });

    testWidgets('le signe du mouvement est lisible', (tester) async {
      await pumpHistory(
        tester,
        movements: [
          movement(delta: 2, at: now),
          movement(delta: -1, at: now),
        ],
      );

      expect(find.text('+2'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
    });

    testWidgets('un journal vide le dit', (tester) async {
      await pumpHistory(tester, movements: const []);

      expect(find.textContaining('Aucun mouvement'), findsOneWidget);
    });

    testWidgets('le journal d\'une carte ne demande que la sienne', (
      tester,
    ) async {
      final collection = await pumpHistory(
        tester,
        movements: [movement(delta: 1, at: now)],
        oracleId: 'oracle-1',
      );

      expect(collection.lastHistoryOracleId, 'oracle-1');
    });

    testWidgets('le journal complet ne restreint à aucune carte', (
      tester,
    ) async {
      final collection = await pumpHistory(
        tester,
        movements: [movement(delta: 1, at: now)],
      );

      expect(collection.lastHistoryOracleId, isNull);
    });
  });
}
