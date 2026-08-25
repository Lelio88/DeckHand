/// Le froissement d'une page, mesuré — puisqu'on ne peut pas l'écouter ici.
///
/// **Ce qu'un test peut dire d'un son, et ce qu'il ne peut pas.** Il ne dira
/// jamais si cela *ressemble* à une page qui tourne : cela s'écoute
/// (`test/ecoute_son_test.dart` écrit un `.wav` pour ça). Il dit en revanche
/// tout ce qui rend un son inutilisable sans qu'on s'en aperçoive à la lecture
/// du code — un tampon muet, une saturation, une composante continue qui claque
/// à chaque déclenchement, une enveloppe à l'envers.
library;

import 'dart:math' as math;

import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:deckhand/src/features/binders/presentation/page_sound.dart';
import 'package:deckhand/src/features/binders/presentation/page_sound_wave.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un son qui compte au lieu de sonner.
class FauxSon implements PageSound {
  int tours = 0;
  int ouvertures = 0;
  bool ferme = false;

  @override
  void turn() => tours++;

  @override
  void unlock() => ouvertures++;

  @override
  PageSoundStatus get status => PageSoundStatus.actif;

  @override
  void dispose() => ferme = true;
}

double _energie(List<double> x) =>
    x.fold<double>(0, (a, v) => a + v * v) / x.length;

/// Ce qui décrit un timbre sans passer par une transformée.
///
/// **La cadence de passages par zéro tient lieu de brillance.** Elle compte les
/// changements de signe : un son clair en fait beaucoup, un son sourd peu. Ce
/// n'est pas un centroïde spectral, mais elle en suit l'ordre — vérifié sur les
/// trois voix — et elle se calcule en une boucle plutôt qu'en une FFT qu'il
/// faudrait écrire et vérifier.
typedef _Descripteurs = ({
  double duree,
  double creteSurMoyenne,
  double passagesParZero,
});

/// Une somme FNV-1a sur les échantillons quantifiés en 16 bits.
///
/// **Quantifiés, et c'est le point.** Comparer des flottants ferait échouer le
/// test pour un dernier bit qu'aucune oreille ne distingue ; seize bits sont la
/// résolution à laquelle le son est réellement joué.
int _somme(List<double> onde) {
  var h = 0x811c9dc5;
  for (final v in onde) {
    final q = (v.clamp(-1.0, 1.0) * 32767).round() & 0xFFFF;
    h = ((h ^ (q & 0xFF)) * 0x01000193) & 0xFFFFFFFF;
    h = ((h ^ (q >> 8)) * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

_Descripteurs _descripteurs(List<double> onde, [int taux = 48000]) {
  var moyenne = 0.0;
  var crete = 0.0;
  var passages = 0;
  for (var i = 0; i < onde.length; i++) {
    final v = onde[i];
    moyenne += v.abs();
    if (v.abs() > crete) crete = v.abs();
    if (i > 0 && (v >= 0) != (onde[i - 1] >= 0)) passages++;
  }
  moyenne /= onde.length;
  final duree = onde.length / taux;
  return (
    duree: duree,
    creteSurMoyenne: moyenne == 0 ? 0 : crete / moyenne,
    passagesParZero: passages / duree,
  );
}

void main() {
  group("l'onde", () {
    test('dure ce qu_une page met à tourner, quel que soit l_appareil', () {
      // Une longueur en échantillons fixe donnerait un son deux fois plus court
      // sur un appareil à 96 kHz.
      for (final taux in [44100, 48000, 96000]) {
        final onde = pageTurnWave(taux);
        expect(onde.length / taux, closeTo(PageTurnVoice.papier.seconds, 1e-3));
      }
    });

    test('les trois voix sont réellement différentes', () {
      // Trois préréglages qui rendraient le même son ne serviraient à rien —
      // et c_est exactement ce qui arrive si un paramètre est branché mais
      // jamais lu.
      final ondes = [
        pageTurnWave(48000, PageTurnVoice.papier),
        pageTurnWave(48000, PageTurnVoice.douce),
        pageTurnWave(48000, PageTurnVoice.seche),
      ];
      for (var i = 0; i < ondes.length; i++) {
        for (var j = i + 1; j < ondes.length; j++) {
          expect(ondes[i], isNot(ondes[j]));
        }
      }
      // La sèche est la plus courte, la douce la plus longue.
      expect(ondes[2].length, lessThan(ondes[0].length));
      expect(ondes[1].length, greaterThan(ondes[0].length));
    });

    test('elle craque : le son n_est pas un souffle lisse', () {
      // **Le défaut de la première version, tenu par un test.** Du bruit filtré
      // sous une enveloppe donne un « chhh » ; ce qui fait le papier, ce sont
      // des chocs. Un train d_impulsions a des pics bien au-dessus de sa propre
      // moyenne — un souffle lisse, non.
      final onde = pageTurnWave(48000);
      final moyenneAbs =
          onde.fold<double>(0, (a, v) => a + v.abs()) / onde.length;
      var crete = 0.0;
      for (final v in onde) {
        crete = math.max(crete, v.abs());
      }
      // Facteur de crête : au-delà de 6, le signal est fait d_événements et non
      // d_un souffle continu.
      expect(crete / moyenneAbs, greaterThan(6));
    });

    test('elle sonne, sans saturer', () {
      final onde = pageTurnWave(48000);
      var crete = 0.0;
      for (final v in onde) {
        expect(v.isFinite, isTrue);
        crete = math.max(crete, v.abs());
      }
      // Normalisée : la crête touche 1 sans le dépasser. En dessous, le
      // froissement passerait sous le commentaire ; au-dessus, il claquerait.
      expect(crete, closeTo(1, 1e-3));
    });

    test('elle ne porte pas de composante continue', () {
      // **Ce qui claque n_est pas le son, c_est son départ.** Un tampon dont la
      // moyenne n_est pas nulle saute à zéro à la fin de la lecture, et l_on
      // entend un clic à chaque feuille.
      final onde = pageTurnWave(48000);
      final moyenne = onde.fold<double>(0, (a, v) => a + v) / onde.length;
      expect(moyenne.abs(), lessThan(0.01));
      expect(onde.first.abs(), lessThan(0.01));
      expect(onde.last.abs(), lessThan(0.01));
    });

    test('elle part de zéro et y revient, et son cœur porte l_énergie', () {
      // L_enveloppe en fuseau est ce qui distingue un geste d_un interrupteur.
      // **Les tout premiers et tout derniers échantillons**, pas les dixièmes :
      // le crépitement commence au relâchement et reprend à la pose, si bien
      // que l_énergie n_est pas une cloche. Ce qui doit rester vrai, c_est que
      // le tampon **part de zéro et y revient** — sans quoi il claque.
      final onde = pageTurnWave(48000).toList();
      final n = onde.length;
      // Les extrémités, au sens strict : un tampon qui ne part ni ne finit à
      // zéro claque au déclenchement et à la fin de la lecture.
      expect(onde.first.abs(), lessThan(1e-6));
      expect(onde.last.abs(), lessThan(1e-6));
      final coeur = _energie(onde.sublist(n * 3 ~/ 10, n * 7 ~/ 10));
      final bords = _energie([
        ...onde.sublist(0, n ~/ 400),
        ...onde.sublist(n - n ~/ 400),
      ]);
      expect(coeur, greaterThan(bords * 10));
    });

    test('elle est la même d_une session à l_autre', () {
      // Un timbre qui change tout seul est un défaut, pas une variété : celle-ci
      // vient de la vitesse de lecture.
      expect(pageTurnWave(48000), pageTurnWave(48000));
    });
  });

  group("l'empreinte de la voix retenue", () {
    // **Les descripteurs, mesurés à 48 kHz.** La synthèse est déterministe :
    // à taux d'échantillonnage fixé, ces chiffres sont reproductibles au bit
    // près. La tolérance de 3 % n'est pas du bruit de mesure — c'est la marge
    // sous laquelle un changement de timbre reste inaudible.
    const duree = 0.260;
    const creteSurMoyenne = 9.68;
    const passagesParZero = 3377.0;
    const marge = 0.03;

    // Les deux taux d'échantillonnage qu'un navigateur peut rendre.
    const somme48k = 2430232646;
    const somme44k = 3634615535;

    test('elle n_a pas bougé — au bit près', () {
      // **Le seul contrôle complet, et il a fallu le prouver.** Une première
      // version ne comparait que les trois descripteurs ci-dessus : essai fait,
      // `crackleHz` déplacé de 1 400 à 1 800 Hz — vingt-neuf pour cent — et le
      // test passait au vert, parce que le passe-bas final masque la résonance
      // et que la cadence de passages par zéro n_y est pas sensible. **Un
      // garde-fou qui ne se déclenche jamais est pire que pas de garde-fou.**
      //
      // La synthèse étant déterministe (graine fixe), une somme sur les
      // échantillons quantifiés en 16 bits couvre *tous* les réglages, pas
      // seulement ceux qu_un descripteur sait voir. Quantifiés, parce que la
      // résolution audible est là : un dernier bit de flottant qui bougerait
      // sur une autre machine ferait échouer un test pour un son identique.
      //
      // Pour changer la voix volontairement : écouter
      // (`DECKHAND_BENCH=1 flutter test test/ecoute_son_test.dart`), décider,
      // **puis** remettre ces chiffres à jour. Jamais l_inverse.
      expect(
        _somme(pageTurnWave(48000)),
        somme48k,
        reason:
            'le son retenu a changé. Si c_est voulu : réécouter les .wav, '
            'décider, puis mettre à jour cette valeur.',
      );
      expect(_somme(pageTurnWave(44100)), somme44k);
    });

    test('et les descripteurs disent en quoi', () {
      // **La somme dit *que* le son a changé, ceux-ci disent *comment*.** Sans
      // eux, un échec de l_empreinte n_apprend rien : ils nomment la durée, le
      // grain et la brillance, qui sont les trois choses dont on parle quand on
      // écoute.
      final mesure = _descripteurs(pageTurnWave(48000));
      expect(
        mesure.duree,
        closeTo(duree, 1e-4),
        reason: 'la durée du froissement a changé',
      );
      expect(
        mesure.creteSurMoyenne,
        closeTo(creteSurMoyenne, creteSurMoyenne * marge),
        reason: 'le grain a changé : plus (ou moins) de craquements',
      );
      expect(
        mesure.passagesParZero,
        closeTo(passagesParZero, passagesParZero * marge),
        reason: 'la brillance a changé : le son est plus clair ou plus sourd',
      );
    });

    test('le descripteur distingue vraiment les trois voix', () {
      // **Sans ceci, l_empreinte ci-dessus ne prouverait rien.** Un descripteur
      // qui rendrait la même valeur pour la voix douce, celle de référence et
      // la sèche ne détecterait aucun changement de timbre.
      final douce = _descripteurs(pageTurnWave(48000, PageTurnVoice.douce));
      final retenue = _descripteurs(pageTurnWave(48000));
      final seche = _descripteurs(pageTurnWave(48000, PageTurnVoice.seche));

      expect(douce.passagesParZero, lessThan(retenue.passagesParZero));
      expect(retenue.passagesParZero, lessThan(seche.passagesParZero));
      // Et l_écart est large : un tiers au moins de part et d_autre.
      expect(retenue.passagesParZero / douce.passagesParZero, greaterThan(1.3));
      expect(seche.passagesParZero / retenue.passagesParZero, greaterThan(1.3));
    });
  });

  group('qui déclenche le froissement', () {
    test('une feuille, un son', () {
      const t = RevealTiming(48);
      final faux = FauxSon();
      final cue = RiffleSound(faux);

      // Rien avant l_ouverture.
      cue.at(t, 0);
      cue.at(t, RevealTiming.open);
      expect(faux.tours, 0);

      // Le premier tour sonne dès que la feuille part, pas quand elle arrive.
      cue.at(t, RevealTiming.open + 1);
      expect(faux.tours, 1);

      // Le même tour ne sonne pas deux fois.
      cue.at(t, RevealTiming.open + 30);
      cue.at(t, RevealTiming.open + 60);
      expect(faux.tours, 1);

      // Le suivant, si.
      cue.at(t, RevealTiming.open + RevealTiming.sheetTurn + 1);
      expect(faux.tours, 2);
    });

    test('un saut d_horloge ne fait pas crépiter', () {
      // Onglet en arrière-plan, images perdues : trois tours peuvent s_écouler
      // entre deux appels. Rattraper le retard ferait crépiter le calque au
      // moment où la machine est déjà en peine.
      const t = RevealTiming(48);
      final faux = FauxSon();
      RiffleSound(faux)
        ..at(t, RevealTiming.open + 1)
        ..at(t, RevealTiming.open + RevealTiming.sheetTurn * 4);
      expect(faux.tours, 2);
    });

    test('une animation réelle, à soixante images par seconde, sonne', () {
      // **Le contrôle qui répond à « je n_entends rien ».** Les autres tests
      // interrogent le déclencheur à des instants choisis ; celui-ci le pilote
      // comme le fait le contrôleur d_animation, du début à la fin, et compte.
      // Un déclencheur qui ne se réveillerait jamais passerait tous les autres.
      const t = RevealTiming(48);
      final faux = FauxSon();
      final cue = RiffleSound(faux);
      final images = (t.total / (1000 / 60)).ceil();
      for (var i = 0; i <= images; i++) {
        cue.at(t, t.total * i / images);
      }
      expect(faux.tours, greaterThan(0));
      // Environ une par tour de feuille, à une près : le premier tour sonne
      // dès le départ, le dernier peut être incomplet.
      expect(faux.tours, closeTo(t.riffle / RevealTiming.sheetTurn, 1.5));
    });

    test('rien ne sonne une fois la page posée', () {
      const t = RevealTiming(48);
      final faux = FauxSon();
      RiffleSound(faux).at(t, t.total);
      expect(faux.tours, 0);
    });

    test('une carte de la page 1 ne feuillette pas, donc ne sonne pas', () {
      const t = RevealTiming(1);
      final faux = FauxSon();
      final cue = RiffleSound(faux);
      for (var i = 0; i <= 20; i++) {
        cue.at(t, t.total * i / 20);
      }
      expect(faux.tours, 0);
    });

    test('le compte repart à chaque apparition', () {
      const t = RevealTiming(48);
      final faux = FauxSon();
      final cue = RiffleSound(faux)..at(t, RevealTiming.open + 1);
      cue.restart();
      cue.at(t, RevealTiming.open + 1);
      expect(faux.tours, 2);
    });
  });

  group('le compte des tours', () {
    test('il suit le temps, pas le nombre de pages', () {
      const t = RevealTiming(48);
      expect(t.sheetTurnsAt(RevealTiming.open), 0);
      expect(
        t.sheetTurnsAt(RevealTiming.open + t.riffle),
        (t.riffle / RevealTiming.sheetTurn).floor(),
      );
      // Une page proche fait moins de tours qu_une page lointaine.
      const proche = RevealTiming(6);
      expect(
        proche.sheetTurnsAt(proche.total),
        lessThan(t.sheetTurnsAt(t.total)),
      );
    });
  });
}
