/// Accès à la reconnaissance vocale du système.
///
/// Isolé derrière une interface étroite : le paquet sous-jacent expose une
/// machine à états riche dont l'application n'a besoin que de trois choses —
/// démarrer, arrêter, recevoir du texte.
///
/// **La langue compte plus qu'il n'y paraît.** Un nom anglais dicté à un moteur
/// réglé en français revient phonétiquement massacré, au point que même une
/// recherche tolérante n'y retrouve rien. Le choix est donc laissé à
/// l'utilisateur plutôt que déduit de la locale du système, puisqu'une
/// collection mêle les deux langues.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

enum DictationLanguage {
  french('fr_FR', 'Français'),
  english('en_US', 'English');

  const DictationLanguage(this.localeId, this.label);

  final String localeId;
  final String label;
}

class SpeechService {
  SpeechService();

  final SpeechToText _speech = SpeechToText();
  bool _available = false;

  bool get isListening => _speech.isListening;

  /// Prépare le moteur. Renvoie faux si l'appareil n'en a pas, ou si le
  /// microphone est refusé.
  Future<bool> prepare() async {
    if (_available) return true;
    _available = await _speech.initialize(
      // Les erreurs et changements d'état ne sont pas remontés ici : l'appelant
      // observe le texte, et une panne se traduit par une absence de résultat.
      onError: (_) {},
      onStatus: (_) {},
    );
    return _available;
  }

  /// Écoute jusqu'à `stop()`, en livrant les transcriptions au fil de l'eau.
  ///
  /// [onResult] reçoit aussi les résultats partiels : c'est ce qui permet
  /// d'afficher les mots pendant qu'ils sont prononcés, et donc de savoir que
  /// l'application entend bien.
  Future<void> start({
    required DictationLanguage language,
    required void Function(String text, bool isFinal) onResult,
  }) async {
    if (!await prepare()) return;

    await _speech.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        localeId: language.localeId,
        partialResults: true,
        // Dicter une collection prend du temps : sans cela le moteur coupe
        // après quelques secondes de silence, en pleine réflexion.
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        // Laisse le temps de chercher la carte suivante dans la boîte : sans
        // cette marge, le moteur coupe l'écoute entre deux cartes.
        pauseFor: const Duration(seconds: 4),
        listenFor: const Duration(minutes: 5),
      ),
    );
  }

  Future<void> stop() => _speech.stop();
}

final speechServiceProvider = Provider<SpeechService>((ref) {
  final service = SpeechService();
  ref.onDispose(service.stop);
  return service;
});
