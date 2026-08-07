/// Accès à la reconnaissance vocale du système.
///
/// Isolé derrière une interface étroite : le paquet sous-jacent expose une
/// machine à états riche dont l'application n'a besoin que de trois choses —
/// démarrer, arrêter, recevoir du texte.
///
/// **L'écoute se relance toute seule, et c'est la raison d'être de ce service.**
/// Le moteur Android ne tient pas une session ouverte indéfiniment : il clôt dès
/// qu'un silence dépasse `pauseFor`, livre son résultat final, et s'arrête. Sans
/// relance, l'écran reste ouvert, le bouton affiche toujours « Arrêter », et plus
/// rien n'est entendu — on parle dans le vide. Dicter une collection suppose au
/// contraire des dizaines de phrases séparées par des silences, le temps
/// d'attraper la carte suivante.
///
/// **La langue compte plus qu'il n'y paraît.** Un nom anglais dicté à un moteur
/// réglé en français revient phonétiquement massacré, au point que même une
/// recherche tolérante n'y retrouve rien. Le choix est donc laissé à
/// l'utilisateur plutôt que déduit de la locale du système, puisqu'une
/// collection mêle les deux langues.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

enum DictationLanguage {
  french('fr_FR', 'Français'),
  english('en_US', 'English');

  const DictationLanguage(this.localeId, this.label);

  final String localeId;
  final String label;
}

/// Silence au-delà duquel le moteur clôt une phrase et livre son résultat.
///
/// C'est le délai entre la fin d'un nom prononcé et son apparition à l'écran.
/// Quatre secondes donnaient l'impression que rien ne se passait ; deux coupent
/// au milieu d'un nom long (« La Sorcière Rouge, Wanda Maximoff »), qu'on
/// prononce avec des respirations.
const _pauseBeforeFinal = Duration(seconds: 3);

/// Durée maximale d'une session avant que le moteur ne coupe de lui-même.
const _sessionLength = Duration(minutes: 2);

/// Rythme du chien de garde.
///
/// **Les événements du moteur ne suffisent pas.** La relance s'appuie sur
/// `done` et sur `onError`, mais une session peut s'éteindre sans émettre ni
/// l'un ni l'autre — après une phrase qu'il n'a pas su transcrire, notamment.
/// L'écoute meurt alors en silence : l'écran affiche « Arrêter », et l'on
/// continue de dicter sans que rien ne soit entendu.
const _watchdogPeriod = Duration(seconds: 2);

/// Passes inactives consécutives avant que le chien de garde n'intervienne.
///
/// **Il ne doit surtout pas être pressé.** Entre la fin d'une phrase et la
/// livraison de sa transcription, le moteur n'écoute plus mais travaille
/// encore : `isListening` est faux alors que tout va bien. Relancer là annule
/// la session et la phrase est perdue — on voit son texte s'afficher, et rien
/// n'est jamais cherché. Trois passes laissent au moteur le temps de finir ;
/// la relance normale sur `done` a largement eu lieu d'ici là, et ce garde-fou
/// ne sert plus qu'aux sessions qui meurent vraiment sans rien dire.
const _watchdogGracePasses = 3;

/// Nombre de relances infructueuses consécutives avant d'abandonner.
///
/// Sans ce garde-fou, un microphone refusé en cours de route ferait boucler la
/// relance indéfiniment, en vidant la batterie sans rien dire.
const _maxConsecutiveFailures = 3;

class SpeechService {
  SpeechService();

  final SpeechToText _speech = SpeechToText();
  bool _available = false;

  /// Vrai tant que l'utilisateur n'a pas demandé l'arrêt. C'est ce drapeau, et
  /// non l'état du moteur, qui décide s'il faut relancer.
  bool _wanted = false;

  int _failures = 0;
  int _idlePasses = 0;
  Timer? _restart;
  Timer? _watchdog;

  DictationLanguage _language = DictationLanguage.french;
  void Function(String text, bool isFinal)? _onResult;

  /// Signale à l'écran que l'écoute s'est interrompue pour de bon.
  void Function()? _onGaveUp;

  bool get isListening => _speech.isListening;

  /// Prépare le moteur. Renvoie faux si l'appareil n'en a pas, ou si le
  /// microphone est refusé.
  Future<bool> prepare() async {
    if (_available) return true;
    _available = await _speech.initialize(
      // Une erreur isolée (silence trop long, réseau du moteur) ne doit pas
      // arrêter la dictée : on relance comme après une fin normale.
      onError: (_) => _scheduleRestart(),
      // **Uniquement `done`.** `notListening` survient dès que le micro se
      // coupe, mais le moteur est alors encore en train de transcrire : relancer
      // à ce moment annule la session et la phrase est perdue — on voit son
      // texte s'afficher, puis plus rien. `done` arrive après la livraison du
      // résultat final, et c'est le seul instant où relancer est sans risque.
      onStatus: (status) {
        if (status == 'done') _scheduleRestart();
      },
    );
    return _available;
  }

  /// Écoute jusqu'à `stop()`, en livrant les transcriptions au fil de l'eau.
  ///
  /// [onResult] reçoit aussi les résultats partiels : c'est ce qui permet
  /// d'afficher les mots pendant qu'ils sont prononcés, et donc de savoir que
  /// l'application entend bien. [onGaveUp] est appelé si l'écoute ne peut plus
  /// être relancée — l'écran doit alors cesser d'afficher « Arrêter ».
  Future<void> start({
    required DictationLanguage language,
    required void Function(String text, bool isFinal) onResult,
    void Function()? onGaveUp,
  }) async {
    if (!await prepare()) return;

    _wanted = true;
    _failures = 0;
    _language = language;
    _onResult = onResult;
    _onGaveUp = onGaveUp;

    _idlePasses = 0;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(_watchdogPeriod, (_) {
      if (!_wanted) return;
      if (_speech.isListening) {
        _idlePasses = 0;
        return;
      }
      _idlePasses++;
      if (_idlePasses >= _watchdogGracePasses) {
        _idlePasses = 0;
        _scheduleRestart();
      }
    });

    await _listen();
  }

  Future<void> _listen() async {
    final onResult = _onResult;
    if (!_wanted || onResult == null) return;

    try {
      await _speech.listen(
        onResult: (result) =>
            onResult(result.recognizedWords, result.finalResult),
        listenOptions: SpeechListenOptions(
          localeId: _language.localeId,
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: false,
          pauseFor: _pauseBeforeFinal,
          listenFor: _sessionLength,
        ),
      );
      _failures = 0;
    } catch (_) {
      _failures++;
      if (_failures >= _maxConsecutiveFailures) {
        _wanted = false;
        _watchdog?.cancel();
        _watchdog = null;
        _onGaveUp?.call();
      }
    }
  }

  /// Relance après un court répit.
  ///
  /// Le délai n'est pas cosmétique : relancer dans le callback même, alors que
  /// le moteur est encore en train de se fermer, fait échouer l'appel — et trois
  /// échecs de suite arrêtent la dictée.
  void _scheduleRestart() {
    if (!_wanted) return;
    _restart?.cancel();
    _restart = Timer(const Duration(milliseconds: 400), () {
      _idlePasses = 0;
      if (_wanted && !_speech.isListening) unawaited(_listen());
    });
  }

  Future<void> stop() async {
    _wanted = false;
    _restart?.cancel();
    _restart = null;
    _watchdog?.cancel();
    _watchdog = null;
    await _speech.stop();
  }
}

final speechServiceProvider = Provider<SpeechService>((ref) {
  final service = SpeechService();
  ref.onDispose(service.stop);
  return service;
});
