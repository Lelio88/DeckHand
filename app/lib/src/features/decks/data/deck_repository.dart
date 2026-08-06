/// Accès aux suggestions de decks.
///
/// Le calcul vit côté base : confronter une collection à des centaines de
/// decklists est une jointure, pas un travail de client. Rapatrier le corpus
/// pour le comparer localement serait absurde.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/data/auth_repository.dart';
import '../../collection/data/collection_repository.dart';
import '../domain/deck_suggestion.dart';

class DeckRepository {
  const DeckRepository(this._client);

  final SupabaseClient _client;

  Future<List<DeckSuggestion>> suggestions(
    DeckFormat format, {
    int maxMissing = 100,
    int maxResults = 30,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'deck_suggestions',
      params: {
        'p_format': format.id,
        'p_max_missing': maxMissing,
        'p_max_results': maxResults,
      },
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(DeckSuggestion.fromJson)
        .toList(growable: false);
  }

  Future<List<MissingCard>> missingCards(String deckId) async {
    final rows = await _client.rpc<List<dynamic>>(
      'deck_missing_cards',
      params: {'p_deck_id': deckId},
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(MissingCard.fromJson)
        .toList(growable: false);
  }
}

final deckRepositoryProvider = Provider<DeckRepository>(
  (ref) => DeckRepository(Supabase.instance.client),
);

/// Format actuellement consulté.
///
/// Un `Notifier` et non un `StateProvider` : ce dernier a été retiré de
/// Riverpod 3.
class SelectedFormat extends Notifier<DeckFormat> {
  @override
  DeckFormat build() => DeckFormat.pauper;

  void select(DeckFormat format) => state = format;
}

final selectedFormatProvider = NotifierProvider<SelectedFormat, DeckFormat>(
  SelectedFormat.new,
);

/// Suggestions pour le format sélectionné.
///
/// Dépend de `collectionProvider` : ajouter une carte doit refaire remonter les
/// decks concernés sans que l'utilisateur ait à rafraîchir quoi que ce soit.
final deckSuggestionsProvider =
    FutureProvider.autoDispose<List<DeckSuggestion>>((ref) async {
      final session = ref.watch(sessionProvider).asData?.value;
      if (session == null) return const [];

      ref.watch(collectionProvider);
      final format = ref.watch(selectedFormatProvider);
      return ref.watch(deckRepositoryProvider).suggestions(format);
    });

final missingCardsProvider = FutureProvider.autoDispose
    .family<List<MissingCard>, String>((ref, deckId) {
      return ref.watch(deckRepositoryProvider).missingCards(deckId);
    });
