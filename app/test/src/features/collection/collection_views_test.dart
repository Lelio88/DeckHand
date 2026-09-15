/// Ce qu'une écriture dans la collection oblige à relire.
///
/// **Ce que ce test protège** : la liste unique que tous les écrans qui écrivent
/// appellent. Retirer une vue de cette liste laisserait un écran faux sans
/// qu'aucune erreur ne le dise.
library;

import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_views.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('une écriture relit les totaux, le journal et tout ce que montre le '
      'classeur', () {
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
      ]),
    );
  });
}
