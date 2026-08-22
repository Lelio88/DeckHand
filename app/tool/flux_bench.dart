/// Ce qui tue l'empreinte sur un flux caméra, facteur par facteur (#8).
///
/// **La question que ce banc tranche.** Une carte parfaitement centrée et
/// immobile n'est pas reconnue au fil de la caméra, alors que la même carte, en
/// image officielle, tombe à 1 bit de sa référence avec 13 bits de marge. La
/// chaîne est donc saine, et c'est l'image du flux qui pèche — mais *par quoi* ?
/// La résolution, le flou de bougé, l'inclinaison d'une carte tenue à la main,
/// l'éclairage ? Sans le savoir, la seule réponse possible est « tenez le
/// téléphone autrement », et elle ne suffit pas : l'usage visé est de faire
/// défiler les cartes à la main.
///
/// **La méthode.** On part de l'image officielle, dont on sait qu'elle est
/// reconnue, on la pose sur un fond — la détection cherche une forme *sur*
/// quelque chose, une carte sans bord ne lui donne rien —, puis on dégrade un
/// facteur à la fois. Le verdict se lit sur deux seuils du pipeline :
/// `maxTrustedDistance` (12 bits), au-delà duquel l'index se tait, et
/// `minConfidenceMargin` (4 bits), en deçà duquel il refuse de trancher même
/// sous le seuil.
///
/// **Le code est celui de production**, `findCard` et `artHashCandidatesInQuad`,
/// jamais une reproduction : un banc qui approche le pipeline mesurerait autre
/// chose que ce qui tourne.
///
/// **Ce que ce banc ne dit pas.** Il mesure la fragilité de l'**empreinte**, pas
/// celle de la détection : son fond est uni, quand le terrain offre un parquet
/// ou une main. Que la détection perde la carte sur un fond texturé est un
/// chantier distinct, instruit dans l'issue #8 — et c'est pour cela que les
/// deux se mesurent séparément.
///
/// Usage :
/// ```
/// dart run tool/flux_bench.dart <carte.jpg> [--game magic]
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:image/image.dart' as img;

/// Hauteur de la scène telle que le flux la sert, en pixels.
///
/// La caméra tourne en 1280 × 720 ; l'image analysée est donc haute de 720, et
/// la carte n'en occupe qu'une part.
const int fluxSceneHeight = 720;

/// L'empreinte que le pipeline tirerait de cette scène, ou `null`.
///
/// On garde l'hypothèse la mieux placée, comme le fait `searchAny` : c'est le
/// candidat que l'application soumettrait à l'index.
ArtHash? _empreinte(img.Image scene, String game) {
  final quad = findCard(scene, game: game);
  if (quad == null) return null;
  final candidates = artHashCandidatesInQuad(scene, quad, game: game);
  return candidates.values.isEmpty ? null : candidates.values.first;
}

/// La carte posée sur une surface, comme le flux la voit.
///
/// **Ce n'est pas un artifice.** L'image officielle est un carton sans bord ;
/// la détection, qui cherche une forme sur un fond, n'y trouve rien. Sans marge,
/// le banc mesurerait un cas qui n'existe pas.
img.Image _poseSurFond(img.Image carte) {
  final marge = (carte.height * 0.18).round();
  final fond = img.Image(
    width: carte.width + 2 * marge,
    height: carte.height + 2 * marge,
  );
  img.fill(fond, color: img.ColorRgb8(150, 138, 120));
  img.compositeImage(fond, carte, dstX: marge, dstY: marge);
  return fond;
}

img.Image _aLaHauteur(img.Image scene, int hauteur) => img.copyResize(
  scene,
  height: hauteur,
  interpolation: img.Interpolation.average,
);

/// Une carte tenue à la main n'est pas parallèle au capteur.
///
/// Le haut est rétréci d'autant que l'inclinaison l'éloigne. On ne simule pas
/// une optique : ce qui compte est l'ampleur de la déformation que la détection
/// devra rattraper.
img.Image _incline(img.Image scene, double degres) {
  if (degres == 0) return scene;
  final retrait =
      scene.width * (1 - math.cos(degres * math.pi / 180)) / 2;
  final w = (scene.width - 1).toDouble();
  final h = (scene.height - 1).toDouble();
  return img.copyRectify(
    scene,
    topLeft: img.Point(retrait, 0),
    topRight: img.Point(w - retrait, 0),
    bottomLeft: img.Point(0, h),
    bottomRight: img.Point(w, h),
  );
}

void main(List<String> args) {
  final chemin = args.isEmpty ? null : args.first;
  if (chemin == null) {
    stderr.writeln('usage : dart run tool/flux_bench.dart <carte.jpg> [--game magic]');
    exitCode = 64;
    return;
  }
  final i = args.indexOf('--game');
  final game = i >= 0 && i + 1 < args.length ? args[i + 1] : 'magic';

  final carte = img.decodeImage(File(chemin).readAsBytesSync());
  if (carte == null) {
    stderr.writeln('image illisible : $chemin');
    exitCode = 65;
    return;
  }

  final scene = _poseSurFond(carte);
  final reference = _empreinte(scene, game);
  if (reference == null) {
    stderr.writeln('la détection ne trouve rien sur la scène de départ');
    exitCode = 65;
    return;
  }

  print('carte      ${carte.width} × ${carte.height}, posée sur un fond uni');
  print('scène      ${scene.width} × ${scene.height}');
  print('référence  ${reference.toHex()}');
  print('seuils     $maxTrustedDistance bits pour se taire, '
      '$minConfidenceMargin de marge pour trancher');
  print('');

  void ligne(String label, img.Image variante) {
    final empreinte = _empreinte(variante, game);
    if (empreinte == null) {
      print('  ${label.padRight(30)}  carte non détectée');
      return;
    }
    final d = empreinte.distanceTo(reference);
    final verdict = d > maxTrustedDistance
        ? 'MUETTE'
        : (d > maxTrustedDistance - minConfidenceMargin
              ? 'sans marge'
              : 'reconnue');
    print('  ${label.padRight(30)}  ${d.toString().padLeft(3)} bits   $verdict');
  }

  print('résolution — hauteur de la scène analysée');
  for (final h in [1000, 800, 720, 600, 500, 400, 300, 200]) {
    ligne('$h px', _aLaHauteur(scene, h));
  }

  final flux = _aLaHauteur(scene, fluxSceneHeight);
  print('\nflou — à $fluxSceneHeight px, la hauteur du flux');
  for (final r in [1, 2, 3, 4, 6, 8]) {
    ligne('rayon $r px', img.gaussianBlur(flux.clone(), radius: r));
  }

  print('\ninclinaison — carte non parallèle au capteur');
  for (final deg in [5.0, 10.0, 15.0, 20.0, 30.0]) {
    ligne('${deg.round()}°', _incline(flux, deg));
  }

  print('\néclairage — plus sombre que l\'image officielle');
  for (final f in [0.8, 0.6, 0.45, 0.3, 0.2]) {
    ligne('×$f', img.adjustColor(flux.clone(), brightness: f));
  }

  print('\ncumul — ce que produit une main qui tient la carte');
  ligne(
    '720 px + flou 2 + 10° + ×0,6',
    img.adjustColor(
      img.gaussianBlur(_incline(flux, 10).clone(), radius: 2),
      brightness: 0.6,
    ),
  );
}
