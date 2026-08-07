/// Journal de mesure, destiné au poste de travail plutôt qu'à l'utilisateur.
///
/// **Pourquoi ce module existe.** Les décisions de ce projet se prennent sur des
/// chiffres, et plusieurs d'entre elles portent sur ce que l'appareil voit ou
/// entend — les lignes que la reconnaissance de texte a réellement lues, les
/// événements que le moteur vocal a réellement émis. Rien de tout cela n'est
/// observable depuis un test : il faut un vrai téléphone, une vraie photo, une
/// vraie voix. Ce journal est le seul chemin entre ces mesures et le poste de
/// travail.
///
/// **Éteint par défaut.** Le journal ne s'allume qu'avec
/// `--dart-define=DECKHAND_DIAG=true`. Sans cela [_enabled] est une constante
/// fausse, et le compilateur élimine purement et simplement les appels : un
/// build ordinaire n'en porte aucune trace, ni en poids ni en temps.
///
/// **Passe par la sortie standard, pas par un fichier.** Un fichier obligerait
/// à une permission de stockage et à une dépendance de plus, pour une donnée
/// qu'on relit une fois. `adb logcat` la reçoit en direct, y compris sur un
/// build de production non déboguable.
///
/// Usage depuis le poste de travail :
/// ```
/// adb -s <addr> logcat -c                       # vider le tampon
/// adb -s <addr> logcat | grep DHDIAG > mesure.log
/// ```
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Marqueur de début de ligne, choisi pour être filtrable sans ambiguïté.
const String diagnosticsTag = 'DHDIAG';

/// Vrai uniquement sur un build de mesure.
const bool _enabled = bool.fromEnvironment('DECKHAND_DIAG');

/// Vrai si le journal émet quelque chose. Permet à un appelant d'éviter un
/// calcul coûteux qui ne servirait qu'à la mesure.
bool get diagnosticsEnabled => _enabled;

/// Émet un événement de mesure.
///
/// [event] nomme ce qui vient de se produire, en snake_case ; [fields] porte
/// les valeurs. Une ligne par événement, plutôt qu'un objet unique en fin de
/// course : le tampon de journal tronque les entrées longues, et une dictée qui
/// s'éteint ne livrerait jamais son bilan.
void diagnose(String event, [Map<String, Object?> fields = const {}]) {
  if (!_enabled) return;
  final payload = {
    't': DateTime.now().millisecondsSinceEpoch,
    'event': event,
    ...fields,
  };
  debugPrint('$diagnosticsTag ${jsonEncode(payload)}');
}
