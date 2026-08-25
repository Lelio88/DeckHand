/// Le son d'une page qui tourne, et qui le déclenche.
///
/// **Le calque sonne parce qu'un classeur fait du bruit.** Un feuilletage muet
/// se regarde ; un feuilletage qui froisse se *voit* mieux — c'est le même
/// principe que l'ombre portée sous une feuille levée, un indice de matière.
///
/// **Rien n'est joué sur mobile, et rien n'y échoue non plus.** Le calque est
/// une *browser source* OBS : le seul endroit où il tourne est le web. L'import
/// conditionnel donne une implémentation silencieuse partout ailleurs, y compris
/// sous `flutter test` — aucun test n'a donc à se protéger de l'audio.
///
/// **Il n'y a pas de réglage de volume, et c'est délibéré.** OBS range une
/// *browser source* dans sa table de mixage : la couper, la baisser ou la
/// router se fait là, avec le reste du direct. Un second réglage dans l'URL
/// serait un endroit de plus où chercher quand le son manque.
///
/// **Le compte des feuilles vit dans `RevealTiming`**, pas ici : le calque et
/// l'aperçu pilotent chacun leur horloge, et deux comptes séparés dériveraient.
/// [RiffleSound] ne fait que traduire « une feuille de plus a tourné » en « joue
/// un froissement », et se teste avec un faux son.
library;

import 'binder_reveal.dart' show RevealTiming;
import 'page_sound_stub.dart'
    if (dart.library.js_interop) 'page_sound_web.dart'
    as impl;

/// Où en est l'audio du navigateur.
///
/// **Un échec muet est acceptable en direct, jamais dans l'outil qui sert à
/// juger le son.** Le calque se tait quand Web Audio refuse — c'est la règle,
/// un direct ne fait pas entendre une erreur de DeckHand. Mais `apercu_montre`
/// existe *pour* écouter : sans cet état, « je n'entends rien » ne distingue pas
/// un navigateur qui attend un clic d'un son mal réglé, et l'on cherche pendant
/// une heure du mauvais côté.
enum PageSoundStatus {
  /// Pas de navigateur. Rien ne sonnera, et c'est normal.
  silencieux,

  /// Aucun froissement n'a encore été demandé.
  attente,

  /// Le contexte existe mais dort : **le navigateur attend un geste**. C'est le
  /// cas par défaut d'un onglet fraîchement ouvert.
  suspendu,

  /// Ça joue.
  actif,

  /// Web Audio a refusé.
  indisponible,
}

/// De quoi faire entendre une page qui tourne.
abstract interface class PageSound {
  /// Joue un froissement. Ne lève jamais : un son manqué ne vaut pas une
  /// erreur à l'antenne.
  void turn();

  /// Ouvre l'audio à la faveur d'un geste de l'utilisateur.
  ///
  /// **Un navigateur refuse de démarrer l'audio sans geste**, et le refus est
  /// silencieux. OBS n'a pas cette règle — une *browser source* joue ses sons
  /// sans qu'on clique — mais un Chrome ordinaire, si. À appeler depuis un
  /// gestionnaire de clic ; ailleurs, cela ne coûte rien et ne fait rien.
  void unlock();

  /// Où en est l'audio — voir [PageSoundStatus].
  PageSoundStatus get status;

  void dispose();
}

/// Le son de la plateforme courante — silencieux hors du web.
PageSound createPageSound() => impl.createPageSound();

/// Fait sonner une feuille à chaque tour, et pas deux fois la même.
///
/// **Un froissement par tour au plus.** Si l'horloge saute — onglet en
/// arrière-plan, image perdue —, deux tours peuvent s'écouler entre deux
/// appels : on n'en joue qu'un. Rattraper le retard ferait crépiter le calque
/// au moment précis où la machine est déjà en peine.
class RiffleSound {
  RiffleSound(this._sound);

  final PageSound _sound;
  int _joues = 0;

  /// Remet le compte à zéro — à appeler au début de chaque apparition.
  void restart() => _joues = 0;

  /// À appeler à chaque image, avec le temps écoulé depuis l'arrivée de la
  /// demande.
  void at(RevealTiming timing, double elapsed) {
    if (timing.riffle <= 0) return;
    final avance = timing.riffleAt(elapsed);
    // Hors du feuilletage, rien ne tourne : ni avant l'ouverture, ni une fois
    // la page posée.
    if (avance <= 0 || avance >= 1) return;

    // Le tour **en cours**, à partir de 1 : le froissement accompagne le
    // départ de la feuille, pas son arrivée.
    final tour = timing.sheetTurnsAt(elapsed) + 1;
    if (tour <= _joues) return;
    _joues = tour;
    _sound.turn();
  }

  void dispose() => _sound.dispose();

  /// Ouvre l'audio à la faveur d'un geste — voir [PageSound.unlock].
  void unlock() => _sound.unlock();

  /// Où en est l'audio.
  PageSoundStatus get status => _sound.status;
}
