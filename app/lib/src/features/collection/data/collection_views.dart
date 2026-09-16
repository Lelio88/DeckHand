/// Ce qu'une écriture dans la collection oblige à relire.
///
/// **Une seule liste, pour qu'aucun écran qui écrit ne l'oublie.** Recherche,
/// scan, étalement, dictée et classeur ajoutent, retirent ou déplacent des
/// exemplaires ; chacun tenait sa propre liste d'invalidations, et un oubli ne
/// lève aucune erreur, il laisse un écran faux — un nouveau classeur absent de
/// l'étagère jusqu'au redémarrage, une page de classeur ou une pile « à trier »
/// figée après un ajout fait ailleurs.
///
/// **Tout ce qui montre la collection est relu**, pas seulement ce que l'écran
/// courant affiche. Un provider que personne n'écoute est seulement marqué, et
/// ne recalcule qu'au prochain regard : une invalidation de trop ne coûte rien,
/// un oubli coûte un écran faux.
///
/// **La fonction d'invalidation est passée, pas un `ref`.** `WidgetRef` et
/// `ProviderContainer` en ont chacun une, sans type commun, et l'annulation d'un
/// retrait s'exécute sur le conteneur, la feuille étant déjà refermée.
///
/// ```dart
/// refreshCollectionViews(ref.invalidate);
/// refreshCollectionViews(container.invalidate);
/// ```
library;

import 'package:flutter_riverpod/misc.dart';

import '../../binders/data/binder_repository.dart';
import '../../decks/data/deck_repository.dart';
import 'collection_repository.dart';

/// Invalide chaque vue de la collection. À appeler après toute écriture.
void refreshCollectionViews(void Function(ProviderOrFamily) invalidate) {
  invalidate(collectionProvider);
  invalidate(collectionHistoryProvider);
  invalidate(binderShelfProvider);
  invalidate(binderPageProvider);
  invalidate(binderFindProvider);
  invalidate(unsortedPileProvider);
  // **Les decks sont une vue de la collection, eux aussi.** Ils ne figuraient
  // pas ici parce qu'ils se rafraîchissaient tout seuls, en observant le
  // résumé — au prix d'une requête de trop à chaque lancement. Les inscrire
  // dans la liste commune rend l'ajout d'une carte aussi visible qu'avant, et
  // place les decks sous la même règle que le reste : ce qui montre la
  // collection est relu quand elle change.
  invalidate(deckSuggestionsProvider);
}
