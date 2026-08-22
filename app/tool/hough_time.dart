/// Ce que coûte la détection par droites, en millisecondes (#8).
///
/// **Le chiffre qui décide de l'usage.** Une photo peut se payer une seconde ;
/// le flux caméra travaille sous ~12 ms par image, mesuré sur l'appareil. Si la
/// chaîne dépasse ce budget, elle reste réservée à la photo — et le flux garde
/// un autre réglage, plus grossier mais tenable.
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:image/image.dart' as img;

import 'package:deckhand/src/features/scan/domain/card_edges.dart';

void main(List<String> args) {
  final dir = Directory(args.first);
  final fichiers = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.jpg'))
      .take(6)
      .toList();

  for (final largeur in [200, 320, 400]) {
    final petites = [
      for (final f in fichiers)
        img.copyResize(
          img.decodeImage(f.readAsBytesSync())!,
          width: largeur,
          interpolation: img.Interpolation.average,
        ),
    ];
    // Une passe à blanc : le JIT ne doit pas être compté.
    for (final im in petites) {
      final c = dominantLines(im, maxLines: 32);
      bestQuad(c.lines, c.edges, c.width, c.height, 'magic');
    }

    final chrono = Stopwatch()..start();
    var tours = 0;
    while (chrono.elapsedMilliseconds < 2000) {
      for (final im in petites) {
        final c = dominantLines(im, maxLines: 32);
        bestQuad(c.lines, c.edges, c.width, c.height, 'magic');
        tours++;
      }
    }
    chrono.stop();
    final parImage = chrono.elapsedMicroseconds / tours / 1000;
    print('largeur ${largeur.toString().padLeft(3)} px'
        ' — ${parImage.toStringAsFixed(1)} ms par image'
        ' ($tours passes)');
  }

  // **Le chemin du flux** : plan de luminance, un seul canal, 240 px.
  {
    final plans = <({Uint8List luma, int w, int h})>[];
    for (final f in fichiers) {
      final im = img.decodeImage(f.readAsBytesSync())!;
      final petite = img.copyResize(im, width: 640);
      final luma = Uint8List(petite.width * petite.height);
      for (var y = 0; y < petite.height; y++) {
        for (var x = 0; x < petite.width; x++) {
          final p = petite.getPixel(x, y);
          luma[y * petite.width + x] =
              (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
        }
      }
      plans.add((luma: luma, w: petite.width, h: petite.height));
    }
    for (final largeur in [200, 240, 320]) {
      for (final p in plans) {
        findCardByEdgesInLuma(
          p.luma,
          width: p.w,
          height: p.h,
          rowStride: p.w,
          analysisWidth: largeur,
        );
      }
      final c = Stopwatch()..start();
      var n = 0;
      while (c.elapsedMilliseconds < 2000) {
        for (final p in plans) {
          findCardByEdgesInLuma(
            p.luma,
            width: p.w,
            height: p.h,
            rowStride: p.w,
            analysisWidth: largeur,
          );
          n++;
        }
      }
      c.stop();
      print('luma ${largeur.toString().padLeft(3)} px'
          ' — ${(c.elapsedMicroseconds / n / 1000).toStringAsFixed(1)} ms par image');
    }
  }

  // Repère : la chaîne de production sur la même largeur.
  final petites = [
    for (final f in fichiers)
      img.copyResize(
        img.decodeImage(f.readAsBytesSync())!,
        width: analysisWidth,
        interpolation: img.Interpolation.average,
      ),
  ];
  for (final im in petites) {
    findCard(im, game: 'magic');
  }
  final chrono = Stopwatch()..start();
  var tours = 0;
  while (chrono.elapsedMilliseconds < 2000) {
    for (final im in petites) {
      findCard(im, game: 'magic');
      tours++;
    }
  }
  chrono.stop();
  print('production (clarté, $analysisWidth px)'
      ' — ${(chrono.elapsedMicroseconds / tours / 1000).toStringAsFixed(1)} ms par image');
}
