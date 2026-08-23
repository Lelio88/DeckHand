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
/// **Passe par l'écran, et non par la sortie standard ni par un fichier.** Une version
/// antérieure affirmait qu'`adb logcat` recevait ces lignes « y compris sur un
/// build de production non déboguable ». **C'est faux, et cela a coûté deux
/// allers-retours avec l'appareil** : ni en `release` ni en `profile` la sortie
/// Dart n'atteint le journal système sur cet appareil — l'application tourne,
/// son ramasse-miettes s'y voit, et pas une ligne du journal.
///
/// **Le fichier a été essayé, et il échoue aussi.** Depuis Android 10, une
/// application ne peut plus atteindre son propre dossier sous `Android/data`
/// par un chemin en dur — il faut passer par l'API système, donc par une
/// dépendance que ce projet n'a pas. Le dossier n'est jamais créé, et l'échec
/// est muet puisque c'est précisément le journal qui aurait dû le dire.
///
/// Reste l'écran, qui ne dépend ni du mode de compilation ni des règles de
/// stockage : [recentDiagnostics] garde les dernières lignes, et un écran de
/// mesure les affiche. Une capture d'écran suffit alors à les rapporter au
/// poste de travail.
///
/// Usage depuis le poste de travail :
/// ```
/// # … faire la manipulation à mesurer sur l'appareil …
/// adb exec-out screencap -p > mesure.png    # le relevé est à l'écran
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
  final ligne = '$diagnosticsTag ${jsonEncode(payload)}';
  debugPrint(ligne);
  _ecrire(ligne);
}

/// Les dernières lignes émises, les plus récentes en tête.
///
/// **Lisibles depuis l'application, faute de mieux.** Ni `logcat` ni un fichier
/// ne ramènent le journal d'un appareil : le premier ne reçoit rien hors du
/// mode debug, le second ne peut plus être écrit là où `adb` sait le lire. Un
/// écran, lui, se photographie.
List<String> get recentDiagnostics => List.unmodifiable(_recents);

final List<String> _recents = <String>[];

/// Au-delà, les lignes les plus anciennes tombent. Assez pour une passe de
/// scan, assez peu pour tenir sur un écran de téléphone.
const int _maxRecents = 40;

void _ecrire(String ligne) {
  _recents.insert(0, ligne);
  if (_recents.length > _maxRecents) _recents.removeLast();
}

