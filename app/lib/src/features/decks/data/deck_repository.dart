/// Accès aux suggestions de decks.
///
/// Le calcul vit côté base : confronter une collection à des centaines de
/// decklists est une jointure, pas un travail de client. Rapatrier le corpus
/// pour le comparer localement serait absurde.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/request_timeout.dart';
import '../../../config/selected_game.dart';
import '../../auth/data/auth_repository.dart';
import '../../collection/data/collection_repository.dart';
import '../domain/deck_suggestion.dart';
import '../domain/mana_color.dart';

class DeckRepository {
  const DeckRepository(this._client);

  final SupabaseClient _client;

  Future<List<DeckSuggestion>> suggestions(
    DeckFormat format, {
    DeckFilters filters = const DeckFilters(),
    int maxResults = 30,
    Game game = Game.magic,
  }) async {
    final rows = await _client
        .rpc<List<dynamic>>(
          'deck_suggestions',
          params: {
            'p_format': format.id,
            // **Sans le jeu, le serveur répond « magic ».** Le format suffisait
            // tant qu'un seul jeu avait des decks ; il ne suffit plus, et
            // l'omission ne se serait vue qu'à un écran vide.
            'p_game': game.id,
            // Zéro carte manquante = constructible dès maintenant.
            'p_max_missing': filters.budget.maxMissing,
            'p_max_results': maxResults,
            'p_max_cost': filters.budget.maxCostEur,
            // `p_tier` reste offert par le serveur : le jour où une source
            // apportera des listes de tournoi Commander, la distinction
            // redeviendra utile. Aujourd'hui elle doublonne le format.
            'p_tier': null,
            // Trié pour que la requête soit la même d'une sélection à l'autre : le
            // serveur n'a que faire de l'ordre dans lequel on a touché les pastilles.
            'p_colors': (filters.colors.toList()..sort()),
            'p_banned_colors': (filters.bannedColors.toList()..sort()),
            'p_commander': filters.commander.trim().isEmpty
                ? null
                : filters.commander.trim(),
            'p_owned_commander': filters.ownedCommanderOnly,
          },
        )
        .timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(DeckSuggestion.fromJson)
        .toList(growable: false);
  }

  Future<List<MissingCard>> missingCards(String deckId) async {
    final rows = await _client
        .rpc<List<dynamic>>('deck_missing_cards', params: {'p_deck_id': deckId})
        .timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(MissingCard.fromJson)
        .toList(growable: false);
  }
}

final deckRepositoryProvider = Provider<DeckRepository>(
  (ref) => DeckRepository(Supabase.instance.client),
);

/// Ce qu'on est prêt à dépenser pour compléter un deck.
///
/// **Un seul contrôle là où il y en avait deux.** « Constructibles » et le
/// plafond de budget répondaient à la même question — jusqu'où suis-je prêt à
/// aller — mais se cochaient séparément, si bien qu'on pouvait demander un deck
/// sans rien à acheter *et* un budget de cinquante euros. Les fondre supprime la
/// contradiction.
///
/// **« Constructible » n'est pourtant pas « zéro euro ».** Une carte manquante
/// sans cote coûte zéro et manque quand même : le premier cas exige qu'il ne
/// manque *rien*, les autres plafonnent une dépense. C'est pourquoi il ouvre le
/// menu au lieu d'y figurer comme un montant.
enum DeckBudget {
  any('Tous budgets'),
  buildable('Constructibles — rien à acheter'),
  under10('Moins de 10 €'),
  under25('Moins de 25 €'),
  under50('Moins de 50 €'),
  under100('Moins de 100 €');

  const DeckBudget(this.label);

  final String label;

  /// Nombre de cartes manquantes toléré.
  int get maxMissing => this == DeckBudget.buildable ? 0 : 100;

  /// Plafond de dépense, ou `null` quand il n'y en a pas.
  double? get maxCostEur => switch (this) {
    DeckBudget.under10 => 10,
    DeckBudget.under25 => 25,
    DeckBudget.under50 => 50,
    DeckBudget.under100 => 100,
    _ => null,
  };

  /// Étiquette courte, pour la puce refermée.
  String get shortLabel => switch (this) {
    DeckBudget.any => 'Budget',
    DeckBudget.buildable => 'Constructibles',
    _ => label.replaceFirst('Moins de ', '< '),
  };
}

/// Critères d'affinage des suggestions.
///
/// Séparés du format parce qu'ils répondent à d'autres questions : le format dit
/// *quoi* jouer, les filtres disent *ce qui est à portée*.
class DeckFilters {
  const DeckFilters({
    this.budget = DeckBudget.any,
    this.colors = const {},
    this.bannedColors = const {},
    this.commander = '',
    this.ownedCommanderOnly = false,
  });

  /// Jusqu'où l'on est prêt à aller pour compléter un deck.
  final DeckBudget budget;

  /// Couleurs que le deck doit porter.
  final Set<String> colors;

  /// Couleurs que le deck ne doit pas porter.
  final Set<String> bannedColors;

  /// Nom de commandant cherché. Vide = tous.
  ///
  /// C'est la façon dont on choisit un deck Commander : on part du général
  /// qu'on veut jouer. La recherche accepte le nom français comme l'anglais.
  final String commander;

  /// N'afficher que les decks dont on possède déjà le commandant.
  final bool ownedCommanderOnly;

  bool get isActive =>
      budget != DeckBudget.any ||
      ownedCommanderOnly ||
      colors.isNotEmpty ||
      bannedColors.isNotEmpty ||
      commander.trim().isNotEmpty;

  DeckFilters copyWith({
    DeckBudget? budget,
    Set<String>? colors,
    Set<String>? bannedColors,
    String? commander,
    bool? ownedCommanderOnly,
  }) => DeckFilters(
    budget: budget ?? this.budget,
    colors: colors ?? this.colors,
    bannedColors: bannedColors ?? this.bannedColors,
    commander: commander ?? this.commander,
    ownedCommanderOnly: ownedCommanderOnly ?? this.ownedCommanderOnly,
  );
}

class DeckFiltersNotifier extends Notifier<DeckFilters> {
  @override
  DeckFilters build() => const DeckFilters();

  void setBudget(DeckBudget budget) => state = state.copyWith(budget: budget);

  /// Remplace les deux ensembles d'un coup.
  ///
  /// La roue mène son propre pas-à-pas — voulue, bannie, indifférente — et ne
  /// rend son résultat qu'à la validation : filtrer à chaque appui relancerait
  /// une requête par pression, et le troisième appui annulant le premier, on en
  /// paierait trois pour revenir au point de départ.
  void setColors(Set<String> wanted, Set<String> banned) =>
      state = state.copyWith(colors: wanted, bannedColors: banned);

  void toggleColor(String symbol) {
    // Un appui fait avancer d'un état : indifférent, voulue, bannie, puis
    // retour. C'est le geste demandé — une pression pour vouloir, deux pour
    // bannir — sans second contrôle.
    final wanted = {...state.colors};
    final banned = {...state.bannedColors};
    final current = wanted.contains(symbol)
        ? ManaChoice.wanted
        : banned.contains(symbol)
        ? ManaChoice.banned
        : ManaChoice.neutral;

    wanted.remove(symbol);
    banned.remove(symbol);
    switch (current.next) {
      case ManaChoice.wanted:
        wanted.add(symbol);
      case ManaChoice.banned:
        banned.add(symbol);
      case ManaChoice.neutral:
        break;
    }
    state = state.copyWith(colors: wanted, bannedColors: banned);
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
///
/// **Il suit le jeu.** Un format n'appartient qu'à un jeu : rester sur Pauper
/// après une bascule vers Riftbound ferait demander au serveur un format qui n'y
/// existe pas, et l'écran annoncerait « aucun deck » sur un corpus de 2 500.
/// C'est exactement le genre de câblage qui cède en silence — la sélection se
/// remet donc au premier format du jeu courant.
class SelectedFormat extends Notifier<DeckFormat> {
  @override
  DeckFormat build() => deckFormatsFor(ref.watch(selectedGameProvider)).first;

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
          .suggestions(
            format,
            filters: filters,
            game: ref.watch(selectedGameProvider),
          );
    });

final missingCardsProvider = FutureProvider.autoDispose
    .family<List<MissingCard>, String>((ref, deckId) {
      return ref.watch(deckRepositoryProvider).missingCards(deckId);
    });
