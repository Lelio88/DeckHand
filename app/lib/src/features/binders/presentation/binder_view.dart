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
/// La grille est de trois par trois, comme une feuille de classeur physique. Le
/// rendu reste sobre : le volume, les pages qui se tournent et le reflet des
/// brillants relèvent d'un autre chantier, et une belle animation qui saccade
/// serait pire qu'une transition sobre.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/binder_repository.dart';
import '../domain/binder.dart';

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
    return open == null ? const _Shelf() : _Binder(setCode: open);
  }
}

/// Les éditions dont on possède au moins une carte.
class _Shelf extends ConsumerWidget {
  const _Shelf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelf = ref.watch(binderShelfProvider);

    return shelf.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => _Message(
        icon: Icons.cloud_off,
        title: 'Étagère illisible',
        detail: '$error',
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const _Message(
            icon: Icons.inbox_outlined,
            title: 'Aucun classeur',
            // Une carte sans édition précisée n'a pas de case : elle n'est
            // rangeable nulle part. Le dire ici évite de laisser croire à une
            // collection vide.
            detail:
                'Un classeur est une édition. Précisez l\'édition de vos cartes '
                'pour qu\'elles trouvent leur case.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: entries.length,
          itemBuilder: (context, i) => _ShelfTile(entry: entries[i]),
        );
      },
    );
  }
}

class _ShelfTile extends ConsumerWidget {
  const _ShelfTile({required this.entry});

  final BinderShelfEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final percent = (entry.completion * 100).toStringAsFixed(
      entry.completion < 0.1 ? 1 : 0,
    );

    return ListTile(
      onTap: () {
        ref.read(binderPageNumberProvider.notifier).set(1);
        ref.read(openBinderProvider.notifier).open(entry.setCode);
      },
      title: Text(
        entry.setName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            '${entry.setCode.toUpperCase()} · '
            '${entry.ownedCells} / ${entry.totalCells} cases · '
            '${entry.pages} pages',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          // La barre dit d'un coup d'œil ce que le rapport chiffré demande de
          // calculer — c'est le taux de complétion qui fait regarder un
          // classeur, pas le nombre de cartes.
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: entry.completion,
              minHeight: 5,
            ),
          ),
        ],
      ),
      trailing: Text('$percent %', style: theme.textTheme.titleSmall),
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
    final cells = ref.watch(
      binderPageProvider((setCode: setCode, page: page)),
    );
    final entry = ref
        .watch(binderShelfProvider)
        .asData
        ?.value
        .where((e) => e.setCode == setCode)
        .firstOrNull;

    return Column(
      children: [
        _BinderHeader(entry: entry, setCode: setCode, page: page),
        Expanded(
          child: cells.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (error, _) => _Message(
              icon: Icons.cloud_off,
              title: 'Page illisible',
              detail: '$error',
            ),
            data: (list) => list.isEmpty
                ? const _Message(
                    icon: Icons.menu_book_outlined,
                    title: 'Page vide',
                    detail: 'Ce classeur n\'a pas de page à cet endroit.',
                  )
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: GridView.count(
                      crossAxisCount: 3,
                      childAspectRatio: 0.72,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [for (final cell in list) _Cell(cell: cell)],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
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
                Text(
                  'Page $page sur $pages',
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
class _Cell extends StatelessWidget {
  const _Cell({required this.cell});

  final BinderCell cell;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = cell.isEmpty;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        // Une case vide se lit comme telle : creusée, sans illustration, avec
        // son numéro pour qu'on sache ce qui manque exactement.
        color: empty
            ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4)
            : theme.colorScheme.surfaceContainerLow,
        border: Border.all(
          color: empty
              ? theme.colorScheme.outlineVariant
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          style: empty ? BorderStyle.solid : BorderStyle.solid,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: empty || cell.artCropUrl == null
                ? Center(
                    child: Text(
                      '#${cell.collectorNumber}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : Image.network(
                    cell.artCropUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  empty ? '—' : cell.shownName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: empty ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
                Row(
                  children: [
                    Text(
                      '#${cell.collectorNumber}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    // Le brillant ne prend pas de case à lui : il se signale
                    // sur celle qu'il occupe.
                    if (cell.hasFoil)
                      Icon(
                        Icons.auto_awesome,
                        size: 11,
                        color: theme.colorScheme.primary,
                      ),
                    if (cell.owned > 1)
                      Text(
                        ' ×${cell.owned}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, this.detail});

  final IconData icon;
  final String title;
  final String? detail;

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
          ],
        ),
      ),
    );
  }
}
