/// Scan d'un étalement : plusieurs cartes sur une même photo.
///
/// Distinct du scan d'une carte parce que le geste l'est : on ne cherche pas
/// *quelle* carte on tient, mais *lesquelles* sont là. Le résultat n'est donc
/// pas une proposition à départager mais une liste à valider, où l'on décoche ce
/// qui a été mal lu et où l'on ajuste les quantités.
///
/// **Aucune carte n'entre en collection sans validation** — garde-fou §IV.8. Il
/// pèse davantage ici qu'ailleurs : valider vingt cartes d'un geste rend une
/// erreur d'autant plus facile à laisser passer, et une carte saisie à tort
/// fausse ensuite toutes les suggestions de decks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../card_search/domain/card_hit.dart';
import '../../collection/data/collection_repository.dart';
import '../application/scan_service.dart';
import '../data/photo_source.dart';

/// Une carte repérée sur la photo, telle que l'utilisateur peut l'amender.
class _Spotted {
  _Spotted(this.card);

  final CardHit card;
  bool keep = true;
  int quantity = 1;
}

class SpreadScanScreen extends ConsumerStatefulWidget {
  const SpreadScanScreen({super.key});

  @override
  ConsumerState<SpreadScanScreen> createState() => _SpreadScanScreenState();
}

class _SpreadScanScreenState extends ConsumerState<SpreadScanScreen> {
  final List<_Spotted> _spotted = [];
  bool _busy = false;
  bool _saving = false;
  bool _scanned = false;
  String? _error;

  Future<void> _capture(ImageSource source) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final theme = Theme.of(context);
      final photo = await ref
          .read(photoSourceProvider)
          .capture(
            source: source,
            toolbarColor: theme.colorScheme.surfaceContainerHigh,
            toolbarWidgetColor: theme.colorScheme.onSurface,
            webContext: context,
          );
      if (photo == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final service = await ref.read(scanServiceProvider.future);
      final found = await service.recogniseSpread(photo.path);

      if (!mounted) return;
      setState(() {
        _spotted
          ..clear()
          ..addAll(found.map(_Spotted.new));
        _scanned = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAll() async {
    final kept = _spotted.where((s) => s.keep).toList();
    if (kept.isEmpty) return;

    setState(() => _saving = true);
    final repository = ref.read(collectionRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    var added = 0;
    try {
      for (final item in kept) {
        await repository.add(item.card.oracleId, quantity: item.quantity);
        added += item.quantity;
      }
      ref.invalidate(collectionProvider);
      ref.invalidate(collectionPageProvider);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('$added carte${added > 1 ? 's' : ''} ajoutée'
              '${added > 1 ? 's' : ''}'),
        ),
      );
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Enregistrement impossible : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keptCount = _spotted
        .where((s) => s.keep)
        .fold<int>(0, (sum, s) => sum + s.quantity);

    return Scaffold(
      appBar: AppBar(title: const Text('Plusieurs cartes')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Text(
                    'Photographiez vos cartes étalées, noms bien visibles. '
                    'Ce sont eux qui sont lus, pas les illustrations.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(child: _results(theme)),
                _Actions(
                  busy: _busy,
                  saving: _saving,
                  keptCount: keptCount,
                  onCapture: _capture,
                  onSave: _saveAll,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _results(ThemeData theme) {
    if (_error != null) {
      return _Note(icon: Icons.error_outline, text: _error!);
    }
    if (!_scanned) {
      return const _Note(
        icon: Icons.grid_view,
        text: 'Étalez vos cartes sans les faire se chevaucher, '
            'puis photographiez l\'ensemble.',
      );
    }
    if (_spotted.isEmpty) {
      return const _Note(
        icon: Icons.search_off,
        text: 'Aucun nom n\'a pu être lu. Rapprochez-vous, '
            'ou évitez les reflets sur les protège-cartes.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      itemCount: _spotted.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _SpottedTile(
        item: _spotted[index],
        onChanged: () => setState(() {}),
      ),
    );
  }
}

class _SpottedTile extends StatelessWidget {
  const _SpottedTile({required this.item, required this.onChanged});

  final _Spotted item;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = item.card;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: item.keep
            ? theme.colorScheme.surfaceContainerHigh
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Checkbox(
            value: item.keep,
            onChanged: (v) {
              item.keep = v ?? false;
              onChanged();
            },
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  card.matchedName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: item.keep ? null : theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (card.isLocalized)
                  Text(
                    card.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          // Les exemplaires identiques ne sont pas comptés : la lecture des noms
          // ne distingue pas deux cartes côte à côte d'un nom lu deux fois. La
          // quantité s'ajuste donc à la main.
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Un de moins',
            onPressed: item.quantity > 1
                ? () {
                    item.quantity--;
                    onChanged();
                  }
                : null,
          ),
          Text('${item.quantity}', style: theme.textTheme.titleMedium),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Un de plus',
            onPressed: () {
              item.quantity++;
              onChanged();
            },
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.busy,
    required this.saving,
    required this.keptCount,
    required this.onCapture,
    required this.onSave,
  });

  final bool busy;
  final bool saving;
  final int keptCount;
  final void Function(ImageSource) onCapture;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || saving
                      ? null
                      : () => onCapture(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Photographier'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy || saving
                      ? null
                      : () => onCapture(ImageSource.gallery),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Importer'),
                ),
              ),
            ],
          ),
          if (keptCount > 0) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: saving ? null : onSave,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: saving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.playlist_add_check),
                label: Text('Ajouter ($keptCount)'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              text,
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
