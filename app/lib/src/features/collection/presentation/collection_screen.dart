/// Vue de la collection : ce que vous possédez, rangé comme dans un classeur.
///
/// **Il n'y a plus qu'une vue, et c'est le classeur.** La liste triable a existé
/// et a été retirée : chacun de ses services a trouvé un équivalent qui ne
/// dénature pas le rangement.
///
/// | Ce que la liste faisait | Ce qui le fait désormais |
/// |---|---|
/// | Trier par valeur, par nom | Les régimes de lecture du classeur |
/// | Filtrer sur la finition | Le filtre du classeur, trous conservés |
/// | Atteindre les cartes sans édition | La pile « à trier » |
/// | Chercher une carte par son nom | La recherche de l'étagère, qui donne la page |
/// | Ajouter, retirer, corriger l'édition | Les actions d'une case |
///
/// Ce qu'on y gagne est ce qu'aucune liste ne montrait : **les cases vides**.
/// Une liste dit ce qu'on possède ; un classeur dit ce qui manque.
///
/// Le bandeau de totaux reste : il porte sur la collection entière et vient d'un
/// appel distinct, si bien qu'aucun filtre de classeur ne le fait varier.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../binders/presentation/binder_view.dart';
import '../data/collection_repository.dart';
import '../domain/collection_entry.dart';

class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(collectionProvider);

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
        return Column(
          children: [
            _Totals(summary: totals),
            const Expanded(child: BinderView()),
          ],
        );
      },
    );
  }
}

/// Ce que pèse la collection, indépendamment de ce qu'on regarde.
///
/// **Les totaux portent sur la collection entière.** Ils viennent d'un appel
/// distinct de celui qui remplit les cases : ouvrir un classeur ou filtrer sur
/// les brillants ne doit pas donner l'impression d'avoir perdu mille cartes.
class _Totals extends StatelessWidget {
  const _Totals({required this.summary});

  final CollectionSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${summary.totalCards} cartes',
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  '${summary.distinctCards} références distinctes',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                // Une carte sans édition n'a pas de case : le dire ici évite de
                // chercher en vain dans les classeurs ce qui est dans la pile.
                if (summary.unspecifiedPrints > 0)
                  Text(
                    '${summary.unspecifiedPrints} sans édition — à trier',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            '${summary.totalValueEur.toStringAsFixed(2)} €',
            style: theme.textTheme.titleMedium,
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
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              'Votre collection est vide',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              'Cherchez une carte ou photographiez-la pour l\'ajouter.',
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
