/// Le froissement, joué par le navigateur.
///
/// **Web Audio, et aucune dépendance.** Le son est synthétisé
/// (`page_sound_wave.dart`) puis versé dans un tampon que l'on rejoue à chaque
/// feuille : ni paquet audio ajouté au projet, ni fichier à embarquer, ni
/// requête réseau au moment où le direct en a le moins besoin. L'interop tient
/// dans les six types déclarés ci-dessous.
///
/// **Le contexte naît au premier froissement, pas au chargement.** Un
/// navigateur refuse de démarrer l'audio avant un geste de l'utilisateur ; le
/// créer d'avance donnerait un contexte suspendu qu'il faudrait réveiller de
/// toute façon. Dans OBS la question ne se pose pas — une *browser source* joue
/// ses sons sans geste —, mais l'aperçu, lui, s'ouvre dans un Chrome ordinaire.
///
/// **Tout échec est silencieux, et c'est la règle du calque.** Contexte
/// indisponible, tampon refusé, lecture qui échoue : on se tait. Un direct ne
/// doit jamais montrer — ni faire entendre — une erreur de DeckHand.
///
/// **La vitesse de lecture varie d'une feuille à l'autre.** Six froissements
/// rigoureusement identiques à la suite s'entendent comme un mécanisme ; un
/// dixième de variation suffit à les rendre à la matière.
@JS()
library;

import 'dart:js_interop';
import 'dart:math' as math;

import 'page_sound.dart';
import 'page_sound_wave.dart';

PageSound createPageSound() => _WebPageSound();

/// Volume du froissement. Un indice de matière derrière un commentaire, pas un
/// effet sonore : OBS reste le seul endroit où l'on coupe ou l'on baisse.
const double _volume = 0.35;

/// Bornes de la vitesse de lecture, d'une feuille à l'autre.
const double _rateMin = 0.92;
const double _rateMax = 1.12;

class _WebPageSound implements PageSound {
  _AudioContext? _ctx;
  _AudioBuffer? _buffer;
  _GainNode? _master;
  final math.Random _tirage = math.Random();

  /// Vrai dès qu'une tentative a échoué : on n'y revient pas à chaque feuille.
  bool _horsService = false;

  void _ensure() {
    if (_horsService || _ctx != null) return;
    try {
      final ctx = _AudioContext();
      final taux = ctx.sampleRate.round();
      final onde = pageTurnWave(taux);
      final tampon = ctx.createBuffer(1, onde.length, ctx.sampleRate);
      tampon.copyToChannel(onde.toJS, 0);
      final master = ctx.createGain();
      master.gain.value = _volume;
      master.connect(ctx.destination);
      _ctx = ctx;
      _buffer = tampon;
      _master = master;
    } on Object {
      _horsService = true;
    }
  }

  @override
  PageSoundStatus get status {
    if (_horsService) return PageSoundStatus.indisponible;
    final ctx = _ctx;
    if (ctx == null) return PageSoundStatus.attente;
    try {
      return ctx.state == 'running'
          ? PageSoundStatus.actif
          : PageSoundStatus.suspendu;
    } on Object {
      return PageSoundStatus.indisponible;
    }
  }

  @override
  void unlock() {
    _ensure();
    final ctx = _ctx;
    if (ctx == null) return;
    try {
      if (ctx.state != 'running') ctx.resume();
    } on Object {
      // Un réveil refusé n'est pas une panne : le geste suivant réessaiera.
    }
  }

  @override
  void turn() {
    _ensure();
    final ctx = _ctx;
    final tampon = _buffer;
    final master = _master;
    if (ctx == null || tampon == null || master == null) return;
    try {
      // Un contexte suspendu ne joue rien et ne se plaint pas : le réveiller
      // est la seule façon de s'en apercevoir.
      if (ctx.state != 'running') ctx.resume();
      final source = ctx.createBufferSource();
      source.buffer = tampon;
      source.playbackRate.value =
          _rateMin + _tirage.nextDouble() * (_rateMax - _rateMin);
      source.connect(master);
      source.start();
    } on Object {
      // Un froissement manqué ne vaut pas une erreur à l'antenne.
    }
  }

  @override
  void dispose() {
    try {
      _ctx?.close();
    } on Object {
      // Rien à faire d'un contexte qui refuse de se fermer.
    }
    _ctx = null;
    _buffer = null;
    _master = null;
  }
}

// --------------------------------------------------------------------------
// Web Audio, réduit à ce dont le froissement a besoin.
// --------------------------------------------------------------------------

@JS('AudioContext')
extension type _AudioContext._(JSObject _) implements JSObject {
  external _AudioContext();

  external String get state;
  external num get sampleRate;
  external _AudioNode get destination;

  external void resume();
  external void close();
  external _AudioBuffer createBuffer(
    int numberOfChannels,
    int length,
    num sampleRate,
  );
  external _AudioBufferSourceNode createBufferSource();
  external _GainNode createGain();
}

extension type _AudioNode._(JSObject _) implements JSObject {
  external void connect(_AudioNode destination);
}

extension type _AudioBuffer._(JSObject _) implements JSObject {
  external void copyToChannel(JSFloat32Array source, int channelNumber);
}

extension type _AudioParam._(JSObject _) implements JSObject {
  external set value(num v);
}

extension type _AudioBufferSourceNode._(JSObject _)
    implements _AudioNode, JSObject {
  external set buffer(_AudioBuffer value);
  external _AudioParam get playbackRate;
  external void start();
}

extension type _GainNode._(JSObject _) implements _AudioNode, JSObject {
  external _AudioParam get gain;
}
