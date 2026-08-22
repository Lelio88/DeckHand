/// Ce que la détection voit d'une photo, en images (#8).
///
/// **Un compteur ne dit pas où ça casse.** Quand le quadrilatère retenu est le
/// pavé de texte au lieu de la carte, trois causes sont possibles et n'appellent
/// pas le même travail : le contour n'est pas dans les pixels de bord retenus,
/// il y est mais ne ressort pas comme droite dominante, ou il en ressort mais
/// se fait écarter à l'assemblage. Ces trois images-là répondent.
///
/// Usage :
/// ```
/// dart run tool/hough_probe.dart <photo.jpg> <dossier de sortie>
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:image/image.dart' as img;

import 'package:deckhand/src/features/scan/domain/card_edges.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage : dart run tool/hough_probe.dart <photo> <dossier>');
    exitCode = 64;
    return;
  }
  final photo = img.decodeImage(File(args.first).readAsBytesSync())!;
  final out = args[1];
  final small = img.copyResize(
    photo,
    width: analysisWidth,
    interpolation: img.Interpolation.average,
  );
  final champ = dominantLines(small, maxLines: 24);

  // 1. Les pixels retenus comme bords.
  final masque = img.Image(width: champ.width, height: champ.height);
  for (var y = 0; y < champ.height; y++) {
    for (var x = 0; x < champ.width; x++) {
      final on = champ.edges[y * champ.width + x] != 0;
      masque.setPixelRgb(x, y, on ? 255 : 0, on ? 255 : 0, on ? 255 : 0);
    }
  }
  File('$out/1-bords.png').writeAsBytesSync(img.encodePng(masque));

  // 2. Les droites dominantes, tracées sur la photo.
  final vue = small.clone();
  for (final l in champ.lines) {
    final c = math.cos(l.theta), s = math.sin(l.theta);
    // Deux points très éloignés le long de la droite.
    final x0 = c * l.rho, y0 = s * l.rho;
    img.drawLine(
      vue,
      x1: (x0 + 2000 * -s).round(),
      y1: (y0 + 2000 * c).round(),
      x2: (x0 - 2000 * -s).round(),
      y2: (y0 - 2000 * c).round(),
      color: img.ColorRgb8(0, 255, 0),
      thickness: 1,
    );
  }
  File('$out/2-droites.png').writeAsBytesSync(img.encodePng(vue));

  print('${champ.lines.length} droites dominantes');
  for (final l in champ.lines.take(12)) {
    print('  theta ${(l.theta * 180 / math.pi).toStringAsFixed(0).padLeft(3)}°'
        '  rho ${l.rho.toStringAsFixed(0).padLeft(5)}'
        '  votes ${l.votes}');
  }
}
