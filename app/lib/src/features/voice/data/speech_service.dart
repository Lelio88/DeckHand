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

import '../../../diagnostics/diagnostics.dart';

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

/// Répit avant de relancer, quand la phrase a bien été livrée.
///
/// Relancer dans le callback même, alors que le moteur se ferme encore, fait
/// échouer l'appel — et trois échecs de suite arrêtent la dictée.
const _restartDelay = Duration(milliseconds: 400);

/// Répit avant de relancer, quand **aucun résultat final n'est venu**.
///
/// **C'est le délai qui décide si la phrase est perdue ou récupérée.** Le
/// moteur clôt parfois sa session sans conclure : le texte a été transcrit, il
/// s'affiche à l'écran, mais rien n'est jamais livré comme définitif. Le paquet
/// prévoit ce cas — à l'arrêt, il arme un rattrapage de deux secondes qui
/// promeut la dernière transcription partielle en résultat final.
///
/// Or `listen()` **annule ce rattrapage** dès son premier geste. Relancer au
/// bout de 400 ms, comme après une phrase normale, détruit donc le filet 1,6 s
/// avant qu'il ne serve, et la phrase disparaît. Mesuré : une carte dictée,
/// neuf transcriptions partielles, pas un seul résultat final, relance à
/// +401 ms — rien n'est jamais cherché.
///
/// On attend donc que le rattrapage ait joué. Sa promotion émet à son tour un
/// « done », qui raccourcit ce délai d'autant : le coût n'est payé que dans le
/// cas où il n'y a rien à récupérer.
const _rescueDelay = Duration(milliseconds: 2200);

/// Répit à observer avant de relancer l'écoute.
///
/// Isolé du service parce que c'est là que se joue la perte des phrases, et
/// qu'un test doit pouvoir le vérifier sans microphone : le délai de secours
/// doit dépasser le rattrapage du paquet, faute de quoi la relance l'annule.
Duration restartDelayAfter({required bool finalSeen}) =>
    finalSeen ? _restartDelay : _rescueDelay;

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

  /// Vrai si la session en cours a déjà livré une phrase pour de bon.
  ///
  /// Distingue la session qui s'achève normalement de celle qui s'éteint sans
  /// avoir conclu — les deux se ressemblent vues de l'extérieur, mais l'une n'a
  /// plus rien à donner et l'autre garde une phrase en suspens.
  bool _finalSeen = false;

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
      //
      // **Le message d'erreur n'est utilisé que pour la mesure.** Il ne change
      // rien à la décision — on relance dans tous les cas — mais c'est la seule
      // trace de ce que le moteur reproche, et donc le seul moyen de savoir
      // pourquoi la dictée finit par s'éteindre.
      onError: (error) {
        diagnose('speech_error', {
          'msg': error.errorMsg,
          'permanent': error.permanent,
        });
        // **Le même répit que sur `done`, et pour la même raison.** L'erreur
        // suit la fin de session de quelques dizaines de millisecondes ;
        // relancer court ici écraserait la relance longue qui vient d'être
        // planifiée, et le rattrapage serait perdu malgré tout.
        _scheduleRestart(restartDelayAfter(finalSeen: _finalSeen));
      },
      // **Uniquement `done`.** `notListening` survient dès que le micro se
      // coupe, mais le moteur est alors encore en train de transcrire : relancer
      // à ce moment annule la session et la phrase est perdue — on voit son
      // texte s'afficher, puis plus rien. `done` arrive après la livraison du
      // résultat final, et c'est le seul instant où relancer est sans risque.
      onStatus: (status) {
        diagnose('speech_status', {'status': status});
        // **Uniquement `done`, mais pas toujours au même rythme.** Une session
        // qui s'achève sans avoir rien conclu a peut-être encore une phrase à
        // rendre : on lui laisse le temps du rattrapage plutôt que de l'annuler.
        if (status == 'done') {
          _scheduleRestart(restartDelayAfter(finalSeen: _finalSeen));
        }
      },
    );
    diagnose('speech_prepared', {'available': _available});
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

    diagnose('speech_start', {'locale': language.localeId});

    _idlePasses = 0;
    _watchdog?.cancel();
    _watchdog = Timer.periodic(_watchdogPeriod, (_) {
      if (!_wanted) return;
      // Le chien de garde bat à intervalle fixe : il fait aussi office
      // d'échantillonneur. C'est cette trace régulière qui date l'instant où
      // l'écoute cesse, à deux secondes près, sans code supplémentaire.
      diagnose('speech_tick', {
        'listening': _speech.isListening,
        'idle': _idlePasses,
      });
      if (_speech.isListening) {
        _idlePasses = 0;
        return;
      }
      _idlePasses++;
      if (_idlePasses >= _watchdogGracePasses) {
        _idlePasses = 0;
        diagnose('speech_watchdog_restart');
        _scheduleRestart();
      }
    });

    await _listen();
  }

  Future<void> _listen() async {
    final onResult = _onResult;
    if (!_wanted || onResult == null) return;

    diagnose('speech_listen');
    _finalSeen = false;
    try {
      await _speech.listen(
        onResult: (result) {
          diagnose('speech_result', {
            'final': result.finalResult,
            'words': result.recognizedWords,
          });
          if (result.finalResult) _finalSeen = true;
          onResult(result.recognizedWords, result.finalResult);
        },
        listenOptions: SpeechListenOptions(
          localeId: _language.localeId,
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: false,
          pauseFor: _pauseBeforeFinal,
          listenFor: _sessionLength,
        ),
      );
      // **Un retour sans exception ne prouve pas que l'écoute a démarré.** Le
      // paquet interroge la plateforme, et si celle-ci refuse, il n'en fait
      // rien : ni exception, ni écoute. Consigner l'état juste après permet de
      // distinguer ce refus silencieux d'un démarrage réussi — la trace dira si
      // c'est là que la dictée s'éteint.
      diagnose('speech_listening', {'listening': _speech.isListening});
      _failures = 0;
    } catch (e) {
      _failures++;
      diagnose('speech_listen_failed', {'error': '$e', 'failures': _failures});
      if (_failures >= _maxConsecutiveFailures) {
        _wanted = false;
        _watchdog?.cancel();
        _watchdog = null;
        diagnose('speech_gave_up');
        _onGaveUp?.call();
      }
    }
  }

  /// Relance après un répit, dont la longueur dépend de ce qu'on attend encore.
  ///
  /// Un appel plus tardif écrase un appel en attente : c'est ce qui permet au
  /// rattrapage, lorsqu'il livre enfin sa phrase, de ramener la relance au délai
  /// court sans qu'on ait à l'orchestrer.
  void _scheduleRestart([Duration delay = _restartDelay]) {
    if (!_wanted) return;
    _restart?.cancel();
    diagnose('speech_restart_scheduled', {'in_ms': delay.inMilliseconds});
    _restart = Timer(delay, () {
      _idlePasses = 0;
      final listening = _speech.isListening;
      diagnose('speech_restart_due', {'listening': listening});
      if (_wanted && !listening) unawaited(_listen());
    });
  }

  Future<void> stop() async {
    diagnose('speech_stop');
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
