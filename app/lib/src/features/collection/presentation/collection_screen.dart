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

import '../../../config/selected_game.dart';
import '../../printings/presentation/card_art_view.dart';
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
            // Les critères de la première page valent pour les suivantes : les
            // omettre ferait défiler une collection filtrée sur une suite non
            // filtrée, et changerait de jeu en cours de liste.
            game: ref.read(selectedGameProvider),
            unspecifiedOnly: view.unspecifiedOnly,
            descending: view.descending,
            finish: view.finish,
            fullArt: view.fullArt,
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
              view: view,
              onSearch: _onSearchChanged,
              onSort: (value) =>
                  ref.read(collectionViewProvider.notifier).sortBy(value),
              onFinish: (value) =>
                  ref.read(collectionViewProvider.notifier).filterFinish(value),
              onFullArt: (value) =>
                  ref.read(collectionViewProvider.notifier).filterFullArt(value),
              // Le filtre ne s'affiche que s'il a une prise sur quelque chose :
              // sur une collection entièrement précisée, un bouton qui ne
              // renverrait jamais rien encombrerait sans rien promettre.
              unspecifiedCount: totals.unspecifiedPrints,
              unspecifiedOnly: view.unspecifiedOnly,
              onUnspecifiedOnly: (value) => ref
                  .read(collectionViewProvider.notifier)
                  .showUnspecifiedOnly(value),
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
                    switch ((view.query.isEmpty, view.unspecifiedOnly)) {
                      // Un filtre qui ne rend rien doit dire ce qu'il cherchait,
                      // sinon la collection paraît vide.
                      (true, true) =>
                        'Toutes vos cartes ont leur édition précisée.',
                      (false, true) =>
                        'Aucune carte à préciser ne correspond à '
                            '« ${view.query} ».',
                      _ => 'Aucune carte ne correspond à « ${view.query} ».',
                    },
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

/// Recherche, tri, et raccourci vers ce qui reste à préciser.
///
/// **Le filtre n'apparaît que s'il a prise sur quelque chose.** Sur une
/// collection entièrement précisée, un bouton qui ne renverrait jamais rien
/// occuperait la place sans rien promettre. Il reste en revanche affiché tant
/// qu'il est actif, sans quoi on ne pourrait plus le désactiver après avoir
/// précisé la dernière carte.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.view,
    required this.onSearch,
    required this.onSort,
    required this.onFinish,
    required this.onFullArt,
    required this.unspecifiedCount,
    required this.unspecifiedOnly,
    required this.onUnspecifiedOnly,
  });

  final TextEditingController controller;
  final CollectionView view;
  final ValueChanged<String> onSearch;
  final ValueChanged<CollectionSort> onSort;
  final ValueChanged<FinishFilter> onFinish;
  final ValueChanged<bool?> onFullArt;

  /// Exemplaires dont l'édition reste à préciser, dans la collection entière.
  final int unspecifiedCount;
  final bool unspecifiedOnly;
  final ValueChanged<bool> onUnspecifiedOnly;

  CollectionSort get sort => view.sort;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _searchRow(context),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            children: [
              if (unspecifiedCount > 0 || unspecifiedOnly) ...[
                FilterChip(
                  selected: unspecifiedOnly,
                  onSelected: onUnspecifiedOnly,
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    unspecifiedOnly ? Icons.filter_alt : Icons.style_outlined,
                    size: 17,
                  ),
                  label: Text(
                    unspecifiedCount > 0
                        ? 'À préciser · $unspecifiedCount'
                        : 'À préciser',
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // Trois états plutôt qu'une case à cocher : « toutes », « que les
              // normales », « que les brillantes ». Une case ne saurait dire la
              // deuxième, qui est pourtant celle qu'on veut en vérifiant ce
              // qu'on possède vraiment de chaque.
              for (final finish in FinishFilter.values)
                if (finish != FinishFilter.all || view.finish != FinishFilter.all) ...[
                  FilterChip(
                    label: Text(finish.label),
                    selected: view.finish == finish,
                    onSelected: (_) => onFinish(finish),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                ],
              FilterChip(
                label: const Text('Pleine illustration'),
                selected: view.fullArt == true,
                onSelected: (on) => onFullArt(on ? true : null),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _searchRow(BuildContext context) {
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
                PopupMenuItem(
                  value: value,
                  child: Row(
                    children: [
                      Expanded(child: Text(value.label)),
                      // Le critère courant montre où un second appui mènera :
                      // l'inverse de ce qui est affiché.
                      if (value == sort)
                        Icon(
                          view.descending
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          size: 16,
                        ),
                    ],
                  ),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              // La flèche dit le sens **et** l'annonce : sans elle, re-toucher
              // le critère retournerait la liste sans que rien n'explique
              // pourquoi.
              child: Row(
                children: [
                  Icon(
                    view.descending ? Icons.arrow_downward : Icons.arrow_upward,
                    size: 16,
                  ),
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

    return GestureDetector(
      // Même geste que partout ailleurs — étalement, dictée, sélecteur : on
      // maintient une ligne pour voir la carte. Ici il sert à retrouver dans une
      // liste de deux mille entrées celle qu'on a en main.
      onLongPress: () => showCardArt(
        context,
        oracleId: entry.oracleId,
        title: entry.displayName,
        printId: entry.printId,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        decoration: foilDecoration(theme, foil: entry.isFoil),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.displayName,
                          style: theme.textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Le numéro suit le nom parce que c'est ainsi qu'on range :
                      // on cherche une carte, puis sa place. Le mettre plus bas
                      // avec l'extension obligeait à descendre le regard pour la
                      // moitié de l'information dont on se sert.
                      if (entry.collectorNumber != null) ...[
                        const SizedBox(width: 8),
                        Text('#${entry.collectorNumber}', style: muted),
                      ],
                    ],
                  ),
                  if (entry.displayName != entry.name)
                    Text(
                      entry.name,
                      style: muted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 2),
                  _PrintingLine(
                    entry: entry,
                    onTap: () => _changePrinting(context, ref),
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
              width: 66,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.linePriceEur == null
                        ? '—'
                        : '${entry.linePriceEur!.toStringAsFixed(2)} €',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.titleSmall,
                  ),
                  // Le prix unitaire n'apparaît qu'en présence de plusieurs
                  // exemplaires : sur un exemplaire unique il répéterait le
                  // nombre du dessus.
                  if (entry.quantity > 1 && entry.unitPriceEur != null)
                    Text(
                      '${entry.unitPriceEur!.toStringAsFixed(2)} €/u',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
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
