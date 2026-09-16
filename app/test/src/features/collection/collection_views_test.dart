/// Ce qu'une écriture dans la collection oblige à relire.
///
/// **Ce que ce test protège** : la liste unique que tous les écrans qui écrivent
/// appellent. Retirer une vue de cette liste laisserait un écran faux sans
/// qu'aucune erreur ne le dise.
library;

import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_views.dart';
import 'package:deckhand/src/features/decks/data/deck_repository.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('une écriture relit les totaux, le journal, le classeur et les decks', () {
    final invalidated = <ProviderOrFamily>[];

    refreshCollectionViews(invalidated.add);

    expect(
      invalidated,
      unorderedEquals(<ProviderOrFamily>[
        collectionProvider,
        collectionHistoryProvider,
        binderShelfProvider,
        binderPageProvider,
        binderFindProvider,
        unsortedPileProvider,
        // **Les decks aussi.** Ils se rafraîchissaient seuls en observant le
        // résumé, ce qui coûtait une requête de trop à chaque lancement ; leur
        // place est ici, avec les autres vues de la collection.
        deckSuggestionsProvider,
      ]),
    );
  });
}
