/// Le froissement d'une page qui tourne, synthétisé échantillon par échantillon.
///
/// **Rien n'est chargé, et c'est le même garde-fou que pour le dos des cartes.**
/// Un enregistrement de page qui tourne est l'œuvre de quelqu'un ; le projet ne
/// réhéberge rien (§IV.3).
///
/// **Trois voix, pas une — et c'est ce qui manquait à la première version.**
/// Elle était faite d'une seule chose : du bruit blanc passé dans un filtre à un
/// pôle, sous une enveloppe en cloche. Cela donne un « chhh » — un souffle, pas
/// du papier. Ce qui fait qu'une page *sonne* comme du papier tient à trois
/// gestes distincts, et il faut les trois :
///
/// 1. **Le crépitement.** Une feuille qu'on relâche ne siffle pas, elle
///    craque : des centaines de micro-ruptures de fibres, chacune un choc
///    minuscule. On le modélise par un train d'impulsions clairsemé — rare, pas
///    du bruit continu — passé dans un résonateur. C'est *la* chose absente de
///    la première version, et c'est elle qui manque à un souffle pour devenir
///    une matière.
/// 2. **L'air.** Le déplacement de la feuille, du bruit large sous un
///    passe-bande dont la fréquence **monte puis redescend** : la feuille prend
///    de la vitesse, puis s'arrête.
/// 3. **La pose.** Le contact final, une basse très courte. Sans elle le son
///    n'aboutit nulle part et l'oreille reste en attente — c'est ce qui rend
///    un bruitage « insatisfaisant » sans qu'on sache dire pourquoi.
///
/// **Et une quatrième chose, qui est ce que « ASMR » veut dire techniquement :
/// la douceur.** Un passe-bas final ôte le haut du spectre. Sans lui, le
/// crépitement est *sifflant* — précis, mais désagréable à volume d'écoute.
/// C'est [PageTurnVoice.softness].
///
/// **Ce fichier ne connaît ni le navigateur ni l'audio.** Il rend des
/// échantillons ; `page_sound_web.dart` les verse dans un tampon Web Audio, un
/// test les écrit dans des `.wav` pour qu'on les écoute. Aucun jumeau : la
/// synthèse existe **une fois**, et ce qu'on entend au casque est exactement ce
/// que le direct joue.
///
/// **Les réglages ne peuvent pas se juger autrement qu'à l'oreille**, et il faut
/// le dire : ils viennent de ce qu'est physiquement le son, pas d'une écoute.
/// D'où trois voix préréglées plutôt qu'une — [PageTurnVoice.papier],
/// [PageTurnVoice.douce], [PageTurnVoice.seche] — et un test qui écrit les
/// trois côte à côte :
///
/// ```bash
/// cd app && DECKHAND_BENCH=1 flutter test test/ecoute_son_test.dart
/// ```
///
/// **Le tirage est déterministe.** Une graine fixe : le tampon est calculé une
/// fois par session et rejoué à chaque feuille. La variété entre deux feuilles
/// vient de la vitesse de lecture, pas d'une nouvelle synthèse.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Les réglages d'un froissement.
///
/// Chaque champ est une grandeur physique, pas un coefficient : une fréquence
/// en hertz, une densité d'impulsions par seconde, une proportion. C'est ce qui
/// permet de les discuter à l'oreille sans lire le code.
@immutable
class PageTurnVoice {
  const PageTurnVoice({
    this.seconds = 0.26,
    this.airLow = 500,
    this.airHigh = 2000,
    this.crackleHz = 1400,
    this.crackleQ = 1.6,
    this.cracklePerSecond = 1100,
    this.crackleMix = 0.7,
    this.thumpHz = 92,
    this.thumpMix = 0.30,
    this.softnessHz = 1300,
  });

  /// Durée totale, en secondes. Une feuille de classeur met environ un quart de
  /// seconde à passer, pose comprise.
  final double seconds;

  /// Bornes du balayage du passe-bande de l'air, en hertz. La fréquence monte
  /// jusqu'au sommet du geste puis redescend.
  final double airLow;
  final double airHigh;

  /// Où résonne le crépitement, et avec quelle finesse. Plus le `Q` est haut,
  /// plus chaque craquement sonne comme une note ; au-delà de 3 cela siffle.
  final double crackleHz;
  final double crackleQ;

  /// Combien de craquements par seconde au sommet du geste. C'est le réglage
  /// qui décide entre « une feuille de papier » (quelques centaines) et « du
  /// papier de soie froissé » (plusieurs milliers).
  final double cracklePerSecond;

  /// Part du crépitement dans le mélange ; le reste est l'air.
  final double crackleMix;

  /// La pose : fréquence et poids du contact final.
  final double thumpHz;
  final double thumpMix;

  /// Douceur : la coupure du passe-bas final, en hertz.
  ///
  /// **C'est le réglage qui décide entre « agréable » et « sifflant »**, et il
  /// se mesure. Une première version le laissait à ~3 900 Hz : le banc spectral
  /// rendait un centroïde de 3,8 kHz et 15 % de l'énergie au-dessus de 7 kHz,
  /// c'est-à-dire un son *précis et désagréable*. Un froissement de page
  /// enregistré de près a son centre de gravité vers 1,5–2 kHz. Voir
  /// `test/ecoute_son_test.dart`, dont le banc rend ces trois chiffres.
  final double softnessHz;

  /// **La voix retenue** — celle que le direct joue, choisie à l'oreille le
  /// 2026-08-25 parmi les trois écrites côte à côte.
  ///
  /// **Ne pas la modifier par inadvertance.** Ses réglages ne sont plus des
  /// hypothèses : ils sont une décision. `page_sound_test.dart` en fige
  /// l'empreinte — durée, facteur de crête, cadence de passages par zéro — et
  /// échoue si l'un d'eux bouge. La bonne façon de la changer est d'écouter, de
  /// décider, **puis** de mettre les chiffres à jour ; la mauvaise est de
  /// toucher une constante et de voir la suite passer au vert.
  ///
  /// Mesurée à 48 kHz : centroïde 2 335 Hz, 6,7 % d'énergie au-dessus de
  /// 7 kHz, 3 377 passages par zéro par seconde.
  static const PageTurnVoice papier = PageTurnVoice();

  /// Plus feutrée : moins de craquements, plus de corps, le haut du spectre
  /// ôté. Pour une écoute proche, au casque.
  ///
  /// **Gardée bien que non retenue.** Elle et [seche] encadrent [papier] — 2 267
  /// et 5 580 passages par zéro contre 3 377 : c'est cet encadrement qui a
  /// permis de trancher en une écoute, et c'est de lui que repartirait un
  /// réglage futur. Elles servent aussi à prouver que l'empreinte du test n'est
  /// pas vide de sens : un descripteur qui ne distinguerait pas ces trois-là ne
  /// distinguerait rien.
  static const PageTurnVoice douce = PageTurnVoice(
    seconds: 0.30,
    airLow: 380,
    airHigh: 1400,
    crackleHz: 900,
    crackleQ: 1.2,
    cracklePerSecond: 600,
    crackleMix: 0.55,
    thumpMix: 0.36,
    softnessHz: 800,
  );

  /// Plus sèche et plus nette : le papier rigide d'une carte, pas d'une page de
  /// livre. Pour un direct où le commentaire couvre le calque — elle est la
  /// seule des trois à assumer d'être brillante.
  static const PageTurnVoice seche = PageTurnVoice(
    seconds: 0.20,
    airLow: 900,
    airHigh: 3000,
    crackleHz: 2800,
    crackleQ: 2.2,
    cracklePerSecond: 1800,
    crackleMix: 0.85,
    thumpMix: 0.15,
    softnessHz: 3900,
  );
}

/// Graine du bruit. Fixe, pour que le son soit le même d'une session à l'autre
/// — un timbre qui change tout seul est un défaut, pas une variété.
const int pageTurnSeed = 20260825;

/// Durée de la voix de référence, en secondes. Raccourci commode : le tempo du
/// feuilletage se règle contre elle.
const double pageTurnSeconds = 0.26;

/// Les échantillons d'une page qui tourne, normalisés à ±1.
///
/// [sampleRate] est celui du contexte audio : le son garde sa durée réelle quel
/// que soit l'appareil, ce qu'une longueur en échantillons fixe ne ferait pas.
Float32List pageTurnWave(
  int sampleRate, [
  PageTurnVoice voice = PageTurnVoice.papier,
]) {
  final n = math.max(1, (sampleRate * voice.seconds).round());
  final tirage = math.Random(pageTurnSeed);
  final out = Float32List(n);

  final air = _Biquad();
  final crack = _Biquad()
    ..bandPass(voice.crackleHz, voice.crackleQ, sampleRate);

  // Le passe-bande de l'air balaie : on ne recalcule ses coefficients que tous
  // les 64 échantillons. Les recalculer à chaque pas coûterait un sinus et un
  // cosinus par échantillon pour une différence inaudible ; ne jamais les
  // recalculer donnerait un souffle immobile.
  const pasBalayage = 64;

  // Le passe-bas final, exprimé en coupure plutôt qu'en coefficient : c'est la
  // conversion d'un filtre à un pôle, et elle vaut d'être écrite une fois
  // plutôt que devinée à chaque réglage.
  final douceurA = 1 - math.exp(-2 * math.pi * voice.softnessHz / sampleRate);

  var douceur = 0.0;
  var crete = 0.0;

  for (var i = 0; i < n; i++) {
    final u = (i + 0.5) / n;

    // Le geste : nul aux deux bouts, plein au milieu.
    final geste = math.sin(math.pi * u);

    if (i % pasBalayage == 0) {
      final f = voice.airLow + (voice.airHigh - voice.airLow) * geste;
      air.bandPass(f, 0.9, sampleRate);
    }

    // 1. L'air — bruit large sous un passe-bande qui balaie.
    final souffle =
        air.process(tirage.nextDouble() * 2 - 1) *
        math.pow(geste, 1.3).toDouble();

    // 2. Le crépitement — des chocs rares, pas du bruit continu. La densité est
    // forte au relâchement puis décroît, avec un regain à la pose : c'est la
    // chronologie d'une feuille qu'on lâche.
    final densite =
        math.exp(-u * 3.2) * 0.8 + 0.4 * math.exp(-_carre(u - 0.86) / 0.006);
    final chance = voice.cracklePerSecond * densite / sampleRate;
    final choc = tirage.nextDouble() < chance
        ? (tirage.nextDouble() * 2 - 1)
        : 0.0;
    final craquement = crack.process(choc);

    // 3. La pose — une basse très courte, qui donne une fin au geste.
    var contact = 0.0;
    if (u > 0.78) {
      final t = (u - 0.78) * voice.seconds;
      contact =
          math.sin(2 * math.pi * voice.thumpHz * t) * math.exp(-t / 0.035);
    }

    final brut =
        souffle * (1 - voice.crackleMix) +
        craquement * voice.crackleMix +
        contact * voice.thumpMix;

    // 4. La douceur — sans ce passe-bas, le crépitement siffle.
    douceur += douceurA * (brut - douceur);
    out[i] = douceur;
    final abs = douceur.abs();
    if (abs > crete) crete = abs;
  }

  if (crete > 0) {
    for (var i = 0; i < n; i++) {
      out[i] = out[i] / crete;
    }
  }
  // Les deux extrémités sont ramenées à zéro : un tampon qui ne commence ni ne
  // finit à zéro claque au déclenchement et à la fin de la lecture.
  _fondu(out, math.max(1, (sampleRate * 0.002).round()));
  return out;
}

double _carre(double x) => x * x;

/// Ramène le début et la fin à zéro.
void _fondu(Float32List x, int longueur) {
  final l = math.min(longueur, x.length ~/ 2);
  for (var i = 0; i < l; i++) {
    final f = i / l;
    x[i] *= f;
    x[x.length - 1 - i] *= f;
  }
}

/// Un filtre biquad, réduit au passe-bande dont la synthèse a besoin.
///
/// **Deux pôles, et pas un.** Un filtre à un pôle — la première version — n'a
/// pas de bande : il ne fait qu'incliner le spectre, si bien que le bruit reste
/// du bruit. C'est un passe-bande qui donne au souffle une *couleur*, et au
/// craquement sa résonance.
class _Biquad {
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  /// Passe-bande à gain de crête unitaire (recette RBJ).
  void bandPass(double f0, double q, int sampleRate) {
    final w0 = 2 * math.pi * f0.clamp(20.0, sampleRate / 2.2) / sampleRate;
    final alpha = math.sin(w0) / (2 * q);
    final a0 = 1 + alpha;
    _b0 = alpha / a0;
    _b1 = 0;
    _b2 = -alpha / a0;
    _a1 = -2 * math.cos(w0) / a0;
    _a2 = (1 - alpha) / a0;
  }

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}
