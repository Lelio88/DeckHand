/// Écran de scan : photographier une carte pour l'ajouter à sa collection.
///
/// **Rien n'est ajouté sans confirmation.** La reconnaissance propose, elle ne
/// décide pas — garde-fou §IV.8 du CLAUDE.md. Une carte enregistrée à tort
/// fausserait ensuite toutes les suggestions de decks, ce qui est bien pire
/// qu'une reconnaissance ratée.
///
/// Quand la confiance est faible, les candidats restent affichés mais le ton
/// change : on suggère au lieu d'affirmer, et l'utilisateur tranche.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../card_search/data/card_repository.dart';
import '../../card_search/domain/card_hit.dart';
import '../../collection/data/collection_repository.dart';
import '../application/scan_service.dart';
import '../data/art_index_repository.dart';
import '../data/photo_source.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  ScanOutcome? _outcome;
  List<CardHit> _details = const [];
  bool _busy = false;
  String? _error;

  Future<void> _capture(ImageSource source) async {
    setState(() {
      _busy = true;
      _error = null;
      _outcome = null;
      _details = const [];
    });

    try {
      final theme = Theme.of(context);
      final bytes = await ref
          .read(photoSourceProvider)
          .capture(
            source: source,
            toolbarColor: theme.colorScheme.surfaceContainerHigh,
            toolbarWidgetColor: theme.colorScheme.onSurface,
            webContext: context,
          );
      // Abandon à la prise de vue ou au recadrage : rien à signaler.
      if (bytes == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final service = await ref.read(scanServiceProvider.future);
      final outcome = service.recognise(bytes);

      final details = outcome.candidates.isEmpty
          ? <CardHit>[]
          : await ref
                .read(cardRepositoryProvider)
                .byOracleIds(
                  outcome.candidates.map((c) => c.oracleId).toList(),
                );

      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _details = details;
        _error = outcome.error;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add(CardHit card) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final total = await ref
          .read(collectionRepositoryProvider)
          .add(card.oracleId);
      ref.invalidate(collectionProvider);
      ref.invalidate(collectionPageProvider);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('${card.matchedName} ajoutée — vous en avez $total'),
          duration: const Duration(seconds: 2),
        ),
      );
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Ajout impossible : $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(artHashIndexProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Scanner une carte')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: index.when(
              loading: () => const _LoadingIndex(),
              error: (e, _) => _Message(
                icon: Icons.cloud_off,
                title: 'Index indisponible',
                detail: '$e',
              ),
              data: (loaded) => _Body(
                indexSize: loaded.length,
                busy: _busy,
                error: _error,
                outcome: _outcome,
                details: _details,
                onCapture: _capture,
                onAdd: _add,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.indexSize,
    required this.busy,
    required this.error,
    required this.outcome,
    required this.details,
    required this.onCapture,
    required this.onAdd,
  });

  final int indexSize;
  final bool busy;
  final String? error;
  final ScanOutcome? outcome;
  final List<CardHit> details;
  final void Function(ImageSource) onCapture;
  final void Function(CardHit) onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cadrez la carte pour qu\'elle remplisse la hauteur de l\'image.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '$indexSize illustrations connues',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => onCapture(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera),
                      label: const Text('Photographier'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => onCapture(ImageSource.gallery),
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Importer'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _Result(
            error: error,
            outcome: outcome,
            details: details,
            onAdd: onAdd,
          ),
        ),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.error,
    required this.outcome,
    required this.details,
    required this.onAdd,
  });

  final String? error;
  final ScanOutcome? outcome;
  final List<CardHit> details;
  final void Function(CardHit) onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (error != null) {
      return _Message(
        icon: Icons.error_outline,
        title: 'Reconnaissance impossible',
        detail: error!,
      );
    }
    if (outcome == null) {
      return const _Message(
        icon: Icons.crop_free,
        title: 'Aucune carte scannée',
        detail: 'Photographiez une carte ou importez une image pour commencer.',
      );
    }
    if (details.isEmpty) {
      return const _Message(
        icon: Icons.search_off,
        title: 'Carte non reconnue',
        detail:
            'Réessayez avec un meilleur éclairage, ou ajoutez-la par son nom.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        // La nuance porte tout le sens : « c'est cette carte » ou « est-ce
        // l'une de celles-ci ? ». Affirmer à tort coûte plus cher que suggérer.
        Text(
          outcome!.isConfident
              ? 'Carte reconnue'
              : 'Reconnaissance incertaine — vérifiez avant d\'ajouter',
          style: theme.textTheme.titleSmall?.copyWith(
            color: outcome!.isConfident
                ? theme.colorScheme.primary
                : theme.colorScheme.tertiary,
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < details.length; i++) ...[
          _Candidate(
            card: details[i],
            distance: i < outcome!.candidates.length
                ? outcome!.candidates[i].distance
                : null,
            highlighted: i == 0 && outcome!.isConfident,
            onAdd: () => onAdd(details[i]),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _Candidate extends StatelessWidget {
  const _Candidate({
    required this.card,
    required this.distance,
    required this.highlighted,
    required this.onAdd,
  });

  final CardHit card;
  final int? distance;
  final bool highlighted;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: highlighted
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(card.matchedName, style: theme.textTheme.titleMedium),
                if (card.isLocalized) Text(card.name, style: muted),
                const SizedBox(height: 4),
                Text(
                  [
                    card.typeLine ?? '',
                    if (distance != null) 'écart $distance',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: muted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Text(
            card.priceEur == null
                ? '—'
                : '${card.priceEur!.toStringAsFixed(2)} €',
            style: theme.textTheme.titleSmall,
          ),
          IconButton.filledTonal(
            onPressed: onAdd,
            tooltip: 'Ajouter à ma collection',
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _LoadingIndex extends StatelessWidget {
  const _LoadingIndex();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 20),
            Text(
              'Chargement de l\'index de reconnaissance',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Une seule fois — ensuite la reconnaissance fonctionne hors ligne.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

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
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              detail,
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
