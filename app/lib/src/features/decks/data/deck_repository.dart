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
        // `p_tier` reste offert par le serveur : le jour où une source
        // apportera des listes de tournoi Commander, la distinction
        // redeviendra utile. Aujourd'hui elle doublonne le format.
        'p_tier': null,
        // Trié pour que la requête soit la même d'une sélection à l'autre : le
        // serveur n'a que faire de l'ordre dans lequel on a touché les pastilles.
        'p_colors': (filters.colors.toList()..sort()),
        'p_commander': filters.commander.trim().isEmpty
            ? null
            : filters.commander.trim(),
        'p_owned_commander': filters.ownedCommanderOnly,
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
    this.maxCostEur,
    this.colors = const {},
    this.commander = '',
    this.ownedCommanderOnly = false,
  });

  /// N'afficher que les decks sans carte manquante.
  final bool buildableOnly;

  /// Plafond du coût de complétion, en euros. Nul si aucune limite.
  final double? maxCostEur;

  /// Couleurs retenues, en symboles Scryfall (`W`, `U`, `B`, `R`, `G`).
  ///
  /// **C'est un tamis, pas une recherche** : ne sont proposés que les decks dont
  /// l'identité tient dans cette sélection. Demander « rouge » et recevoir un
  /// deck à cinq couleurs n'aiderait personne — il serait injouable pour qui
  /// voulait justement du mono-rouge.
  final Set<String> colors;

  /// Nom de commandant cherché. Vide = tous.
  ///
  /// C'est la façon dont on choisit un deck Commander : on part du général
  /// qu'on veut jouer. La recherche accepte le nom français comme l'anglais.
  final String commander;

  /// N'afficher que les decks dont on possède déjà le commandant.
  final bool ownedCommanderOnly;

  bool get isActive =>
      buildableOnly ||
      ownedCommanderOnly ||
      maxCostEur != null ||
      colors.isNotEmpty ||
      commander.trim().isNotEmpty;

  DeckFilters copyWith({
    bool? buildableOnly,
    double? maxCostEur,
    Set<String>? colors,
    String? commander,
    bool? ownedCommanderOnly,
    bool clearCost = false,
  }) => DeckFilters(
    buildableOnly: buildableOnly ?? this.buildableOnly,
    maxCostEur: clearCost ? null : (maxCostEur ?? this.maxCostEur),
    colors: colors ?? this.colors,
    commander: commander ?? this.commander,
    ownedCommanderOnly: ownedCommanderOnly ?? this.ownedCommanderOnly,
  );
}

class DeckFiltersNotifier extends Notifier<DeckFilters> {
  @override
  DeckFilters build() => const DeckFilters();

  void toggleBuildable() =>
      state = state.copyWith(buildableOnly: !state.buildableOnly);

  void setMaxCost(double? value) => value == null
      ? state = state.copyWith(clearCost: true)
      : state = state.copyWith(maxCostEur: value);

  void toggleColor(String symbol) {
    final next = {...state.colors};
    if (!next.remove(symbol)) next.add(symbol);
    state = state.copyWith(colors: next);
  }

  void toggleOwnedCommander() =>
      state = state.copyWith(ownedCommanderOnly: !state.ownedCommanderOnly);

  void searchCommander(String name) => state = state.copyWith(commander: name);

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
