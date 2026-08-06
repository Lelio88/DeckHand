/// Écran de saisie de collection : on tape un nom, les cartes apparaissent.
///
/// La frappe est amortie avant d'atteindre le réseau : sans cela, « lightning »
/// déclencherait neuf requêtes dont huit sans intérêt. Le délai est court pour
/// que la liste paraisse suivre la frappe.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/card_repository.dart';
import '../domain/card_hit.dart';

/// Amortissement de la frappe. 250 ms : au-delà la liste semble traîner,
/// en deçà on repart en requête entre deux touches.
const _debounce = Duration(milliseconds: 250);

class CardSearchScreen extends ConsumerStatefulWidget {
  const CardSearchScreen({super.key});

  @override
  ConsumerState<CardSearchScreen> createState() => _CardSearchScreenState();
}

class _CardSearchScreenState extends ConsumerState<CardSearchScreen> {
  final _controller = TextEditingController();
  Timer? _timer;
  String _query = '';

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(cardSearchProvider(_query));

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(controller: _controller, onChanged: _onChanged),
                Expanded(
                  child: _query.isEmpty
                      ? const _EmptyState()
                      : results.when(
                          data: (hits) => hits.isEmpty
                              ? _NoMatch(query: _query)
                              : _ResultList(hits: hits),
                          loading: () => const Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          error: (error, _) => _ErrorState(message: '$error'),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DeckHand', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text(
            'Cherchez une carte en français ou en anglais',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: controller,
            onChanged: onChanged,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Foudre, Sol Ring, contresort…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Effacer',
                      onPressed: () {
                        controller.clear();
                        onChanged('');
                      },
                    ),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultList extends StatelessWidget {
  const _ResultList({required this.hits});

  final List<CardHit> hits;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: hits.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _CardTile(hit: hits[index]),
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({required this.hit});

  final CardHit hit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hit.matchedName,
                  style: theme.textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                // Le nom oracle n'est rappelé que s'il diffère : inutile de
                // répéter la même chaîne sous une carte trouvée en anglais.
                if (hit.isLocalized)
                  Text(hit.name, style: muted, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Text(
                  hit.typeLine ?? '',
                  style: muted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    if (hit.legalPauper) const _FormatChip('Pauper'),
                    if (hit.legalModern) const _FormatChip('Modern'),
                    if (hit.legalCommander) const _FormatChip('Commander'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            hit.priceEur == null
                ? '—'
                : '${hit.priceEur!.toStringAsFixed(2)} €',
            style: theme.textTheme.titleSmall,
          ),
        ],
      ),
    );
  }
}

class _FormatChip extends StatelessWidget {
  const _FormatChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Les accents et les fautes de frappe sont tolérés.\n'
          'Essayez « foudr » ou « contresor ».',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Aucune carte ne correspond à « $query ».',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              'La recherche a échoué.',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              message,
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
