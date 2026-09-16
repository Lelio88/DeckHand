/// Une reprise ne doit pas cacher une panne.
///
/// **Riverpod 3 réessaie tout seul un provider qui a échoué.** Pendant chaque
/// reprise, l'état repasse « en cours » tout en gardant l'erreur — mesuré, cinq
/// tentatives en trois secondes. `when()` rend alors sa branche `loading`, et un
/// réseau coupé donne un écran qui tourne indéfiniment au lieu du message et du
/// bouton « Réessayer ». C'est précisément la panne que `request_timeout.dart`
/// avait supprimée, revenue par un autre chemin.
///
/// **Le piège lui-même se vérifie sur l'écran, pas ici.** Une reprise
/// reconstituée à la main ne reproduit pas l'`AsyncValue` que Riverpod
/// fabrique — essayé, `when()` y rend la branche d'erreur. Ce sont les tests
/// « quand le réseau lâche » de `binder_view_test.dart` qui tiennent la garantie
/// de bout en bout : ils tombaient avec `when`, ils passent avec `settled`.
library;

import 'package:deckhand/src/common/settled_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // **Riverpod 3 réessaie tout seul un provider qui a échoué.** Pendant
  // chaque reprise, l'état repasse « en cours » tout en gardant l'erreur —
  // mesuré, cinq tentatives en trois secondes. `when()` rend alors sa branche
  // `loading`, et un réseau coupé donne un écran qui tourne indéfiniment au
  // lieu du message et du bouton « Réessayer ». C'est précisément la panne que
  // `request_timeout.dart` avait supprimée, revenue par un autre chemin.
  //
  // **Le piège lui-même se vérifie sur l'écran, pas ici.** Une reprise
  // reconstituée à la main ne reproduit pas l'`AsyncValue` que Riverpod
  // fabrique — essayé, `when()` y rend la branche d'erreur. Ce sont les tests
  // « quand le réseau lâche » de `binder_view_test.dart` qui tiennent la
  // garantie de bout en bout : ils tombaient avec `when`, ils passent avec
  // `settled`.
  test('settled() montre la panne', () {
    expect(
      AsyncError<int>('réseau coupé', StackTrace.empty).settled(
          data: (_) => 'données', error: (_, _) => 'panne',
          loading: () => 'chargement'),
      'panne',
    );
  });

  test('un chargement sans erreur reste un chargement', () {
    expect(
      const AsyncLoading<int>().settled(
          data: (_) => 'données', error: (_, _) => 'panne',
          loading: () => 'chargement'),
      'chargement',
    );
  });

  test('des données restent des données', () {
    expect(
      const AsyncData<int>(7).settled(
          data: (v) => 'données $v', error: (_, _) => 'panne',
          loading: () => 'chargement'),
      'données 7',
    );
  });
}
