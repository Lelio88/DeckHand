/// Banc de poste de travail pour le coût d'une image (issue #8).
///
///     cd app && dart run tool/frame_bench.dart
///
/// **Ce qu'il mesure, et ce qu'il ne mesure pas.** Il chronomètre exactement le
/// code que le téléphone exécutera — `lumaImage`, `rgbImage`, `computeArtHash`,
/// `ArtHashIndex.search` — mais sur un processeur de bureau. Les durées
/// absolues ne transfèrent pas : un cœur de téléphone est plusieurs fois plus
/// lent, et Dart y tourne en AOT là où il tourne ici en JIT.
///
/// **Le rapport entre les chemins, lui, transfère**, et c'est la décision à
/// prendre : lire le plan de luminance découpé, ou convertir en RGB.
///
/// La distance entre les deux empreintes est nulle **ici seulement**, parce que
/// la chrominance de synthèse est neutre : la conversion RGB n'écrête donc
/// jamais. Sur un vrai capteur elle écrête, et l'écart monte — c'est la perte du
/// détour, mesurée par le banc embarqué, et une raison de plus de ne pas le
/// prendre.
///
/// Le banc embarqué (`--dart-define=DECKHAND_BENCH=true`) donne les durées
/// réelles. Celui-ci répond avant lui à la question de conception, et sert de
/// garde-fou : si un jour le rapport s'inverse, c'est que le code a changé.
library;

// Ce fichier n'est pas embarqué : c'est un banc de mesure lancé à la main,
// et sa sortie EST son résultat. Le journal de diagnostic vise l'appareil,
// pas un terminal.
// ignore_for_file: avoid_print

import 'dart:math';
import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/camera_frame.dart';

/// Résolutions plausibles pour un flux de reconnaissance.
const _frames = [
  (name: 'ResolutionPreset.medium', width: 720, height: 480),
  (name: 'ResolutionPreset.high', width: 1280, height: 720),
  (name: 'ResolutionPreset.veryHigh', width: 1920, height: 1080),
];

/// L'index Magic embarqué compte environ 31 600 entrées.
const _indexSize = 31600;

const _iterations = 40;
const _warmup = 8;

void main() {
  final random = Random(20260816);
  final index = ArtHashIndex.fromEntries([
    for (var i = 0; i < _indexSize; i++)
      (
        oracleId: 'card-$i',
        hash: ArtHash(
          Uint8List.fromList([for (var b = 0; b < hashBytes; b++) random.nextInt(256)]),
        ),
      ),
  ]);

  print('index : $_indexSize entrées · $_iterations itérations · $_warmup rodage');
  print('');
  print(
    '${'résolution'.padRight(26)}'
    '${'luma'.padLeft(9)}${'rgb'.padLeft(9)}${'rgb_plein'.padLeft(11)}'
    '${'empreinte'.padLeft(11)}${'recherche'.padLeft(11)}'
    '${'total luma'.padLeft(12)}${'total rgb'.padLeft(11)}',
  );

  for (final frame in _frames) {
    final planes = _syntheticFrame(frame.width, frame.height, random);
    final art = CardFrame.modern.box;
    final crop = (
      left: (art.left * frame.width).round(),
      top: (art.top * frame.height).round(),
      width: ((art.right - art.left) * frame.width).round(),
      height: ((art.bottom - art.top) * frame.height).round(),
    );

    late ArtHash fromRgb;

    final tLumaOnly = _timeMicros(() {
      lumaImage(
        planes.luma,
        width: frame.width,
        height: frame.height,
        rowStride: frame.width,
        crop: crop,
      );
    });

    final tRgbOnly = _timeMicros(() {
      fromRgb = computeArtHash(
        rgbImage(
          planes.luma,
          planes.u,
          planes.v,
          width: frame.width,
          height: frame.height,
          lumaRowStride: frame.width,
          chromaRowStride: frame.width ~/ 2,
          chromaPixelStride: 1,
          crop: crop,
        ),
      );
    });

    final tRgbFull = _timeMicros(() {
      rgbImage(
        planes.luma,
        planes.u,
        planes.v,
        width: frame.width,
        height: frame.height,
        lumaRowStride: frame.width,
        chromaRowStride: frame.width ~/ 2,
        chromaPixelStride: 1,
      );
    });

    final grey = lumaImage(
      planes.luma,
      width: frame.width,
      height: frame.height,
      rowStride: frame.width,
      crop: crop,
    );
    final tHash = _timeMicros(() => computeArtHash(grey));
    final fromLuma = computeArtHash(grey);
    final query = fromLuma;
    final tSearch = _timeMicros(() => index.search(query));

    print(
      '${frame.name.padRight(26)}'
      '${_ms(tLumaOnly).padLeft(9)}'
      '${_ms(tRgbOnly - tHash).padLeft(9)}'
      '${_ms(tRgbFull).padLeft(11)}'
      '${_ms(tHash).padLeft(11)}'
      '${_ms(tSearch).padLeft(11)}'
      '${_ms(tLumaOnly + tHash + tSearch).padLeft(12)}'
      '${_ms(tRgbOnly + tSearch).padLeft(11)}',
    );

    // La question qui ne dépend d'aucune machine : les deux chemins
    // rendent-ils la même empreinte ? L'index est calculé sur du RGB.
    final distance = fromLuma.distanceTo(fromRgb);
    print(
      '  ↳ empreintes : luma ${fromLuma.toHex()} · rgb ${fromRgb.toHex()} · '
      'distance $distance bit${distance > 1 ? 's' : ''} '
      '(seuil de confiance : $maxTrustedDistance)',
    );
  }
}

({Uint8List luma, Uint8List u, Uint8List v}) _syntheticFrame(
  int width,
  int height,
  Random random,
) {
  final luma = Uint8List(width * height);
  for (var i = 0; i < luma.length; i++) {
    luma[i] = random.nextInt(256);
  }
  final chroma = Uint8List((width ~/ 2) * (height ~/ 2));
  for (var i = 0; i < chroma.length; i++) {
    chroma[i] = 128;
  }
  return (luma: luma, u: chroma, v: chroma);
}

int _timeMicros(void Function() body) {
  for (var i = 0; i < _warmup; i++) {
    body();
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < _iterations; i++) {
    body();
  }
  return watch.elapsedMicroseconds ~/ _iterations;
}

String _ms(int micros) => '${(micros / 1000).toStringAsFixed(1)} ms';
