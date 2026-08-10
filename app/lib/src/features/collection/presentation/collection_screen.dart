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
/// Le poids de la collection — son nombre de cartes et sa valeur — est annoncé
/// par la barre du haut, qui le tient d'un appel distinct portant sur la
/// collection entière : aucun filtre de classeur ne le fait donc varier.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../binders/presentation/binder_view.dart';
import '../data/collection_repository.dart';

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
        // Le poids de la collection est annoncé par la barre du haut ; le
        // répéter ici volait une bande de hauteur aux cartes pour redire la
        // même chose.
        return const BinderView();
      },
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
