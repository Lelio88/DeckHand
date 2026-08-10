/// Écran des decks : ce que la collection permet de construire.
///
/// Deux familles distinguées visuellement — constructibles immédiatement, et
/// à quelques cartes près avec leur coût. La distinction entre deck accessible
/// et deck de tournoi est affichée : un deck de compétition à plusieurs
/// centaines d'euros ne doit pas se présenter comme « presque à portée ».
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/deck_repository.dart';
import '../domain/deck_suggestion.dart';
import '../domain/mana_color.dart';

class DeckSuggestionsScreen extends ConsumerWidget {
  const DeckSuggestionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestions = ref.watch(deckSuggestionsProvider);

    return Column(
      children: [
        const _FormatSelector(),
        const _FilterBar(),
        Expanded(
          child: suggestions.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('Suggestions indisponibles : $error'),
              ),
            ),
            data: (decks) => decks.isEmpty
                ? _NoDeck(filtered: ref.watch(deckFiltersProvider).isActive)
                : _DeckList(decks: decks),
          ),
        ),
      ],
    );
  }
}

class _FormatSelector extends ConsumerWidget {
  const _FormatSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedFormatProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: SegmentedButton<DeckFormat>(
        segments: [
          for (final format in DeckFormat.values)
            ButtonSegment(value: format, label: Text(format.label)),
        ],
        selected: {selected},
        onSelectionChanged: (values) =>
            ref.read(selectedFormatProvider.notifier).select(values.first),
      ),
    );
  }
}

/// Affinage des suggestions.
///
/// Quatre questions distinctes, d'où quatre contrôles plutôt qu'un tri unique :
/// « qu'est-ce que je peux jouer ce soir » (constructibles), « qu'est-ce qui est
/// à ma portée » (budget), « qu'est-ce qui s'achète tout fait » (précons plutôt
/// que listes de tournoi), et « de quelle couleur » — celle-ci venant d'ordinaire
/// en premier chez un joueur, avant même le prix.
///
/// **Une seule ligne, qui défile.** Empilées sur deux rangs, les commandes
/// mangeaient la hauteur des suggestions, qui sont l'essentiel de l'écran. Les
/// plus employées viennent en tête, donc sous le pouce sans défiler.
class _FilterBar extends ConsumerWidget {
  const _FilterBar();

  /// Paliers de budget. Des valeurs fixes plutôt qu'un curseur : on choisit un
  /// ordre de grandeur, pas un montant au centime près.
  static const _budgets = <double?>[null, 10, 25, 50, 100];

  String _label(double? value) =>
      value == null ? 'Tous budgets' : '≤ ${value.round()} €';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(deckFiltersProvider);
    final notifier = ref.read(deckFiltersProvider.notifier);

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        children: [
          // En tête et non en fin de rangée : c'est la sortie de secours d'un
          // filtrage trop serré, et la reléguer derrière cinq pastilles la
          // rendait invisible sans défiler — précisément quand la liste est
          // vide et qu'on ne comprend pas pourquoi.
          if (filters.isActive) ...[
            TextButton(
              onPressed: notifier.reset,
              child: const Text('Tout afficher'),
            ),
            const SizedBox(width: 4),
          ],
          FilterChip(
            label: const Text('Constructibles'),
            selected: filters.buildableOnly,
            onSelected: (_) => notifier.toggleBuildable(),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),
          // « Précons » plutôt qu'« Accessibles » : le mot désignait la
          // provenance de la liste — un deck vendu tout fait — mais se lisait
          // comme une promesse de prix, juste à côté d'un filtre de budget qui,
          // lui, parle bien d'argent.
          FilterChip(
            label: const Text('Précons'),
            tooltip: 'Decks vendus tout faits, plutôt que listes de tournoi',
            selected: filters.accessibleOnly,
            onSelected: (_) => notifier.toggleAccessible(),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),
          PopupMenuButton<double?>(
            initialValue: filters.maxCostEur,
            onSelected: notifier.setMaxCost,
            itemBuilder: (context) => [
              for (final budget in _budgets)
                PopupMenuItem(value: budget, child: Text(_label(budget))),
            ],
            child: Chip(
              label: Text(_label(filters.maxCostEur)),
              avatar: const Icon(Icons.euro, size: 16),
              visualDensity: VisualDensity.compact,
              backgroundColor: filters.maxCostEur == null
                  ? null
                  : Theme.of(context).colorScheme.secondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          for (final color in manaColors) ...[
            _ColorChip(
              color: color,
              selected: filters.colors.contains(color.symbol),
              onTap: () => notifier.toggleColor(color.symbol),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

/// Pastille d'une couleur de mana.
///
/// **Une pastille et non un mot.** Les cinq couleurs se reconnaissent à leur
/// teinte depuis trente ans ; écrire « blanc, bleu, noir, rouge, vert » sur une
/// ligne déjà chargée coûterait quatre fois la place pour la même information.
/// L'initiale reste, pour qui hésite entre deux teintes voisines.
class _ColorChip extends StatelessWidget {
  const _ColorChip({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final ManaColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: color.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.swatch,
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: selected ? 3 : 1,
            ),
          ),
          child: Text(
            color.symbol,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color.onSwatch,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _DeckList extends StatelessWidget {
  const _DeckList({required this.decks});

  final List<DeckSuggestion> decks;

  @override
  Widget build(BuildContext context) {
    // L'attribution est une obligation contractuelle envers les sources : elle
    // doit rester visible, pas reléguée dans un écran « à propos ».
    final credits = decks
        .map((d) => d.attribution)
        .whereType<String>()
        .toSet()
        .join(' · ');

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: decks.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == decks.length) return _Credits(text: credits);
        return _DeckTile(deck: decks[index]);
      },
    );
  }
}

class _DeckTile extends StatelessWidget {
  const _DeckTile({required this.deck});

  final DeckSuggestion deck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // La barre de progression interne capturait la sémantique de la tuile, qui
    // était annoncée « barre de progression » au lieu de « bouton » : un lecteur
    // d'écran ne signalait pas qu'on peut l'ouvrir. On décrit donc la tuile
    // explicitement et on masque la sémantique de la barre, purement décorative.
    return Semantics(
      button: true,
      label: deck.isBuildable
          ? '${deck.deckName}, constructible, ${deck.totalCards} cartes'
          : '${deck.deckName}, ${(deck.completion * 100).round()} pour cent, '
                'il manque ${deck.missingCards} cartes pour '
                '${deck.missingCostEur.toStringAsFixed(2)} euros',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _MissingSheet(deck: deck),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: deck.isBuildable
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      deck.deckName,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(deck.completion * 100).round()} %',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: deck.completion,
                    minHeight: 6,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      deck.isBuildable
                          ? 'Constructible dès maintenant — ${deck.totalCards} cartes'
                          : 'Il manque ${deck.missingCards} carte${deck.missingCards > 1 ? 's' : ''} '
                                'sur ${deck.totalCards}',
                      style: muted,
                    ),
                  ),
                  if (!deck.isBuildable)
                    Text(
                      '${deck.missingCostEur.toStringAsFixed(2)} €',
                      style: theme.textTheme.titleSmall,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  _Tag(
                    deck.isCompetitive ? 'Tournoi' : 'Précon',
                    emphasised: !deck.isCompetitive,
                  ),
                  _Tag(deck.sourceName),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.emphasised = false});

  final String label;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: emphasised
            ? theme.colorScheme.tertiaryContainer
            : theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: emphasised
              ? theme.colorScheme.onTertiaryContainer
              : theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _MissingSheet extends ConsumerWidget {
  const _MissingSheet({required this.deck});

  final DeckSuggestion deck;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final missing = ref.watch(missingCardsProvider(deck.deckId));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(deck.deckName, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  deck.isBuildable
                      ? 'Vous avez toutes les cartes.'
                      : 'Liste de courses — ${deck.missingCostEur.toStringAsFixed(2)} €',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: missing.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (error, _) => Center(child: Text('Erreur : $error')),
              data: (cards) => ListView.builder(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                itemCount: cards.length,
                itemBuilder: (context, index) {
                  final card = cards[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          child: Text(
                            '${card.missing}×',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(card.displayName),
                              if (card.owned > 0)
                                Text(
                                  'vous en avez ${card.owned} sur ${card.needed}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '${(card.lineCostEur ?? 0).toStringAsFixed(2)} €',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Credits extends StatelessWidget {
  const _Credits({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _NoDeck extends StatelessWidget {
  const _NoDeck({this.filtered = false});

  /// Distingue « rien à proposer » de « vos filtres masquent tout ». Sans cette
  /// nuance, l'utilisateur croit la base vide alors qu'il a simplement plafonné
  /// son budget.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          filtered
              ? 'Aucun deck ne passe ces filtres.\n'
                    'Élargissez le budget, les couleurs, ou décochez « Constructibles ».'
              : 'Aucun deck dans ce format pour l\'instant.\n'
                    'Ajoutez des cartes à votre collection, ou changez de format.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
