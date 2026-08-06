/// Saisie vocale : dicter une collection plutôt que la taper.
///
/// **Le mode continu est la raison d'être de cet écran.** Dicter une carte,
/// confirmer, recommencer serait plus lent que le clavier. L'écoute reste donc
/// ouverte, chaque carte reconnue s'ajoute à une liste, et la validation se fait
/// en bloc à la fin.
///
/// Rien n'entre en collection sans confirmation — garde-fou §IV.8, comme pour le
/// scan. La reconnaissance vocale se trompe davantage encore qu'une photo :
/// proposer sans écrire est ici d'autant plus nécessaire.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../card_search/data/card_repository.dart';
import '../../card_search/domain/card_hit.dart';
import '../../collection/data/collection_repository.dart';
import '../data/speech_service.dart';
import '../domain/dictation_parser.dart';

/// Une carte dictée, avec ce que la recherche en a fait.
class _Heard {
  _Heard({
    required this.spoken,
    required this.quantity,
    this.match,
    this.alternatives = const [],
  });

  final String spoken;
  int quantity;
  final CardHit? match;
  final List<CardHit> alternatives;

  bool get isResolved => match != null;
}

class VoiceInputScreen extends ConsumerStatefulWidget {
  const VoiceInputScreen({super.key});

  @override
  ConsumerState<VoiceInputScreen> createState() => _VoiceInputScreenState();
}

class _VoiceInputScreenState extends ConsumerState<VoiceInputScreen> {
  DictationLanguage _language = DictationLanguage.french;
  final List<_Heard> _heard = [];
  final Set<String> _consumed = {};

  bool _listening = false;
  bool _saving = false;
  String _partial = '';
  String? _error;

  @override
  void dispose() {
    ref.read(speechServiceProvider).stop();
    super.dispose();
  }

  Future<void> _toggleListening() async {
    final speech = ref.read(speechServiceProvider);

    if (_listening) {
      await speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    final ready = await speech.prepare();
    if (!ready) {
      if (mounted) {
        setState(
          () => _error =
              'Reconnaissance vocale indisponible. Vérifiez l\'autorisation du microphone.',
        );
      }
      return;
    }

    setState(() {
      _listening = true;
      _error = null;
      _partial = '';
    });

    await speech.start(
      language: _language,
      onResult: (text, isFinal) {
        if (!mounted) return;
        setState(() => _partial = text);
        if (isFinal) unawaited(_absorb(text));
      },
    );
  }

  /// Transforme une transcription finale en cartes, sans redoubler ce qui a
  /// déjà été absorbé — le moteur renvoie parfois deux fois la même phrase.
  Future<void> _absorb(String transcript) async {
    final cards = parseDictation(transcript);
    if (cards.isEmpty) return;

    final repository = ref.read(cardRepositoryProvider);
    for (final card in cards) {
      final key = '${card.query}#${card.quantity}';
      if (!_consumed.add(key)) continue;

      List<CardHit> hits = const [];
      try {
        hits = await repository.search(card.query, limit: 4);
      } catch (_) {
        // Une recherche en échec laisse la carte non résolue : l'utilisateur la
        // verra signalée plutôt que silencieusement perdue.
      }
      if (!mounted) return;
      setState(() {
        _heard.add(
          _Heard(
            spoken: card.query,
            quantity: card.quantity,
            match: hits.isEmpty ? null : hits.first,
            alternatives: hits.length > 1 ? hits.sublist(1) : const [],
          ),
        );
        _partial = '';
      });
    }
  }

  Future<void> _saveAll() async {
    final resolved = _heard.where((h) => h.isResolved).toList();
    if (resolved.isEmpty) return;

    setState(() => _saving = true);
    final repository = ref.read(collectionRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    var added = 0;
    try {
      for (final item in resolved) {
        await repository.add(item.match!.oracleId, quantity: item.quantity);
        added += item.quantity;
      }
      ref.invalidate(collectionProvider);
      ref.invalidate(collectionPageProvider);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '$added carte${added > 1 ? 's' : ''} ajoutée${added > 1 ? 's' : ''}',
          ),
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
    final resolved = _heard.where((h) => h.isResolved).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dicter des cartes'),
        actions: [
          PopupMenuButton<DictationLanguage>(
            initialValue: _language,
            onSelected: (value) => setState(() => _language = value),
            itemBuilder: (context) => [
              for (final language in DictationLanguage.values)
                PopupMenuItem(value: language, child: Text(language.label)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: Text(_language.label)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                _Hint(listening: _listening, partial: _partial, error: _error),
                Expanded(
                  child: _heard.isEmpty
                      ? const _Empty()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                          itemCount: _heard.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) => _HeardTile(
                            item: _heard[index],
                            onRemove: () =>
                                setState(() => _heard.removeAt(index)),
                            onQuantity: (value) =>
                                setState(() => _heard[index].quantity = value),
                          ),
                        ),
                ),
                _Actions(
                  listening: _listening,
                  saving: _saving,
                  resolvedCount: resolved,
                  onToggle: _toggleListening,
                  onSave: _saveAll,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.listening,
    required this.partial,
    required this.error,
  });

  final bool listening;
  final String partial;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            listening
                ? 'Dictez vos cartes à la suite : « quatre foudre, puis anneau solaire »'
                : 'Appuyez sur le micro et dictez vos cartes les unes après les autres.',
            style: theme.textTheme.bodyMedium,
          ),
          if (partial.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '« $partial »',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeardTile extends StatelessWidget {
  const _HeardTile({
    required this.item,
    required this.onRemove,
    required this.onQuantity,
  });

  final _Heard item;
  final VoidCallback onRemove;
  final ValueChanged<int> onQuantity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: item.isResolved
            ? theme.colorScheme.surfaceContainerHigh
            : theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.match?.matchedName ?? item.spoken,
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                // Ce qui a été entendu reste visible : c'est le seul moyen de
                // comprendre pourquoi une carte est fausse ou introuvable.
                Text(
                  item.isResolved
                      ? 'entendu : « ${item.spoken} »'
                      : 'non reconnue : « ${item.spoken} »',
                  style: muted,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (item.isResolved) ...[
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Un de moins',
              onPressed: item.quantity > 1
                  ? () => onQuantity(item.quantity - 1)
                  : null,
            ),
            Text('${item.quantity}', style: theme.textTheme.titleMedium),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Un de plus',
              onPressed: () => onQuantity(item.quantity + 1),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Écarter',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.listening,
    required this.saving,
    required this.resolvedCount,
    required this.onToggle,
    required this.onSave,
  });

  final bool listening;
  final bool saving;
  final int resolvedCount;
  final VoidCallback onToggle;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: saving ? null : onToggle,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: listening
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
              icon: Icon(listening ? Icons.stop : Icons.mic),
              label: Text(listening ? 'Arrêter' : 'Dicter'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: resolvedCount == 0 || saving ? null : onSave,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              icon: saving
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.playlist_add_check),
              label: Text('Ajouter ($resolvedCount)'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

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
              Icons.mic_none,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('Aucune carte dictée', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Les quantités se disent avant le nom, et « puis » sépare deux cartes.',
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
