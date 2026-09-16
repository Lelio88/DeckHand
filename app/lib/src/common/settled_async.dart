/// Lire un `AsyncValue` sans se laisser piéger par une reprise.
///
/// **Riverpod 3 réessaie tout seul un provider qui a échoué**, avec un délai
/// croissant. Pendant chaque reprise, l'état repasse « en cours » *tout en
/// gardant l'erreur* — mesuré : `isLoading: true` et `hasError: true` en même
/// temps, cinq tentatives en trois secondes. `when()` rend alors sa branche
/// `loading`, si bien qu'un réseau coupé donne un écran qui tourne sans fin, au
/// lieu du message et du bouton « Réessayer ».
///
/// C'est exactement la panne que `request_timeout.dart` avait été écrite pour
/// supprimer, revenue par un autre chemin — et invisible, parce qu'un
/// indicateur qui tourne a l'air de travailler.
///
/// [settled] donne la priorité à l'erreur : dès qu'il y en a une, elle
/// s'affiche, reprises ou non. La reprise continue en arrière-plan et l'écran
/// se corrige tout seul si elle aboutit ; entre-temps, l'utilisateur sait où il
/// en est et dispose d'un recours.
///
/// **Règle de l'application : `settled` partout où `when` avait une branche
/// `loading` distincte de sa branche `error`.** Le seul endroit qui garde
/// `when` est celui où les deux rendent la même chose — la feuille voisine
/// préchargée dans `binder_view.dart`, qui n'affiche rien dans les deux cas et
/// pour qui la distinction n'existe pas.
///
/// ```dart
/// cells.settled(
///   loading: () => const LoadingView(skeleton: BinderGridSkeleton()),
///   error: (error, _) => StateMessage(title: 'Page illisible', detail: '$error'),
///   data: (cells) => _Sheet(cells: cells),
/// )
/// ```
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

extension SettledAsyncValue<T> on AsyncValue<T> {
  /// Comme `when`, mais une erreur connue l'emporte sur une reprise en cours.
  R settled<R>({
    required R Function(T value) data,
    required R Function(Object error, StackTrace? stack) error,
    required R Function() loading,
  }) {
    final echec = this.error;
    if (hasError && echec != null) return error(echec, stackTrace);
    return when(data: data, error: error, loading: loading);
  }
}
