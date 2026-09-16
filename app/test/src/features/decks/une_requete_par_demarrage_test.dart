/// Combien de fois le démarrage interroge-t-il le serveur ?
///
/// **Une requête de trop ne casse rien, et c'est pour ça qu'elle survit.**
/// `deckSuggestionsProvider` observait `collectionProvider` pour se rafraîchir
/// après un ajout. Or observer un `FutureProvider`, c'est observer son
/// `AsyncValue` : au démarrage il vaut « en cours », puis « voici les totaux »,
/// et cette transition reconstruit tout ce qui l'observe. La requête partait
/// donc deux fois — mesuré à une seconde en Pauper et quatre en Commander,
/// jetées avant même que la première réponse n'arrive. L'écran, lui, affichait
/// la seconde réponse et avait l'air parfaitement juste.
///
/// Rien ne le voyait : ni `flutter analyze`, ni les tests d'écran, qui
/// assertent ce que le dépôt a **reçu** et non combien de fois. D'où ce
/// fichier, qui compte.
///
/// Le second test vérifie la contrepartie : sans l'observation, c'est
/// `refreshCollectionViews` qui doit rejouer les decks après une écriture.
/// Retirer l'un sans mettre l'autre laisserait un écran figé sur des decks
/// périmés — un défaut silencieux de la même famille.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_views.dart';
import 'package:deckhand/src/features/decks/data/deck_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

/// Un conteneur dont la session est arrivée et dont les decks restent abonnés.
///
/// Sans session, le provider rend une liste vide **sans interroger le dépôt**,
/// et le test passerait en n'observant rien. Sans abonné, un provider
/// `autoDispose` se défait entre deux lectures.
Future<ProviderContainer> demarrage(
  FakeDeckRepository decks,
  FakeCollectionRepository collection,
) async {
  final container = ProviderContainer(
    overrides: [
      deckRepositoryProvider.overrideWithValue(decks),
      collectionRepositoryProvider.overrideWithValue(collection),
      sessionProvider.overrideWith(
        (ref) => Stream<Session?>.value(fakeSession()),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(sessionProvider, (_, _) {}, fireImmediately: true);
  // Le résumé est observé comme la barre du haut l'observe : c'est lui dont la
  // résolution déclenchait la seconde requête.
  container.listen(collectionProvider, (_, _) {}, fireImmediately: true);
  container.listen(deckSuggestionsProvider, (_, _) {}, fireImmediately: true);
  return container;
}

/// Laisse les futures en vol se résoudre et les reconstructions se propager.
Future<void> laisserRetomber(ProviderContainer container) async {
  await container.read(collectionProvider.future);
  await container.read(deckSuggestionsProvider.future);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('le démarrage ne demande les decks qu\'une fois', () async {
    final decks = FakeDeckRepository();
    final collection = FakeCollectionRepository();
    final container = await demarrage(decks, collection);

    await laisserRetomber(container);

    // **Un, pas deux.** La résolution du résumé ne doit plus rejouer les decks.
    expect(decks.calls, 1);
  });

  test('une écriture dans la collection rejoue les decks', () async {
    final decks = FakeDeckRepository();
    final collection = FakeCollectionRepository();
    final container = await demarrage(decks, collection);
    await laisserRetomber(container);
    expect(decks.calls, 1);

    // C'est ce que tout écran qui écrit appelle après un ajout ou un retrait.
    refreshCollectionViews(container.invalidate);
    await laisserRetomber(container);

    // Le rafraîchissement perdu avec l'observation est bien rendu par la liste.
    expect(decks.calls, 2);
  });
}
