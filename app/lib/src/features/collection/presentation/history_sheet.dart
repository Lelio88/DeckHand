/// Le journal de la collection : ce qui est entré, ce qui est sorti, et quand.
///
/// **Ce que la collection ne peut pas dire.** Une ligne porte une quantité et
/// une date, qu'un ajout écrase : « ×3 depuis aujourd'hui » ne distingue pas
/// trois cartes acquises ce matin de deux cartes anciennes complétées d'une
/// troisième. Le journal garde chaque geste.
///
/// **Groupé par jour**, parce que c'est l'échelle à laquelle on se souvient :
/// on sait qu'on a vidé une boîte hier soir, pas qu'il était 21 h 14.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/collection_repository.dart';
import '../domain/collection_movement.dart';

/// Ouvre le journal, pour toute la collection ou pour une seule carte.
Future<void> showCollectionHistory(
  BuildContext context, {
  String? oracleId,
  String? cardName,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => _HistorySheet(oracleId: oracleId, cardName: cardName),
);

class _HistorySheet extends ConsumerWidget {
  const _HistorySheet({this.oracleId, this.cardName});

  final String? oracleId;
  final String? cardName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final history = ref.watch(collectionHistoryProvider(oracleId));

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cardName == null ? 'Journal' : 'Journal de',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  cardName ?? 'Ma collection',
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            child: history.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Journal illisible : $error'),
                ),
              ),
              data: (movements) => movements.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Aucun mouvement enregistré.'),
                      ),
                    )
                  : _Days(
                      movements: movements,
                      scrollController: scrollController,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Les mouvements, groupés par jour.
class _Days extends StatelessWidget {
  const _Days({required this.movements, required this.scrollController});

  final List<CollectionMovement> movements;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Les mouvements arrivent déjà du plus récent au plus ancien : il suffit de
    // marquer les changements de jour, sans réordonner ni regrouper en mémoire.
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: movements.length,
      itemBuilder: (context, i) {
        final movement = movements[i];
        final previous = i == 0 ? null : movements[i - 1];
        final newDay =
            previous == null || !_sameDay(previous.happenedAt, movement.happenedAt);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (newDay)
              Padding(
                padding: EdgeInsets.fromLTRB(20, i == 0 ? 8 : 20, 20, 4),
                child: Text(
                  _dayLabel(movement.happenedAt),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            _MovementTile(movement: movement),
          ],
        );
      },
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// « Aujourd'hui », « Hier », puis la date — c'est ainsi qu'on se repère.
  static String _dayLabel(DateTime when) {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(when.year, when.month, when.day))
        .inDays;
    if (days == 0) return "Aujourd'hui";
    if (days == 1) return 'Hier';
    return '${when.day.toString().padLeft(2, '0')}/'
        '${when.month.toString().padLeft(2, '0')}/${when.year}';
  }
}

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.movement});

  final CollectionMovement movement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Un rangement n'est ni un gain ni une perte : il ne prend donc pas la
    // couleur d'un ajout, qui laisserait croire à une acquisition de plus.
    final colour = switch (movement.kind) {
      MovementKind.acquired => theme.colorScheme.primary,
      MovementKind.released => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };

    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 44,
        child: Text(
          '${movement.delta > 0 ? '+' : ''}${movement.delta}',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            color: colour,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Text(
        movement.shownName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${movement.label} · ${movement.editionLabel}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Text(
        '${movement.happenedAt.hour.toString().padLeft(2, '0')}h'
        '${movement.happenedAt.minute.toString().padLeft(2, '0')}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
