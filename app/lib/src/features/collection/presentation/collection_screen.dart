/// Vue de la collection : ce que vous possédez, et ce que ça vaut.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/collection_repository.dart';
import '../domain/collection_entry.dart';

class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(collectionProvider);

    return collection.when(
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Collection illisible : $error'),
        ),
      ),
      data: (summary) => summary.isEmpty
          ? const _EmptyCollection()
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(collectionProvider),
              child: Column(
                children: [
                  _Totals(summary: summary),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                      itemCount: summary.entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _EntryTile(entry: summary.entries[index]),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.summary});

  final CollectionSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${summary.totalCards} carte${summary.totalCards > 1 ? 's' : ''}',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              Text(
                '${summary.distinctCards} référence${summary.distinctCards > 1 ? 's' : ''} distincte${summary.distinctCards > 1 ? 's' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
          Text(
            '${summary.totalValueEur.toStringAsFixed(2)} €',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends ConsumerWidget {
  const _EntryTile({required this.entry});

  final CollectionEntry entry;

  Future<void> _remove(WidgetRef ref) async {
    await ref.read(collectionRepositoryProvider).remove(entry.oracleId);
    ref.invalidate(collectionProvider);
  }

  Future<void> _add(WidgetRef ref) async {
    await ref.read(collectionRepositoryProvider).add(entry.oracleId);
    ref.invalidate(collectionProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayName,
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.displayName != entry.name)
                  Text(entry.name, style: muted, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(
                  entry.unitPriceEur == null
                      ? 'Prix inconnu'
                      : '${entry.unitPriceEur!.toStringAsFixed(2)} € l\'unité',
                  style: muted,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Retirer un exemplaire',
            onPressed: () => _remove(ref),
          ),
          SizedBox(
            width: 28,
            child: Text(
              '${entry.quantity}',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Ajouter un exemplaire',
            onPressed: () => _add(ref),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 62,
            child: Text(
              entry.linePriceEur == null
                  ? '—'
                  : '${entry.linePriceEur!.toStringAsFixed(2)} €',
              textAlign: TextAlign.right,
              style: theme.textTheme.titleSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyCollection extends StatelessWidget {
  const _EmptyCollection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.style_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('Votre collection est vide', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Cherchez une carte et ajoutez-la pour commencer.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
