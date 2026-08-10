/// Vue de la collection : ce que vous possédez, et ce que ça vaut.
///
/// **Conçu pour deux mille cartes, pas pour vingt.** À cette échelle, une liste
/// brute est inexploitable : on cherche une carte précise, on veut voir les plus
/// chères d'abord, et tout charger d'un coup serait aussi lent qu'inutile. D'où
/// le champ de recherche, le tri, et le chargement par pages au défilement.
///
/// Le bandeau de totaux vient d'un appel distinct portant sur la collection
/// entière : filtrer la liste ne doit pas faire varier le décompte affiché.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../printings/presentation/foil_decoration.dart';
import '../../printings/presentation/printing_picker.dart';
import '../data/collection_repository.dart';
import '../domain/collection_entry.dart';

class CollectionScreen extends ConsumerStatefulWidget {
  const CollectionScreen({super.key});

  @override
  ConsumerState<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends ConsumerState<CollectionScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  Timer? _debounce;

  /// Pages chargées au-delà de la première, qui vient du provider.
  final List<CollectionEntry> _extra = [];
  bool _loadingMore = false;
  bool _exhausted = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Frappe au clavier : on attend une pause avant d'interroger la base, sinon
  /// « foudre » déclencherait six requêtes dont cinq déjà obsolètes.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(collectionViewProvider.notifier).search(value);
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 400) return;
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted) return;

    final first = ref.read(collectionPageProvider).asData?.value;
    if (first == null || first.length < collectionPageSize) {
      // La première page n'est pas pleine : il n'y a rien après.
      _exhausted = true;
      return;
    }

    setState(() => _loadingMore = true);
    final view = ref.read(collectionViewProvider);
    try {
      final page = await ref
          .read(collectionRepositoryProvider)
          .page(
            query: view.query,
            sort: view.sort,
            offset: first.length + _extra.length,
          );
      if (!mounted) return;
      setState(() {
        _extra.addAll(page);
        _exhausted = page.length < collectionPageSize;
      });
    } catch (_) {
      // Un échec de page suivante laisse la liste en l'état : réessayer suffit,
      // et perdre les cartes déjà affichées serait pire que ne rien ajouter.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Les pages accumulées valent pour un filtre et un tri donnés : dès qu'ils
  /// changent, elles ne veulent plus rien dire.
  void _resetPages() {
    _extra.clear();
    _exhausted = false;
  }

  Future<void> _refresh() async {
    setState(_resetPages);
    ref.invalidate(collectionProvider);
    ref.invalidate(collectionPageProvider);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(collectionViewProvider, (_, _) => setState(_resetPages));

    final summary = ref.watch(collectionProvider);
    final page = ref.watch(collectionPageProvider);
    final view = ref.watch(collectionViewProvider);

    return summary.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Collection illisible : $error'),
        ),
      ),
      data: (totals) {
        if (totals.isEmpty) return const _EmptyCollection();

        final entries = [...?page.asData?.value, ..._extra];

        return Column(
          children: [
            _Totals(summary: totals),
            _Toolbar(
              controller: _searchController,
              sort: view.sort,
              onSearch: _onSearchChanged,
              onSort: (value) =>
                  ref.read(collectionViewProvider.notifier).sortBy(value),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: switch (page) {
                  AsyncError(:final error) => _Message('Liste illisible : $error'),
                  AsyncLoading() when entries.isEmpty => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  _ when entries.isEmpty => _Message(
                    'Aucune carte ne correspond à « ${view.query} ».',
                  ),
                  _ => ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    itemCount: entries.length + (_loadingMore ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => index >= entries.length
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : _EntryTile(entry: entries[index]),
                  ),
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Recherche et tri, sur une seule ligne.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.sort,
    required this.onSearch,
    required this.onSort,
  });

  final TextEditingController controller;
  final CollectionSort sort;
  final ValueChanged<String> onSearch;
  final ValueChanged<CollectionSort> onSort;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Chercher dans la collection',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Effacer',
                        onPressed: () {
                          controller.clear();
                          onSearch('');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<CollectionSort>(
            initialValue: sort,
            onSelected: onSort,
            tooltip: 'Trier',
            itemBuilder: (context) => [
              for (final value in CollectionSort.values)
                PopupMenuItem(value: value, child: Text(value.label)),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.sort, size: 18),
                  const SizedBox(width: 6),
                  Text(sort.label),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    // Reste défilable pour que « tirer pour rafraîchir » fonctionne même vide.
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
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
                  color: theme.colorScheme.onPrimaryContainer.withValues(
                    alpha: 0.8,
                  ),
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${summary.totalValueEur.toStringAsFixed(2)} €',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              // Une valorisation fondée sur des éditions inconnues est un plancher,
              // pas une estimation. Le dire évite de prendre le chiffre pour argent
              // comptant — sans transformer l'imprécision en reproche.
              if (summary.unspecifiedPrints > 0)
                Text(
                  'dont ${summary.unspecifiedPrints} sans édition',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer.withValues(
                      alpha: 0.8,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends ConsumerWidget {
  const _EntryTile({required this.entry});

  final CollectionEntry entry;

  /// Une modification change les totaux et peut sortir la carte de la liste
  /// (dernier exemplaire retiré) : les deux providers sont donc invalidés.
  Future<void> _change(WidgetRef ref, Future<int> Function() action) async {
    await action();
    ref.invalidate(collectionProvider);
    ref.invalidate(collectionPageProvider);
  }

  /// Change l'édition de la ligne — ou la retire, si l'on préfère ne rien dire.
  ///
  /// Déplace **tous** les exemplaires de la ligne : distinguer deux exemplaires
  /// d'une même ligne n'aurait pas de sens, ils sont indiscernables. Pour n'en
  /// préciser qu'une partie, on retire puis on rajoute.
  Future<void> _changePrinting(BuildContext context, WidgetRef ref) async {
    final chosen = await showPrintingPicker(
      context,
      oracleId: entry.oracleId,
      cardName: entry.displayName,
      currentPrintId: entry.printId,
      currentIsFoil: entry.isFoil,
      allowUnspecified: entry.hasPrinting,
    );
    if (chosen == null || !context.mounted) return;

    final target = chosen.isUnspecified ? null : chosen.printing.printId;
    if (target == entry.printId && chosen.isFoil == entry.isFoil) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(collectionRepositoryProvider)
          .setPrinting(
            entry.oracleId,
            fromPrintId: entry.printId,
            toPrintId: target,
            fromFoil: entry.isFoil,
            toFoil: chosen.isFoil,
          );
      ref.invalidate(collectionProvider);
      ref.invalidate(collectionPageProvider);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Édition non enregistrée : $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final repository = ref.read(collectionRepositoryProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: foilDecoration(theme, foil: entry.isFoil),
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
                const SizedBox(height: 2),
                _PrintingLine(
                  entry: entry,
                  onTap: () => _changePrinting(context, ref),
                ),
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
            onPressed: () => _change(
              ref,
              () => repository.remove(
                entry.oracleId,
                printId: entry.printId,
                isFoil: entry.isFoil,
              ),
            ),
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
            onPressed: () => _change(
              ref,
              () => repository.add(
                entry.oracleId,
                printId: entry.printId,
                isFoil: entry.isFoil,
              ),
            ),
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

/// L'édition d'une ligne, toujours cliquable.
///
/// Non précisée, elle invite à l'être sans le reprocher : rester vague est un
/// choix valable, seulement moins précis pour la valorisation.
class _PrintingLine extends StatelessWidget {
  const _PrintingLine({required this.entry, required this.onTap});

  final CollectionEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = entry.hasPrinting;
    final color = known
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(known ? Icons.style : Icons.style_outlined, size: 13, color: color),
            const SizedBox(width: 5),
            // Le fond irisé se voit au défilement, l'icône nomme ce qu'il
            // signifie une fois la ligne regardée. L'un sans l'autre laisserait
            // deviner.
            if (entry.isFoil) ...[
              Icon(Icons.auto_awesome, size: 13, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                '${entry.printingLabel ?? 'Édition non précisée'}${entry.isFoil ? ' · foil' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: known ? FontWeight.w600 : null,
                  decoration: known ? null : TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.dotted,
                ),
              ),
            ),
          ],
        ),
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
            Text(
              'Votre collection est vide',
              style: theme.textTheme.titleMedium,
            ),
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
