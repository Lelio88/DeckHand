/// La carte se voit-elle à ses quatre droites ? (#8)
///
/// Banc de recette du chantier de détection. Il joue trois chaînes sur les
/// mêmes images — la production (clarté), et Hough — et compte deux choses qui
/// comptent autant l'une que l'autre : les cartes trouvées, et les cartes
/// **inventées** sur un fond qui n'en porte aucune.
///
/// Le second chiffre est le juge. Une chaîne qui trouve tout en inventant la
/// moitié est pire que celle qui ne trouve rien : l'utilisateur décoche à la
/// main ce qu'il n'a jamais montré.
///
/// Usage :
/// ```
/// dart run tool/hough_bench.dart <dossier de photos>
/// dart run tool/hough_bench.dart <dossier> --sans-carte
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:image/image.dart' as img;

import 'package:deckhand/src/features/scan/domain/card_edges.dart';

/// Part de l'image occupée par le quadrilatère — le juge visuel en un nombre.
double _part(CardQuad q, int w, int h) {
  double d(({double x, double y}) a, ({double x, double y}) b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
  return d(q.topLeft, q.topRight) * d(q.topRight, q.bottomRight) / (w * h);
}

/// La même photo, vue comme le flux caméra la verrait.
///
/// **Pourquoi cette variante existe.** Le mode vidéo ne reçoit pas une image
/// couleur mais un plan de luminance ; le matérialiser en RGB coûte 10,4 ms sur
/// l'appareil, mesuré, avant même que la détection commence. Or c'est le
/// gradient sur les trois canaux qui a débloqué la détection sur fond sombre :
/// il faut donc savoir ce que la chaîne vaut sans lui, avant de promettre au
/// flux le gain mesuré sur la photo.
img.Image _enLuminance(img.Image photo) {
  final gris = photo.clone();
  for (var y = 0; y < gris.height; y++) {
    for (var x = 0; x < gris.width; x++) {
      final p = gris.getPixel(x, y);
      final l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      gris.setPixelRgb(x, y, l, l, l);
    }
  }
  return gris;
}

img.Image _reduite(img.Image photo) => img.copyResize(
  photo,
  width: analysisWidth,
  interpolation: img.Interpolation.average,
);

int gMaxLines = 24;
double gMinSupport = 0.85;
double gMinArea = 0.06;
double gTol = 0.12;
/// Doit suivre `_supportSansCouple` de la production, sans quoi le banc
/// mesure un autre réglage que celui qui tourne.
double gSc = 0.90;

CardQuad? _parHough(img.Image photo, String game) =>
    _parHoughReduite(_reduite(photo), game);

CardQuad? _parHoughReduite(img.Image small, String game) {
  final champ = dominantLines(small, maxLines: gMaxLines);
  return bestQuad(
    champ.lines,
    champ.edges,
    champ.width,
    champ.height,
    game,
    minSupport: gMinSupport,
    minArea: gMinArea,
    aspectTol: gTol,
    supportPartiel: gSc,
  );
}

/// Balaye support × aire minimale sur les deux populations à la fois.
///
/// **Les deux ensemble, jamais l'une sans l'autre.** Un réglage qui trouve
/// seize cartes en en inventant quatre est pire que celui qui n'en trouve
/// aucune : l'utilisateur décoche à la main ce qu'il n'a jamais montré.
void _balayage(List<File> fichiers) {
  final avec = <img.Image>[];
  final sans = <img.Image>[];
  for (final f in fichiers) {
    final photo = img.decodeImage(f.readAsBytesSync());
    if (photo == null) continue;
    avec.add(_reduite(photo));
    sans.add(
      _reduite(
        img.copyCrop(
          photo,
          x: 0,
          y: 0,
          width: (photo.width * 0.33).round(),
          height: (photo.height * 0.33).round(),
        ),
      ),
    );
  }
  print('${avec.length} photos · ${sans.length} fonds');
  print('');
  print('  support  tolérance  trouvées  médiane  INVENTÉES');
  for (final sup in [0.74, 0.78, 0.82]) {
    for (final tol in [0.05, 0.07, 0.09, 0.12]) {
      gMinSupport = sup;
      gTol = tol;
      var ok = 0, faux = 0;
      final aires = <double>[];
      for (final im in avec) {
        final q = _parHoughReduite(im, 'magic');
        if (q == null) continue;
        ok++;
        aires.add(_part(q, im.width, im.height));
      }
      for (final im in sans) {
        if (_parHoughReduite(im, 'magic') != null) faux++;
      }
      aires.sort();
      final med = aires.isEmpty ? 0.0 : aires[aires.length ~/ 2];
      print(
        '     ${sup.toStringAsFixed(2)}       ${tol.toStringAsFixed(2)}'
        '  ${ok.toString().padLeft(8)}'
        '  ${(med * 100).toStringAsFixed(0).padLeft(6)} %'
        '  ${faux.toString().padLeft(9)}',
      );
    }
  }
}

/// Dessine le quadrilatère trouvé sur la photo réduite.
///
/// **Un chiffre ne dit pas ce qui a été détouré.** Un rapport de 0,71 peut
/// désigner la carte comme le cadre intérieur de son illustration, et deux
/// mesures de suite ont déjà été prises pour des succès alors que la forme
/// retenue était l'image entière. On regarde.
void _dessine(img.Image small, CardQuad? quad, String vers) {
  final vue = small.clone();
  if (quad != null) {
    final coins = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft];
    for (var i = 0; i < 4; i++) {
      final a = coins[i], b = coins[(i + 1) % 4];
      img.drawLine(
        vue,
        x1: a.x.round(),
        y1: a.y.round(),
        x2: b.x.round(),
        y2: b.y.round(),
        color: img.ColorRgb8(255, 0, 0),
        thickness: 2,
      );
    }
  }
  File(vers).writeAsBytesSync(img.encodePng(vue));
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage : dart run tool/hough_bench.dart <dossier>');
    exitCode = 64;
    return;
  }
  final sansCarte = args.contains('--sans-carte');
  final iL = args.indexOf('--lignes');
  if (iL >= 0) gMaxLines = int.parse(args[iL + 1]);
  final iS = args.indexOf('--support');
  if (iS >= 0) gMinSupport = double.parse(args[iS + 1]);
  final iA = args.indexOf('--aire');
  if (iA >= 0) gMinArea = double.parse(args[iA + 1]);
  final iT = args.indexOf('--tol');
  if (iT >= 0) gTol = double.parse(args[iT + 1]);
  final iSc = args.indexOf('--sc');
  if (iSc >= 0) gSc = double.parse(args[iSc + 1]);
  final dir = Directory(args.first);
  final fichiers =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  if (args.contains('--balayage')) {
    _balayage(fichiers);
    return;
  }

  print(
    sansCarte
        ? 'coins recadrés (fond seul) — toute carte annoncée est un faux'
        : '${fichiers.length} photos avec une carte',
  );
  print('');
  print('  clarté    hough     aire     fichier');

  var clarte = 0, hough = 0;
  final aires = <double>[];
  for (final f in fichiers) {
    var photo = img.decodeImage(f.readAsBytesSync());
    if (photo == null) continue;
    if (sansCarte) {
      photo = img.copyCrop(
        photo,
        x: 0,
        y: 0,
        width: (photo.width * 0.33).round(),
        height: (photo.height * 0.33).round(),
      );
    }

    if (args.contains('--luma')) photo = _enLuminance(photo);

    final parClarte = findCard(photo, game: 'magic');
    final parLignes = _parHough(photo, 'magic');
    if (parClarte != null) clarte++;
    if (parLignes != null) hough++;

    final iDump = args.indexOf('--dump');
    if (iDump >= 0 && iDump + 1 < args.length) {
      final small = _reduite(photo);
      _dessine(
        small,
        parLignes,
        '${args[iDump + 1]}/${f.uri.pathSegments.last.replaceAll('.jpg', '.png')}',
      );
    }

    final petite = _reduite(photo);
    if (parLignes != null) {
      aires.add(_part(parLignes, petite.width, petite.height));
    }
    print(
      '  ${(parClarte == null ? '—' : parClarte.aspect.toStringAsFixed(3)).padRight(8)}'
      '  ${(parLignes == null ? '—' : parLignes.aspect.toStringAsFixed(3)).padRight(8)}'
      '  ${parLignes == null ? '    ' : '${(_part(parLignes, petite.width, petite.height) * 100).toStringAsFixed(0).padLeft(3)} %'}'
      '     ${f.uri.pathSegments.last}',
    );
  }
  print('');
  final quoi = sansCarte ? 'inventées' : 'trouvées';
  aires.sort();
  final mediane = aires.isEmpty ? 0.0 : aires[aires.length ~/ 2];
  print('$quoi — clarté : $clarte/${fichiers.length}'
      '   ·   hough : $hough/${fichiers.length}'
      '   ·   aire médiane ${(mediane * 100).toStringAsFixed(0)} %');
}
