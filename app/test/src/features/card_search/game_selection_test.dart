/// Le jeu choisi atteint-il vraiment le serveur ?
///
/// **C'est le maillon qui cède en silence.** Un sélecteur peut cocher la bonne
/// case, l'écran afficher le bon libellé, et la requête partir sans le
/// paramètre : l'utilisateur voit alors le catalogue Magic sous une étiquette
/// Riftbound, sans rien qui signale l'erreur. Le même défaut a déjà été trouvé
/// trois fois sur ce projet, toujours entre l'état et l'appel.
///
/// Les assertions portent donc sur **ce que le dépôt a reçu**.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/card_search/data/card_repository.dart';
import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Retient le jeu de la dernière recherche.
class _RecordingCatalogue implements CardRepository {
  Game? lastGame;

  @override
  Future<List<CardHit>> search(
    String query, {
    int limit = 20,
    Game game = Game.magic,
  }) async {
    lastGame = game;
    return const [];
  }

  @override
  Future<List<CardHit>> byOracleIds(List<String> oracleIds) async => const [];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('la recherche part avec le jeu sélectionné', () async {
    final catalogue = _RecordingCatalogue();
    final container = ProviderContainer(
      overrides: [cardRepositoryProvider.overrideWithValue(catalogue)],
    );
    addTearDown(container.dispose);

    await container.read(cardSearchProvider('foudre').future);
    expect(catalogue.lastGame, Game.magic, reason: 'Magic par défaut');

    await container.read(selectedGameProvider.notifier).select(Game.riftbound);
    await container.read(cardSearchProvider('vi').future);

    expect(
      catalogue.lastGame,
      Game.riftbound,
      reason: 'sans ce paramètre, le serveur répondrait avec le catalogue '
          'Magic sous une étiquette Riftbound — une erreur invisible',
    );
  });

  test('le choix de jeu survit au redémarrage', () async {
    SharedPreferences.setMockInitialValues({'selected_game': 'riftbound'});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // La lecture des préférences est asynchrone : l'état part sur Magic pour
    // ne pas retarder le premier affichage, puis se corrige.
    container.read(selectedGameProvider);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(selectedGameProvider), Game.riftbound);
  });

  test('un identifiant inconnu retombe sur Magic', () {
    // Une préférence écrite par une version antérieure, ou corrompue, ne doit
    // pas empêcher l'application de démarrer.
    expect(Game.fromId('pokemon'), Game.magic);
    expect(Game.fromId(null), Game.magic);
  });
}
