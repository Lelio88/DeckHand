/// Le quadrilatère bouge-t-il alors que la carte ne bouge pas ? (#8)
///
/// **Ce que le terrain a montré, et qu'il faut chiffrer.** Sur une carte
/// immobile devant l'objectif, le cadre relevé variait de ±10 % d'une image à
/// l'autre — 895×633, puis 811×596, puis 841×555 — quand l'empreinte décroche
/// au-delà de 3 % d'écart de cadrage. La fenêtre d'illustration est donc
/// prélevée de travers, et une empreinte de travers tombe par hasard près
/// d'une entrée quelconque du catalogue.
///
/// **Deux causes se corrigent différemment**, et le journal ne les distingue
/// pas :
///
/// - du **bruit** — le quadrilatère oscille autour de la bonne position. Un
///   lissage sur quelques images le supprime, l'écart-type tombant en racine du
///   nombre d'images moyennées.
/// - des **sauts** — la détection hésite entre deux formes distinctes, la carte
///   et l'un de ses cadres intérieurs. Moyenner donnerait alors un quadrilatère
///   à mi-chemin des deux, c'est-à-dire faux à coup sûr.
///
/// Ce banc rejoue la même photo avec le bruit d'un capteur et mesure la
/// dispersion des coins. Une distribution serrée autour d'une valeur signe le
/// bruit ; deux amas signent les sauts.
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:image/image.dart' as img;

/// Amplitude du bruit ajouté, en niveaux de gris.
///
/// Un capteur de téléphone en lumière d'intérieur produit de l'ordre de deux à
/// quatre niveaux d'écart-type ; on prend le haut de la fourchette.
const int bruit = 4;

void main(List<String> args) {
  final dir = Directory(
    args.isNotEmpty && !args.first.startsWith('--')
        ? args.first
        : '../../.deckhand-bench/photos/carte-seule',
  );
  final fichiers = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.jpg'))
      .take(6)
      .toList();

  print('${fichiers.length} photos, 12 tirages chacune, bruit ±$bruit');
  print('');
  print('  largeur                 hauteur              photo');

  final iB = args.indexOf('--bonus');
  if (iB >= 0) continuityBonus = double.parse(args[iB + 1]);
  final alea = math.Random(20260823);
  for (final file in fichiers) {
    final photo = img.decodeImage(file.readAsBytesSync());
    if (photo == null) continue;

    CardQuad? ancre;
    final quads = <CardQuad>[];
    final largeurs = <double>[];
    final hauteurs = <double>[];
    for (var essai = 0; essai < 12; essai++) {
      final bruite = photo.clone();
      for (var y = 0; y < bruite.height; y += 1) {
        for (var x = 0; x < bruite.width; x += 1) {
          final p = bruite.getPixel(x, y);
          final d = alea.nextInt(2 * bruit + 1) - bruit;
          bruite.setPixelRgb(
            x,
            y,
            (p.r + d).clamp(0, 255),
            (p.g + d).clamp(0, 255),
            (p.b + d).clamp(0, 255),
          );
        }
      }
      // **Avec ancre**, comme le flux : le cadre précédent bonifie les
      // candidats compatibles. Sans elle, chaque image repart de zéro et rien
      // n'empêche le choix de basculer.
      final q = findCardByEdges(
        bruite,
        anchor: args.contains('--sans-ancre') ? null : ancre,
      );
      if (q == null) continue;
      ancre = q;
      quads.add(q);
      double d(({double x, double y}) a, ({double x, double y}) b) =>
          math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
      largeurs.add(d(q.topLeft, q.topRight));
      hauteurs.add(d(q.topRight, q.bottomRight));
    }

    // **Regarder les formes plutôt que leur écart-type.** Un pourcentage ne dit
    // pas ce qui hésite ; deux rectangles superposés, si.
    final iD = args.indexOf('--dump');
    if (iD >= 0) {
      final vue = img.copyResize(photo, width: 500);
      final f = 500 / photo.width;
      for (final q in quads) {
        final coins = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft];
        for (var i = 0; i < 4; i++) {
          final a = coins[i], b = coins[(i + 1) % 4];
          img.drawLine(
            vue,
            x1: (a.x * f).round(),
            y1: (a.y * f).round(),
            x2: (b.x * f).round(),
            y2: (b.y * f).round(),
            color: img.ColorRgb8(255, 0, 0),
            thickness: 1,
          );
        }
      }
      final nom = file.uri.pathSegments.last.replaceAll('.jpg', '');
      File('${args[iD + 1]}/$nom.png').writeAsBytesSync(img.encodePng(vue));
    }

    String decrire(List<double> v) {
      if (v.isEmpty) return 'aucune';
      final moy = v.reduce((a, b) => a + b) / v.length;
      final ecart = math.sqrt(
        v.map((x) => (x - moy) * (x - moy)).reduce((a, b) => a + b) / v.length,
      );
      final min = v.reduce(math.min), max = v.reduce(math.max);
      return '${moy.toStringAsFixed(0).padLeft(4)}'
          ' ±${(100 * ecart / moy).toStringAsFixed(1).padLeft(4)} %'
          ' [${min.toStringAsFixed(0)}–${max.toStringAsFixed(0)}]';
    }

    print(
      '  ${decrire(largeurs).padRight(22)}  ${decrire(hauteurs).padRight(20)}'
      '  ${file.uri.pathSegments.last.replaceAll('IMG_20260822_', '')}',
    );
  }
  print('');
  print('au-delà de 3 % d\'écart, l\'empreinte décroche.');
}
