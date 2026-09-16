/// L'onglet Collection demande-t-il l'étagère sans attendre le résumé ?
///
/// **Deux allers-retours se suivaient là où ils pouvaient marcher côte à côte.**
/// L'écran observait `collectionProvider`, et ne montait le classeur que sur sa
/// branche `data` : `my_binder_shelf` ne partait donc qu'une fois
/// `my_collection_summary` revenu. Mesuré sous le rôle réel, 0,82 s puis 0,34 s
/// en série ; et sur une base au cache froid, le premier appel a été relevé
/// jusqu'à 7,63 s — toute cette attente avant même de demander l'étagère.
///
/// Le résumé ne servait ici qu'à décider « collection vide ». `_Shelf` répond
/// mieux à la même question, en offrant la pile « à trier » et en distinguant
/// les deux vides.
///
/// **Ce test échoue si quelqu'un remet une porte devant le classeur** : un
/// résumé qui n'arrive jamais ne doit pas empêcher l'étagère d'être demandée.
library;

import 'dart:async';

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:deckhand/src/features/collection/presentation/collection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

/// Un résumé qui ne revient jamais — le pire cas d'un serveur au cache froid.
class ResumeSuspendu extends FakeCollectionRepository {
  final Completer<CollectionSummary> jamais = Completer<CollectionSummary>();

  @override
  Future<CollectionSummary> summary({Game game = Game.magic}) => jamais.future;
}

/// Une étagère qui compte ce qu'on lui demande. Seul `shelf` est exercé ici.
class EtagereQuiCompte implements BinderRepository {
  int shelfCalls = 0;

  @override
  Future<List<BinderShelfEntry>> shelf({
    Game game = Game.magic,
    String? collection,
  }) async {
    shelfCalls++;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('l\'étagère est demandée même si le résumé n\'arrive pas', (
    tester,
  ) async {
    final collection = ResumeSuspendu();
    final binders = EtagereQuiCompte();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          collectionRepositoryProvider.overrideWithValue(collection),
          binderRepositoryProvider.overrideWithValue(binders),
          sessionProvider.overrideWith(
            (ref) => Stream<Session?>.value(fakeSession()),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: CollectionScreen())),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Le résumé est toujours en vol, et l'étagère est déjà partie.
    expect(collection.jamais.isCompleted, isFalse);
    expect(binders.shelfCalls, 1);
  });
}
