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
    DeckFilters filters = const DeckFilters(),
    int maxResults = 30,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'deck_suggestions',
      params: {
        'p_format': format.id,
        // Zéro carte manquante = constructible dès maintenant.
        'p_max_missing': filters.buildableOnly ? 0 : 100,
        'p_max_results': maxResults,
        'p_max_cost': filters.maxCostEur,
        'p_tier': filters.accessibleOnly ? 'accessible' : null,
        // Trié pour que la requête soit la même d'une sélection à l'autre : le
        // serveur n'a que faire de l'ordre dans lequel on a touché les pastilles.
        'p_colors': (filters.colors.toList()..sort()),
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

/// Critères d'affinage des suggestions.
///
/// Séparés du format parce qu'ils répondent à d'autres questions : le format dit
/// *quoi* jouer, les filtres disent *ce qui est à portée*.
class DeckFilters {
  const DeckFilters({
    this.buildableOnly = false,
    this.accessibleOnly = false,
    this.maxCostEur,
    this.colors = const {},
  });

  /// N'afficher que les decks sans carte manquante.
  final bool buildableOnly;

  /// N'afficher que les decks accessibles (précons), à l'exclusion des listes
  /// de tournoi.
  final bool accessibleOnly;

  /// Plafond du coût de complétion, en euros. Nul si aucune limite.
  final double? maxCostEur;

  /// Couleurs retenues, en symboles Scryfall (`W`, `U`, `B`, `R`, `G`).
  ///
  /// **C'est un tamis, pas une recherche** : ne sont proposés que les decks dont
  /// l'identité tient dans cette sélection. Demander « rouge » et recevoir un
  /// deck à cinq couleurs n'aiderait personne — il serait injouable pour qui
  /// voulait justement du mono-rouge.
  final Set<String> colors;

  bool get isActive =>
      buildableOnly || accessibleOnly || maxCostEur != null || colors.isNotEmpty;

  DeckFilters copyWith({
    bool? buildableOnly,
    bool? accessibleOnly,
    double? maxCostEur,
    Set<String>? colors,
    bool clearCost = false,
  }) => DeckFilters(
    buildableOnly: buildableOnly ?? this.buildableOnly,
    accessibleOnly: accessibleOnly ?? this.accessibleOnly,
    maxCostEur: clearCost ? null : (maxCostEur ?? this.maxCostEur),
    colors: colors ?? this.colors,
  );
}

class DeckFiltersNotifier extends Notifier<DeckFilters> {
  @override
  DeckFilters build() => const DeckFilters();

  void toggleBuildable() =>
      state = state.copyWith(buildableOnly: !state.buildableOnly);

  void toggleAccessible() =>
      state = state.copyWith(accessibleOnly: !state.accessibleOnly);

  void setMaxCost(double? value) => value == null
      ? state = state.copyWith(clearCost: true)
      : state = state.copyWith(maxCostEur: value);

  void toggleColor(String symbol) {
    final next = {...state.colors};
    if (!next.remove(symbol)) next.add(symbol);
    state = state.copyWith(colors: next);
  }

  void reset() => state = const DeckFilters();
}

final deckFiltersProvider = NotifierProvider<DeckFiltersNotifier, DeckFilters>(
  DeckFiltersNotifier.new,
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
      final filters = ref.watch(deckFiltersProvider);
      return ref
          .watch(deckRepositoryProvider)
          .suggestions(format, filters: filters);
    });

final missingCardsProvider = FutureProvider.autoDispose
    .family<List<MissingCard>, String>((ref, deckId) {
      return ref.watch(deckRepositoryProvider).missingCards(deckId);
    });
