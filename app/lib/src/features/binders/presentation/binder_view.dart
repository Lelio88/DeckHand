/// La vue classeur : une étagère d'éditions, puis les cases de l'une d'elles.
///
/// **Ce qu'elle montre et qu'une liste ne montre pas, ce sont les cases vides.**
/// La liste de collection dit ce qu'on possède ; le classeur dit ce qui manque,
/// à sa place, dans l'ordre des numéros. C'est une vue de complétion d'édition,
/// et c'est ce qui la rend intéressante à regarder.
///
/// **L'entrée est une étagère, pas un classeur.** 695 éditions au catalogue :
/// ouvrir directement sur l'une d'elles supposerait de choisir laquelle, et
/// afficher les 695 donnerait 690 classeurs vides. Seules celles où quelque
/// chose est rangé figurent.
///
/// La grille est de trois par trois, comme une feuille de classeur physique, et
/// les feuilles **se tournent** — voir `page_turn.dart`. Une glissière traverse
/// le classeur d'un geste : 97 feuilles ne se parcourent pas une par une.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collection/data/collection_repository.dart';
import '../../collection/domain/collection_entry.dart' show FinishFilter;
import '../../printings/presentation/foil_decoration.dart';
import '../../printings/presentation/printing_picker.dart';
import '../data/binder_repository.dart';
import '../domain/binder.dart';
import 'page_turn.dart';
import 'shelf_tile.dart';

/// Code réservé à la pile à trier, qui n'est l'extension de personne.
///
/// Un mot plutôt qu'un booléen de plus : la pile s'ouvre et se ferme comme un
/// classeur, et tout le reste de la navigation la traite comme tel.
const String unsortedBinder = '\u0000unsorted';

/// Classeur ouvert, ou `null` quand on regarde l'étagère.
class OpenBinder extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String setCode) => state = setCode;
  void close() => state = null;
}

final openBinderProvider = NotifierProvider<OpenBinder, String?>(OpenBinder.new);

/// Page courante du classeur ouvert, à partir de 1.
class BinderPageNumber extends Notifier<int> {
  @override
  int build() => 1;

  void set(int page) => state = page < 1 ? 1 : page;
}

final binderPageNumberProvider =
    NotifierProvider<BinderPageNumber, int>(BinderPageNumber.new);

class BinderView extends ConsumerWidget {
  const BinderView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(openBinderProvider);
    if (open == null) return const _Shelf();
    if (open == unsortedBinder) return const _UnsortedPile();
    return _Binder(setCode: open);
  }
}

/// Champ de recherche de l'étagère.
///
/// **Chercher une carte est la seule chose qu'une liste faisait mieux qu'un
/// classeur.** L'ordre des numéros ne répond pas à « où est ma Foudre ? » : il
/// faudrait connaître l'extension et tourner les feuilles. Le résultat porte
/// donc la page, et y mène.
class _ShelfSearch extends ConsumerStatefulWidget {
  const _ShelfSearch();

  @override
  ConsumerState<_ShelfSearch> createState() => _ShelfSearchState();
}

class _ShelfSearchState extends ConsumerState<_ShelfSearch> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // Une requête par frappe interrogerait le serveur dix fois pour un nom.
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(binderQueryProvider.notifier).set(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: TextField(
        controller: _controller,
        onChanged: _onChanged,
        decoration: InputDecoration(
          hintText: 'Chercher une carte dans mes classeurs',
          prefixIcon: const Icon(Icons.search, size: 20),
          isDense: true,
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _controller.clear();
                    ref.read(binderQueryProvider.notifier).set('');
                    setState(() {});
                  },
                ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}

/// Les cartes trouvées, avec la feuille où les prendre.
class _FindResults extends ConsumerWidget {
  const _FindResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final found = ref.watch(binderFindProvider);

    return found.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => _Message(
        icon: Icons.cloud_off,
        title: 'Recherche impossible',
        detail: '$error',
        onRetry: () => ref.invalidate(binderFindProvider),
      ),
      data: (results) {
        if (results.isEmpty) {
          return const _Message(
            icon: Icons.search_off,
            title: 'Aucune carte rangée sous ce nom',
            // Chercher dans un classeur, c'est chercher parmi ses cartes : ne
            // pas trouver ne veut pas dire que la carte n'existe pas.
            detail: 'La recherche ne porte que sur vos classeurs.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: results.length,
          itemBuilder: (context, i) {
            final hit = results[i];
            return ListTile(
              dense: true,
              onTap: () {
                ref.read(binderPageNumberProvider.notifier).set(hit.page);
                ref.read(openBinderProvider.notifier).open(hit.setCode);
              },
              title: Text(
                hit.shownName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${hit.setName ?? hit.setCode.toUpperCase()} · '
                '#${hit.collectorNumber} · page ${hit.page}'
                '${hit.owned > 1 ? ' · ×${hit.owned}' : ''}',
                style: theme.textTheme.bodySmall,
              ),
              trailing: const Icon(Icons.chevron_right),
            );
          },
        );
      },
    );
  }
}

/// Les éditions dont on possède au moins une carte.
class _Shelf extends ConsumerWidget {
  const _Shelf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelf = ref.watch(binderShelfProvider);
    final query = ref.watch(binderQueryProvider);

    if (query.isNotEmpty) {
      return const Column(
        children: [
          _ShelfSearch(),
          Expanded(child: _FindResults()),
        ],
      );
    }

    return shelf.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => _Message(
        icon: Icons.cloud_off,
        title: 'Étagère illisible',
        detail: '$error',
        onRetry: () => ref.invalidate(binderShelfProvider),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const _Message(
            icon: Icons.inbox_outlined,
            title: 'Aucun classeur',
            // Une carte sans édition précisée n'a pas de case : elle n'est
            // rangeable nulle part. Le classeur étant la vue par défaut, il
            // doit dire où sont passées les cartes plutôt que de laisser
            // croire à une collection vide — et indiquer la sortie.
            detail:
                'Un classeur est une édition, et vos cartes n\'en ont pas encore. '
                'La vue Liste les montre toutes, et permet de préciser leur '
                'édition pour qu\'elles trouvent leur case.',
          );
        }
        return Column(
          children: [
            const _ShelfSearch(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: entries.length + 1,
                // La pile à trier ouvre l'étagère plutôt que de la clore :
                // c'est le travail en cours, et ce qu'on range aujourd'hui
                // remplira les classeurs demain.
                itemBuilder: (context, i) {
                  if (i == 0) return const _UnsortedTile();
                  final entry = entries[i - 1];
                  return ShelfTile(
                    entry: entry,
                    onOpen: () {
                      ref.read(binderPageNumberProvider.notifier).set(1);
                      ref.read(openBinderProvider.notifier).open(entry.setCode);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// L'entrée « À trier », en tête de l'étagère.
///
/// Elle ne s'affiche que s'il y a quelque chose à trier : sur une collection
/// entièrement précisée, une pile vide n'apprendrait rien et occuperait la
/// première place.
class _UnsortedTile extends ConsumerWidget {
  const _UnsortedTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final waiting = ref.watch(collectionProvider).asData?.value.unspecifiedPrints ?? 0;
    if (waiting == 0) return const SizedBox.shrink();

    return ListTile(
      onTap: () {
        ref.read(binderPageNumberProvider.notifier).set(1);
        ref.read(openBinderProvider.notifier).open(unsortedBinder);
      },
      leading: Icon(Icons.inbox_outlined, color: theme.colorScheme.primary),
      title: const Text('À trier'),
      subtitle: Text(
        '$waiting exemplaire${waiting > 1 ? 's' : ''} sans édition — '
        'rangeables nulle part tant qu\'on n\'a pas dit lesquels',
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

/// La pile des cartes sans édition.
///
/// **Ni cases ni numéros** : ces cartes n'ont pas de place. On les montre pour
/// pouvoir leur en donner une — toucher une carte ouvre le sélecteur d'édition,
/// et la pile se vide à mesure qu'on range.
class _UnsortedPile extends ConsumerWidget {
  const _UnsortedPile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final page = ref.watch(binderPageNumberProvider);
    final cards = ref.watch(unsortedPileProvider(page));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Retour à l\'étagère',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => ref.read(openBinderProvider.notifier).close(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('À trier', style: theme.textTheme.titleSmall),
                    Text(
                      'Touchez une carte pour lui donner son édition',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Page précédente',
                icon: const Icon(Icons.chevron_left),
                onPressed: page <= 1
                    ? null
                    : () =>
                          ref.read(binderPageNumberProvider.notifier).set(page - 1),
              ),
              IconButton(
                tooltip: 'Page suivante',
                icon: const Icon(Icons.chevron_right),
                onPressed: (cards.asData?.value.length ?? 0) < binderPageSize
                    ? null
                    : () =>
                          ref.read(binderPageNumberProvider.notifier).set(page + 1),
              ),
            ],
          ),
        ),
        Expanded(
          child: cards.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (error, _) => _Message(
              icon: Icons.cloud_off,
              title: 'Pile illisible',
              detail: '$error',
              onRetry: () => ref.invalidate(unsortedPileProvider),
            ),
            data: (list) => list.isEmpty
                ? const _Message(
                    icon: Icons.check_circle_outline,
                    title: 'Rien à trier',
                    detail: 'Toutes vos cartes ont trouvé leur case.',
                  )
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: GridView.count(
                      crossAxisCount: 3,
                      childAspectRatio: 0.72,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [
                        for (final card in list) _UnsortedCardTile(card: card),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _UnsortedCardTile extends ConsumerWidget {
  const _UnsortedCardTile({required this.card});

  final UnsortedCard card;

  Future<void> _sort(BuildContext context, WidgetRef ref) async {
    final chosen = await showPrintingPicker(
      context,
      oracleId: card.oracleId,
      cardName: card.shownName,
    );
    if (chosen == null || chosen.isUnspecified) return;

    // Le même geste que dans la liste : « ces exemplaires-là sont de cette
    // édition ». Rien n'est ajouté, tout est déplacé.
    await ref
        .read(collectionRepositoryProvider)
        .setPrinting(
          card.oracleId,
          toPrintId: chosen.printing.printId,
          toFoil: chosen.isFoil,
        );

    // La carte quitte la pile et rejoint une case : les trois vues changent.
    ref.invalidate(unsortedPileProvider);
    ref.invalidate(binderShelfProvider);
    ref.invalidate(collectionProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(8);
    final image = card.imageUrl;

    return InkWell(
      onTap: () => _sort(context, ref),
      borderRadius: radius,
      child: ClipRRect(
        borderRadius: radius,
        child: FoilSheen(
          foil: card.hasFoil,
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (image == null)
                ColoredBox(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        card.shownName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                )
              else
                Image.network(
                  image,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerLow,
                    child: Center(
                      child: Text(
                        card.shownName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
              if (card.owned > 1)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      child: Text(
                        '×${card.owned}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Une page de classeur : trois cases sur trois, dans l'ordre des numéros.
class _Binder extends ConsumerWidget {
  const _Binder({required this.setCode});

  final String setCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(binderPageNumberProvider);
    final reading = ref.watch(binderReadingProvider);
    final cells = ref.watch(
      binderPageProvider((
        setCode: setCode,
        page: page,
        sort: reading.sort,
        finish: reading.finish,
        descending: reading.descending,
      )),
    );
    final entry = ref
        .watch(binderShelfProvider)
        .asData
        ?.value
        .where((e) => e.setCode == setCode)
        .firstOrNull;

    final pages = entry?.pages ?? 1;

    // **Seules les feuilles voisines sont préchargées.** Une feuille pèse neuf
    // cartes entières ; en précharger davantage rapatrierait un classeur entier
    // pour en montrer un neuvième. Le `watch` suffit à déclencher la requête et
    // à la garder en cache le temps qu'on reste sur ce classeur.
    for (final neighbour in [page - 1, page + 1]) {
      if (neighbour >= 1 && neighbour <= pages) {
        ref.watch(
          binderPageProvider((
            setCode: setCode,
            page: neighbour,
            sort: reading.sort,
            finish: reading.finish,
            descending: reading.descending,
          )),
        );
      }
    }

    return Column(
      children: [
        _BinderHeader(entry: entry, setCode: setCode, page: page),
        _ReadingSelector(setCode: setCode),
        Expanded(
          child: cells.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (error, _) => _Message(
              icon: Icons.cloud_off,
              title: 'Page illisible',
              detail: '$error',
              onRetry: () => ref.invalidate(binderPageProvider),
            ),
            data: (list) => list.isEmpty
                ? const _Message(
                    icon: Icons.menu_book_outlined,
                    title: 'Page vide',
                    detail: 'Ce classeur n\'a pas de page à cet endroit.',
                  )
                : PageTurner(
                    page: page,
                    pageCount: pages,
                    onTurned: (p) =>
                        ref.read(binderPageNumberProvider.notifier).set(p),
                    builder: (context, p) => _PageFace(
                      setCode: setCode,
                      page: p,
                      reading: reading,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// Une face de feuille : neuf cases, pochettes visibles.
///
/// Isolée du reste pour que le retournement puisse en construire deux — la
/// feuille qui pivote et celle qu'on découvre dessous — sans dupliquer la
/// grille ni son chargement.
class _PageFace extends ConsumerWidget {
  const _PageFace({
    required this.setCode,
    required this.page,
    required this.reading,
  });

  final String setCode;
  final int page;
  final BinderReading reading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cells = ref.watch(
      binderPageProvider((
        setCode: setCode,
        page: page,
        sort: reading.sort,
        finish: reading.finish,
        descending: reading.descending,
      )),
    );

    return DecoratedBox(
      // La feuille a sa propre teinte : sans fond opaque, on verrait par
      // transparence la page du dessous pendant le retournement.
      decoration: BoxDecoration(color: theme.colorScheme.surface),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: cells.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          // **La feuille entière doit tenir à l'écran.** Un rapport figé à
          // 0,72 — la proportion d'une carte — débordait en hauteur : la
          // troisième rangée sortait du cadre. Une feuille de classeur ne
          // défile pas, elle se tourne ; c'est donc la grille qui s'adapte,
          // quitte à laisser un peu d'air sur les côtés.
          data: (list) => LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final cellWidth = (constraints.maxWidth - spacing * 2) / 3;
              final cellHeight = (constraints.maxHeight - spacing * 2) / 3;
              // Jamais plus large qu'une carte : au-delà, l'image serait
              // rognée sur les côtés au lieu de l'être en bas.
              final ratio = (cellWidth / cellHeight).clamp(0.0, 0.716);

              return GridView.count(
                crossAxisCount: 3,
                childAspectRatio: ratio,
                mainAxisSpacing: spacing,
                crossAxisSpacing: spacing,
                // Un défilement vertical intercepterait le geste horizontal du
                // retournement.
                physics: const NeverScrollableScrollPhysics(),
                children: [for (final cell in list) _Cell(cell: cell)],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Demande une feuille et s'y rend.
///
/// La glissière permanente coûtait la hauteur d'une rangée de cartes pour un
/// geste rare : on feuillette de proche en proche, on ne saute d'un bout à
/// l'autre qu'en cherchant quelque chose de précis.
Future<void> _askPage(
  BuildContext context,
  WidgetRef ref, {
  required int page,
  required int pages,
}) async {
  var chosen = page.toDouble();
  final target = await showModalBottomSheet<int>(
    context: context,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Aller à la page ${chosen.round()}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Slider(
                value: chosen,
                min: 1,
                max: pages.toDouble(),
                divisions: pages > 1 ? pages - 1 : null,
                label: 'Page ${chosen.round()}',
                onChanged: (v) => setSheetState(() => chosen = v),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(chosen.round()),
                child: const Text('Y aller'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  if (target != null) {
    ref.read(binderPageNumberProvider.notifier).set(target);
  }
}

/// Ordre de lecture et finition retenue.
///
/// **Changer de lecture ramène à une page qui a quelque chose à montrer.** Un
/// filtre serré laisse des feuilles entièrement creuses — sur 97 feuilles dont
/// douze cartes, ouvrir à la première serait ouvrir sur du vide. Le serveur dit
/// où commencer ; hors du rangement, les cases vides ayant disparu, la première
/// page est toujours pleine et la question ne se pose pas.
class _ReadingSelector extends ConsumerWidget {
  const _ReadingSelector({required this.setCode});

  final String setCode;

  Future<void> _jumpToFirstFilled(WidgetRef ref, FinishFilter finish) async {
    final page = await ref
        .read(binderRepositoryProvider)
        .firstPage(setCode, finish: finish);
    ref.read(binderPageNumberProvider.notifier).set(page);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading = ref.watch(binderReadingProvider);

    // **Deux menus plutôt que six puces.** Les puces occupaient une ligne
    // entière et débordaient de l'écran — il fallait faire défiler pour
    // atteindre « Brillantes ». La hauteur ainsi rendue va aux cartes, qui
    // étaient coupées en bas de page.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<BinderSort>(
              initialValue: reading.sort,
              isDense: true,
              decoration: _dense(
                context,
                reading.descending ? Icons.arrow_upward : Icons.arrow_downward,
              ),
              // **Re-choisir un critère renverse le classeur.** C'est le geste
              // de l'ancienne liste, perdu en passant aux menus : le libellé de
              // l'entrée déjà choisie annonce donc ce qu'un second appui fera —
              // « Dernière page d'abord », « Les moins chères d'abord »,
              // « De Z à A » — plutôt que de laisser croire à un choix inerte.
              items: [
                for (final sort in BinderSort.values)
                  DropdownMenuItem(
                    value: sort,
                    child: Text(
                      sort == reading.sort && !reading.descending
                          ? '${sort.label} — ${sort.reversedLabel}'
                          : sort.label,
                    ),
                  ),
              ],
              // Le champ fermé ne montre que le critère : la phrase du menu y
              // déborderait, et n'a de sens qu'au moment de choisir.
              selectedItemBuilder: (context) => [
                for (final sort in BinderSort.values)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(sort.label),
                  ),
              ],
              onChanged: (sort) {
                if (sort == null) return;
                ref.read(binderReadingProvider.notifier).sortBy(sort);
                // Le numéro de page d'un ordre n'a aucun sens dans un autre :
                // la page 42 par numéro n'est pas la page 42 par valeur.
                ref.read(binderPageNumberProvider.notifier).set(1);
                if (sort.keepsEmptyCells) {
                  unawaited(_jumpToFirstFilled(ref, reading.finish));
                }
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonFormField<FinishFilter>(
              initialValue: reading.finish,
              isDense: true,
              decoration: _dense(context, Icons.auto_awesome_outlined),
              items: [
                for (final finish in FinishFilter.values)
                  DropdownMenuItem(value: finish, child: Text(finish.label)),
              ],
              onChanged: (finish) {
                if (finish == null) return;
                ref.read(binderReadingProvider.notifier).filter(finish);
                ref.read(binderPageNumberProvider.notifier).set(1);
                if (reading.sort.keepsEmptyCells) {
                  unawaited(_jumpToFirstFilled(ref, finish));
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _dense(BuildContext context, IconData icon) =>
      InputDecoration(
        isDense: true,
        prefixIcon: Icon(icon, size: 18),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );
}

class _BinderHeader extends ConsumerWidget {
  const _BinderHeader({
    required this.entry,
    required this.setCode,
    required this.page,
  });

  final BinderShelfEntry? entry;
  final String setCode;
  final int page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pages = entry?.pages ?? 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Retour à l\'étagère',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => ref.read(openBinderProvider.notifier).close(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry?.setName ?? setCode.toUpperCase(),
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // **Le saut de page vit ici depuis que la glissière a disparu.**
                // Elle mangeait la hauteur d'une rangée de cartes ; traverser
                // 51 feuilles reste possible, mais à la demande.
                InkWell(
                  onTap: pages <= 1
                      ? null
                      : () => _askPage(context, ref, page: page, pages: pages),
                  child: Text(
                    pages > 1
                        ? 'Page $page sur $pages  ›'
                        : 'Page $page sur $pages',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: pages > 1
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Page précédente',
            icon: const Icon(Icons.chevron_left),
            onPressed: page <= 1
                ? null
                : () => ref.read(binderPageNumberProvider.notifier).set(page - 1),
          ),
          IconButton(
            tooltip: 'Page suivante',
            icon: const Icon(Icons.chevron_right),
            onPressed: page >= pages
                ? null
                : () => ref.read(binderPageNumberProvider.notifier).set(page + 1),
          ),
        ],
      ),
    );
  }
}

/// Une case : la carte qu'on y range, ou le creux qu'elle laisse.
///
/// **La carte entière, et non son illustration.** Une case de classeur contient
/// une carte — son cadre, son nom, son coût, son numéro. N'en montrer que
/// l'illustration donnait une planche-contact, jolie mais impossible à
/// reconnaître comme sa propre collection. Le nom imprimé devient illisible à
/// trois par ligne, exactement comme dans un vrai classeur qu'on regarde de
/// loin : c'est l'image qu'on reconnaît, pas le texte qu'on lit.
class _Cell extends StatelessWidget {
  const _Cell({required this.cell});

  final BinderCell cell;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = cell.isEmpty;
    final radius = BorderRadius.circular(8);
    final image = cell.imageUrl;

    if (empty || image == null) {
      // Une case vide se lit comme telle : creusée, sans image, et portant son
      // numéro — c'est ce qui manque, et il faut savoir quoi exactement.
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.35,
          ),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Center(
          child: Text(
            '#${cell.collectorNumber}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => showCellActions(context, cell),
      // **L'appui long montre la carte en grand.** À trois par ligne, le texte
      // imprimé est illisible — c'est assumé, on reconnaît l'image — mais lire
      // une carte reste parfois nécessaire, et rien ne le permettait.
      onLongPress: () => showCardInFull(context, image, cell.shownName, cell.hasFoil),
      borderRadius: radius,
      child: ClipRRect(
        borderRadius: radius,
        child: FoilSheen(
          foil: cell.hasFoil,
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                image,
                fit: BoxFit.cover,
                // Le cadre reste visible pendant le chargement : sans lui, la
                // grille se recompose sous les yeux à chaque page tournée.
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : ColoredBox(color: theme.colorScheme.surfaceContainerLow),
                errorBuilder: (_, _, _) => ColoredBox(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Center(
                    child: Text(
                      '#${cell.collectorNumber}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
              // Les doublons se comptent sur la case, pas à côté : un
              // exemplaire de plus ne prend pas de place dans un classeur, il
              // s'empile derrière le premier.
              if (cell.owned > 1)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      child: Text(
                        '×${cell.owned}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La carte en grand, telle qu'on la sortirait de sa pochette.
///
/// **Le reflet suit la carte.** Une brillante vue en grand doit l'être aussi :
/// c'est le moment où l'on regarde vraiment l'exemplaire qu'on possède.
Future<void> showCardInFull(
  BuildContext context,
  String imageUrl,
  String name,
  bool foil,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Colors.transparent,
      child: GestureDetector(
        // N'importe où hors de la carte referme : une croix prendrait de la
        // place sur ce qu'on est venu regarder.
        onTap: () => Navigator.of(context).pop(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // **Le cadre épouse la carte, pas l'écran.** Sans rapport imposé,
            // le reflet des brillantes couvrait toute la boîte de dialogue —
            // la carte était au milieu d'un rectangle irisé. Une carte fait
            // 63 × 88 mm : c'est cette proportion qui borne le reflet.
            Flexible(
              child: AspectRatio(
                aspectRatio: 63 / 88,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: FoilSheen(
                    foil: foil,
                    borderRadius: BorderRadius.circular(14),
                    child: Image.network(imageUrl, fit: BoxFit.cover),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              name,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Ce qu'on peut faire d'une carte rangée.
///
/// **Ces gestes vivaient dans la liste**, qui n'existe plus : ajouter un
/// exemplaire, en retirer un, corriger l'édition. Les perdre en supprimant la
/// liste aurait été une régression déguisée en simplification — le retrait,
/// notamment, n'existe nulle part ailleurs.
Future<void> showCellActions(BuildContext context, BinderCell cell) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) => _CellActions(cell: cell),
  );
}

class _CellActions extends ConsumerStatefulWidget {
  const _CellActions({required this.cell});

  final BinderCell cell;

  @override
  ConsumerState<_CellActions> createState() => _CellActionsState();
}

class _CellActionsState extends ConsumerState<_CellActions> {
  /// Finition sur laquelle portent les actions.
  ///
  /// **Une case ne dit pas de quelle finition on veut ajouter un exemplaire.**
  /// Elle signale ce qu'elle contient — un brillant, ou non — mais on peut très
  /// bien tenir en main l'autre version : elles se rangent dans la même case et
  /// ne valent pas le même prix. Le choix part donc de ce qui est déjà rangé,
  /// et se change.
  late bool _foil = widget.cell.hasFoil;

  BinderCell get cell => widget.cell;

  void _refresh(WidgetRef ref) {
    ref.invalidate(binderPageProvider);
    ref.invalidate(binderShelfProvider);
    ref.invalidate(collectionProvider);
    ref.invalidate(binderFindProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final oracleId = cell.oracleId;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(cell.shownName, style: theme.textTheme.titleMedium),
                      Text(
                        '#${cell.collectorNumber} · ${cell.owned} exemplaire'
                        '${cell.owned > 1 ? 's' : ''}'
                        '${cell.hasFoil ? ' · brillant' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // **Le prix suit la finition qu'on s'apprête à ajouter.** Le
                // brillant vaut couramment le double ou le triple de sa jumelle
                // mate ; afficher l'un pour l'autre tromperait sur la valeur de
                // ce qu'on range. Un tiret dit l'absence de cote — un zéro
                // ferait croire à une carte sans valeur.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      switch (cell.priceFor(foil: _foil)) {
                        final price? => '${price.toStringAsFixed(2)} €',
                        _ => '—',
                      },
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      _foil ? 'brillante' : 'normale',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // **La finition se choisit avant d'agir.** Une case dit ce qu'elle
          // contient, pas ce qu'on tient en main : on peut posséder la version
          // normale et vouloir ajouter la brillante, qui se range dans la même
          // case mais ne vaut pas le même prix. Sans ce choix, il n'y avait
          // aucun moyen d'ajouter l'autre finition depuis le classeur.
          if (oracleId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Normale')),
                  ButtonSegment(value: true, label: Text('Brillante')),
                ],
                selected: {_foil},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _foil = v.first),
              ),
            ),
          const Divider(height: 16),
          if (oracleId != null) ...[
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(
                _foil
                    ? 'Ajouter un exemplaire brillant'
                    : 'Ajouter un exemplaire normal',
              ),
              onTap: () async {
                final navigator = Navigator.of(context);
                await ref
                    .read(collectionRepositoryProvider)
                    .add(oracleId, printId: cell.printId, isFoil: _foil);
                _refresh(ref);
                navigator.pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.remove),
              title: Text(
                _foil
                    ? 'Retirer un exemplaire brillant'
                    : 'Retirer un exemplaire normal',
              ),
              onTap: () async {
                final navigator = Navigator.of(context);
                await ref
                    .read(collectionRepositoryProvider)
                    .remove(oracleId, printId: cell.printId, isFoil: _foil);
                _refresh(ref);
                navigator.pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.style_outlined),
              title: const Text('Corriger l\'édition'),
              subtitle: const Text('Si ce n\'est pas celle que vous tenez'),
              onTap: () async {
                final navigator = Navigator.of(context);
                final chosen = await showPrintingPicker(
                  context,
                  oracleId: oracleId,
                  cardName: cell.shownName,
                  currentPrintId: cell.printId,
                  currentIsFoil: _foil,
                );
                if (chosen == null || chosen.isUnspecified) {
                  navigator.pop();
                  return;
                }
                await ref
                    .read(collectionRepositoryProvider)
                    .setPrinting(
                      oracleId,
                      fromPrintId: cell.printId,
                      toPrintId: chosen.printing.printId,
                      fromFoil: _foil,
                      toFoil: chosen.isFoil,
                    );
                _refresh(ref);
                navigator.pop();
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String? detail;

  /// Ce qu'il faut refaire pour s'en sortir, quand il y a quelque chose à
  /// refaire. **Une panne de réseau n'est pas un état définitif** : sans ce
  /// bouton, il ne resterait qu'à quitter l'application pour retenter.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleSmall),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Réessayer'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
