/// Le classeur de quelqu'un d'autre, sans compte.
///
/// **C'est le même classeur, pas une seconde vue.** Toute la mécanique — les
/// feuilles qui se tournent, les cases vides, la double page couchée — vit dans
/// [BinderView] ; cet écran ne fait que désigner la collection à lire et
/// retirer ce qui n'a pas de sens chez un autre. Écrire une page publique
/// séparée aurait produit deux classeurs à corriger au lieu d'un.
///
/// **Ce que le serveur garantit, et ce que cet écran ne garantit pas.** Une
/// collection non publiée est refusée par la base, pas par cette page : elle
/// affiche alors une étagère vide, comme une collection qui ne contiendrait
/// rien. C'est la bonne réponse — dire « cette collection existe mais elle est
/// privée » confirmerait son existence à qui essaie des adresses au hasard.
///
/// **L'attribution est ici, visible.** Le garde-fou §IV.2 tenait jusqu'ici par
/// un écran « à propos » qu'un visiteur n'ouvrira jamais. Une page vue par des
/// inconnus doit porter son crédit à même le pied de page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collection/data/collection_repository.dart';
import '../data/binder_repository.dart';
import 'binder_view.dart';

/// Identifiant de collection lu dans l'adresse, ou `null`.
///
/// **Deux endroits à regarder, et c'est le prix du web.** Flutter sert ses
/// routes tantôt derrière un `#`, tantôt non, selon la stratégie d'URL
/// retenue ; chercher dans les deux évite qu'un lien cesse de fonctionner parce
/// que la configuration a changé.
///
/// La forme est `?c=<identifiant>`. Un paramètre plutôt qu'un segment de
/// chemin : il ne demande aucune réécriture côté serveur, et une page servie en
/// statique le reçoit tel quel.
String? collectionFromUrl(Uri url) {
  final direct = url.queryParameters['c'];
  if (direct != null && direct.isNotEmpty) return direct;

  final fragment = url.fragment;
  if (fragment.isEmpty) return null;
  final question = fragment.indexOf('?');
  if (question < 0) return null;
  final inner = Uri.splitQueryString(fragment.substring(question + 1))['c'];
  return (inner == null || inner.isEmpty) ? null : inner;
}

/// Collection derrière une adresse de partage — un nom ou un identifiant.
///
/// **La résolution vit côté serveur**, et ne rend rien pour une collection non
/// publiée : une adresse essayée au hasard ne doit pas révéler qu'elle existe.
final resolvedCollectionProvider = FutureProvider.autoDispose
    .family<String?, String>(
      (ref, handle) =>
          ref.watch(collectionRepositoryProvider).collectionByHandle(handle),
    );

/// Écran d'un classeur partagé.
class PublicBinderScreen extends ConsumerStatefulWidget {
  const PublicBinderScreen({super.key, required this.handle});

  /// Ce que portait l'adresse : un nom choisi, ou l'identifiant brut.
  final String handle;

  @override
  ConsumerState<PublicBinderScreen> createState() => _PublicBinderScreenState();
}

class _PublicBinderScreenState extends ConsumerState<PublicBinderScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved = ref.watch(resolvedCollectionProvider(widget.handle));
    final id = resolved.asData?.value;

    // Le classeur lit `readCollectionProvider` dès sa construction : il faut
    // donc le renseigner avant de le montrer, et jamais pendant un rendu.
    if (id != null && ref.read(readCollectionProvider) != id) {
      Future.microtask(
        () => ref.read(readCollectionProvider.notifier).look(id),
      );
    }

    if (resolved.isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    // **Une adresse qui ne mène nulle part se tait.** Collection inexistante ou
    // non publiée : la même réponse, faute de quoi on confirmerait l'existence
    // de la seconde.
    if (id == null || ref.watch(readCollectionProvider) != id) {
      return _Empty(loading: id != null);
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1600),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
                  child: Row(
                    children: [
                      Text('DeckHand', style: theme.textTheme.headlineSmall),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Classeur partagé',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Expanded(child: BinderView()),
                const _Attribution(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le crédit dû aux sources, à même la page.
class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Text(
        'Cartes, images et prix : Scryfall. Magic: The Gathering est une marque '
        'de Wizards of the Coast, qui n\'est pas affiliée à DeckHand.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Ce qu'on montre quand l'adresse ne mène nulle part.
class _Empty extends StatelessWidget {
  const _Empty({required this.loading});

  /// Vrai le temps que le classeur se branche sur la collection résolue.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 40,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text('Rien à voir ici', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Cette adresse ne mène à aucun classeur partagé.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
