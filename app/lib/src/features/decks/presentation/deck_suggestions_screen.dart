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

class DeckSuggestionsScreen extends ConsumerWidget {
  const DeckSuggestionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestions = ref.watch(deckSuggestionsProvider);

    return Column(
      children: [
        const _FormatSelector(),
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
            data: (decks) =>
                decks.isEmpty ? const _NoDeck() : _DeckList(decks: decks),
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
                    deck.isCompetitive ? 'Tournoi' : 'Accessible',
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
  const _NoDeck();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Aucun deck dans ce format pour l\'instant.\n'
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
