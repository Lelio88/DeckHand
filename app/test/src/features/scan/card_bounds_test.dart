/// Tests de la détection des bords d'une carte.
///
/// **Ce qu'ils protègent.** Le pipeline découpait l'illustration à une position
/// fixe dans un rectangle centré, en supposant que la carte remplisse la photo.
/// Mesuré par `api/app/measure/framing_bench.py`, cet espoir ne tolère que 2 à
/// 3 % d'écart : à 8 % de marge et 2° de travers, aucune carte sur quarante
/// n'était reconnue. Avec les coins détectés, 37 sur 40 le sont.
///
/// Les valeurs attendues viennent du jumeau Python `app/vision/card_bounds.py`,
/// joué sur la même image de synthèse. Deux implémentations qui divergeraient
/// produiraient des empreintes incomparables et feraient échouer le scan **en
/// silence** — le pire mode de défaillance, puisqu'il fait accuser l'algorithme.
library;

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Une carte sombre posée sur une table claire, illustration en haut.
///
/// Reproduit exactement la figure servie au jumeau Python : table unie
/// (170, 152, 126), carte 126 × 176 en (70, 90), illustration 100 × 74 en
/// (10, 21) dans la carte.
img.Image _photo({int dx = 0, int dy = 0}) {
  final photo = img.Image(width: 300, height: 400);
  img.fill(photo, color: img.ColorRgb8(170, 152, 126));

  for (var y = 0; y < 176; y++) {
    for (var x = 0; x < 126; x++) {
      photo.setPixelRgb(70 + dx + x, 90 + dy + y, 18, 16, 20);
    }
  }
  for (var y = 0; y < 74; y++) {
    for (var x = 0; x < 100; x++) {
      photo.setPixelRgb(80 + dx + x, 111 + dy + y, 200, 60, 40);
    }
  }
  return photo;
}

void main() {
  group('trouver la carte', () {
    test('les quatre coins épousent la carte', () {
      final quad = findCard(_photo());

      expect(quad, isNotNull);
      expect(quad!.topLeft.x, 70);
      expect(quad.topLeft.y, 90);
      expect(quad.bottomRight.x, 195);
      expect(quad.bottomRight.y, 265);
    });

    test('le rapport reconnu est celui d\'une carte', () {
      // Même valeur que le jumeau Python, à l'arrondi d'affichage près.
      expect(findCard(_photo())!.aspect, closeTo(0.7143, 0.001));
    });

    test('déplacer la carte déplace les coins d\'autant', () {
      // C'est tout l'intérêt : le cadrage n'a plus à être centré.
      final quad = findCard(_photo(dx: 40, dy: -30));

      expect(quad!.topLeft.x, 110);
      expect(quad.topLeft.y, 60);
    });

    test('une photo sans carte ne rend rien', () {
      // Renoncer est un résultat : l'appelant retombe alors sur le cadrage
      // centré, jamais sur pire.
      final table = img.Image(width: 300, height: 400);
      img.fill(table, color: img.ColorRgb8(170, 152, 126));

      expect(findCard(table), isNull);
    });

    test('une image minuscule ne fait pas échouer la détection', () {
      expect(findCard(img.Image(width: 4, height: 4)), isNull);
    });
  });

  group('lire l\'illustration dans le quadrilatère', () {
    test('la zone lue est bien celle de l\'illustration', () {
      final photo = _photo();
      final art = sampleArt(
        photo,
        findCard(photo)!,
        (left: 0.080, top: 0.120, right: 0.920, bottom: 0.550),
        width: 16,
        height: 12,
      );

      var r = 0.0, g = 0.0, b = 0.0;
      for (var y = 0; y < art.height; y++) {
        for (var x = 0; x < art.width; x++) {
          final pixel = art.getPixel(x, y);
          r += pixel.r;
          g += pixel.g;
          b += pixel.b;
        }
      }
      final count = art.width * art.height;

      // Moyennes rendues par le jumeau Python : 188.62, 57.25, 38.75. La zone
      // du gabarit déborde légèrement sur la bordure sombre, d'où un rouge un
      // peu en deçà des 200 de l'illustration.
      expect(r / count, closeTo(188.62, 1.5));
      expect(g / count, closeTo(57.25, 1.5));
      expect(b / count, closeTo(38.75, 1.5));
    });

    test('la lecture reste dans les bornes de la photo', () {
      // Un quadrilatère débordant ne doit pas faire sortir l'échantillonnage
      // de l'image : une photo tronquée ne doit pas planter le scan.
      final photo = _photo();
      final art = sampleArt(
        photo,
        const CardQuad(
          topLeft: (x: -50, y: -50),
          topRight: (x: 400, y: -50),
          bottomRight: (x: 400, y: 500),
          bottomLeft: (x: -50, y: 500),
        ),
        (left: 0.0, top: 0.0, right: 1.0, bottom: 1.0),
        width: 8,
        height: 8,
      );

      expect(art.width, 8);
      expect(art.height, 8);
    });
  });
}
