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

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
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
