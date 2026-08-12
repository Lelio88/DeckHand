/// Le jeu choisi atteint-il les suggestions de decks ?
///
/// **C'est le maillon qui cède en silence**, et il a déjà cédé ici : le dépôt
/// envoyait `p_format` sans `p_game`, si bien que le serveur répondait avec le
/// corpus Magic. Tant que Riftbound n'avait aucun deck, l'omission ne se voyait
/// pas ; avec 2 500 decks importés, elle produirait un écran vide sans rien dire
/// pourquoi.
///
/// Le second point vérifié est le **format**, qui n'appartient qu'à un jeu.
/// Demander « pauper » en Riftbound ne rendrait rien, et l'écran annoncerait
/// « aucun deck » sur un corpus bien peuplé.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/decks/data/deck_repository.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

/// Conteneur dont la session est déjà arrivée, et dont les suggestions restent
/// abonnées.
///
/// Deux précautions, chacune pour une raison distincte. Sans session,
/// `deckSuggestionsProvider` rend une liste vide **sans interroger le dépôt** :
/// le test passerait en n'observant rien. Et sans abonné, un provider
/// `autoDispose` se défait entre deux lectures, si bien que le format et le jeu
/// repartiraient de zéro à chaque appel.
Future<ProviderContainer> containerWith(FakeDeckRepository decks) async {
  final container = ProviderContainer(
    overrides: [
      deckRepositoryProvider.overrideWithValue(decks),
      sessionProvider.overrideWith(
        (ref) => Stream<Session?>.value(fakeSession()),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(sessionProvider, (_, _) {}, fireImmediately: true);
  container.listen(deckSuggestionsProvider, (_, _) {}, fireImmediately: true);
  // Laisse le flux de session émettre : c'est lui qui débloque les suggestions.
  await Future<void>.delayed(Duration.zero);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('les formats proposés sont ceux du jeu', () {
    expect(deckFormatsFor(Game.magic), [
      DeckFormat.pauper,
      DeckFormat.modern,
      DeckFormat.commander,
    ]);
    expect(deckFormatsFor(Game.riftbound), [DeckFormat.constructed]);
    expect(deckFormatsFor(Game.yugioh), [
      DeckFormat.edison,
      DeckFormat.goat,
      DeckFormat.redu,
      DeckFormat.hat,
    ]);
  });

  test('le format en tête est celui qui porte le corpus', () {
    // **C'est l'onglet ouvert par défaut**, donc le seul que beaucoup verront.
    // Le premier jet mettait `Advanced` en tête pour Yu-Gi-Oh sur la foi de son
    // nom : mesuré, il portait 3 decklists contre 3 069 à Edison, et l'écran
    // se serait ouvert vide. Pauper tient ce rôle chez Magic pour la même
    // raison — c'est là qu'une collection ordinaire produit des decks complets.
    expect(deckFormatsFor(Game.magic).first, DeckFormat.pauper);
    expect(deckFormatsFor(Game.yugioh).first, DeckFormat.edison);
  });

  test('chaque jeu propose au moins un format', () {
    // `SelectedFormat.build()` et l'écran font tous deux `formats.first` : une
    // liste vide ne rendrait pas un écran vide, elle lèverait. Ajouter un jeu
    // sans format le ferait planter au premier affichage des decks.
    for (final game in Game.values) {
      expect(
        deckFormatsFor(game),
        isNotEmpty,
        reason: 'le jeu « ${game.id} » ne propose aucun format',
      );
    }
  });

  test('la demande part avec le jeu sélectionné', () async {
    final decks = FakeDeckRepository();
    final container = await containerWith(decks);

    await container.read(deckSuggestionsProvider.future);
    expect(decks.lastGame, Game.magic, reason: 'Magic par défaut');

    await container.read(selectedGameProvider.notifier).select(Game.riftbound);
    await container.read(deckSuggestionsProvider.future);

    expect(
      decks.lastGame,
      Game.riftbound,
      reason:
          'sans ce paramètre le serveur répond avec le corpus Magic, et '
          'l\'écran annonce « aucun deck » sur 2 500 listes',
    );
  });

  test('changer de jeu change le format demandé', () async {
    final decks = FakeDeckRepository();
    final container = await containerWith(decks);

    await container.read(deckSuggestionsProvider.future);
    expect(decks.lastFormat, DeckFormat.pauper);

    await container.read(selectedGameProvider.notifier).select(Game.riftbound);
    await container.read(deckSuggestionsProvider.future);

    expect(
      decks.lastFormat,
      DeckFormat.constructed,
      reason: 'rester sur Pauper demanderait un format qui n\'existe pas ici',
    );
  });

  test('le format choisi tient tant qu\'on ne change pas de jeu', () async {
    final decks = FakeDeckRepository();
    final container = await containerWith(decks);

    container
        .read(selectedFormatProvider.notifier)
        .select(DeckFormat.commander);
    await container.read(deckSuggestionsProvider.future);

    expect(decks.lastFormat, DeckFormat.commander);
  });
}
