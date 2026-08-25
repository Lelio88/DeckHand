/// Écrit un `.wav` du feuilletage, pour l'écouter.
///
/// **Ce que les tests ne peuvent pas dire.** `page_sound_test.dart` vérifie
/// qu'un tampon sonne, ne sature pas, ne claque pas et a la bonne enveloppe —
/// tout ce qui rend un son inutilisable sans qu'on le voie dans le code. Il ne
/// dira jamais si cela *ressemble* à une page qui tourne. Cela s'écoute.
///
/// **L'onde vient de la production, l'assemblage non.** Les échantillons
/// sortent de `pageTurnWave`, celui-là même que le navigateur verse dans son
/// tampon : ce qu'on entend ici est le timbre du direct. La mise bout à bout —
/// six feuilles espacées de `sheetTurn`, avec la même variation de vitesse — est
/// en revanche une **approximation** de ce que fait Web Audio ; c'est une aide à
/// l'écoute, pas un chemin de production, et rien ne la relit.
///
/// **Un fichier par voix.** Ces réglages ne se jugent qu'à l'oreille : les
/// écrire tous les trois permet de dire « celle-ci » plutôt que « pas
/// celui-là ». Seule `papier` est jouée en direct ; les deux autres existent
/// pour la comparaison.
///
/// Il est **sauté par `flutter test`** : il écrit un fichier et n'assère rien.
///
///     cd app && DECKHAND_BENCH=1 flutter test test/ecoute_son_test.dart
///
/// Le fichier atterrit dans `test/apercu/`, hors dépôt.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:deckhand/src/features/binders/presentation/page_sound_wave.dart';
import 'package:flutter_test/flutter_test.dart';

const int _taux = 44100;

/// Rejoue l'onde à une vitesse donnée, par interpolation linéaire — ce que fait
/// `playbackRate` côté navigateur.
List<double> _aLaVitesse(Float32List onde, double vitesse) {
  final n = (onde.length / vitesse).floor();
  return [
    for (var i = 0; i < n; i++)
      () {
        final x = i * vitesse;
        final j = x.floor();
        if (j + 1 >= onde.length) return onde[onde.length - 1].toDouble();
        final f = x - j;
        return onde[j] * (1 - f) + onde[j + 1] * f;
      }(),
  ];
}

Uint8List _wav(List<double> samples) {
  final data = ByteData(44 + samples.length * 2);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, _taux, Endian.little);
  data.setUint32(28, _taux * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(44 + i * 2, v, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test(
    'écrit le feuilletage en .wav, une voix par fichier',
    () async {
      final dossier = Directory('test/apercu')..createSync(recursive: true);

      // **Trois voix côte à côte, et pas une seule.** Ces réglages ne se jugent
      // qu'à l'oreille ; les écrire tous les trois permet de dire « celle-ci »
      // plutôt que « pas celui-là », et c'est la seule façon d'avancer en un
      // aller-retour.
      const voix = <String, PageTurnVoice>{
        'papier': PageTurnVoice.papier,
        'douce': PageTurnVoice.douce,
        'seche': PageTurnVoice.seche,
      };

      for (final entree in voix.entries) {
        final onde = pageTurnWave(_taux, entree.value);
        const feuilles = 6;
        final ecart = (RevealTiming.sheetTurn / 1000 * _taux).round();
        final total = ecart * feuilles + onde.length;
        final piste = List<double>.filled(total, 0);

        // Graine fixe : deux exécutions donnent le même fichier, ce qui permet de
        // comparer deux réglages à l'oreille sans qu'un tirage s'en mêle.
        final tirage = math.Random(1);
        for (var k = 0; k < feuilles; k++) {
          final vitesse = 0.92 + tirage.nextDouble() * 0.2;
          final morceau = _aLaVitesse(onde, vitesse);
          final debut = k * ecart;
          for (var i = 0; i < morceau.length && debut + i < total; i++) {
            piste[debut + i] += morceau[i] * 0.35;
          }
        }

        final fichier = File('${dossier.path}/page-${entree.key}.wav')
          ..writeAsBytesSync(_wav(piste));
        stdout.writeln(
          '  ${fichier.path} — $feuilles feuilles, '
          '${(total / _taux).toStringAsFixed(2)} s',
        );
      }
    },
    skip: Platform.environment['DECKHAND_BENCH'] == null,
  );
}
