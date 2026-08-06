/// Verrouille la parité entre l'empreinte Dart et son jumeau Python.
///
/// Les images sont produites par des formules pures, reproductibles à
/// l'identique dans les deux langages sans transporter de fichier. Les
/// empreintes attendues proviennent de `api/app/vision/dhash.py`, qui fait foi :
/// c'est elle qui a calculé l'index en base.
///
/// Si un de ces tests casse, ce n'est pas le test qu'il faut ajuster — c'est que
/// la reconnaissance embarquée vient de diverger de l'index, et qu'elle
/// échouerait en silence.
library;

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Empreintes calculées par l'implémentation Python de référence.
const referenceVectors = <String, String>{
  'gradient': '2688329832E973C9',
  'damier': 'A55AA55AA55AA55A',
  'bandes': '0000000000000000',
  'radial': 'F0F0F0F0F0F0F0F0',
  'bruit_pseudo': '1821499204182941',
};

img.Image build(int width, int height, List<int> Function(int, int) formula) {
  final image = img.Image(width: width, height: height);
  for (var x = 0; x < width; x++) {
    for (var y = 0; y < height; y++) {
      final c = formula(x, y);
      image.setPixelRgb(x, y, c[0], c[1], c[2]);
    }
  }
  return image;
}

img.Image gradient() => build(
  200,
  200,
  (x, y) => [(x * 2 + y) % 256, (x * 3 + y * 5) % 256, (x + y * 7) % 256],
);

img.Image damier() => build(160, 160, (x, y) {
  final on = ((x ~/ 20) + (y ~/ 20)) % 2 == 0;
  return on ? [240, 240, 240] : [16, 16, 16];
});

img.Image bandes() =>
    build(240, 120, (x, y) => [(y * 4) % 256, 80, 255 - (y * 4) % 256]);

img.Image radial() => build(180, 180, (x, y) {
  final v = (((x - 90) * (x - 90) + (y - 90) * (y - 90)) ~/ 64) % 256;
  return [v, v, v];
});

img.Image bruitPseudo() => build(128, 128, (x, y) {
  final v = (x * 7919 + y * 104729) % 251;
  return [v, v, v];
});

void main() {
  group('parité avec l\'implémentation Python', () {
    final images = <String, img.Image Function()>{
      'gradient': gradient,
      'damier': damier,
      'bandes': bandes,
      'radial': radial,
      'bruit_pseudo': bruitPseudo,
    };

    for (final entry in images.entries) {
      test('${entry.key} produit la même empreinte qu\'en Python', () {
        final computed = computeArtHash(entry.value()).toHex();
        expect(
          computed,
          referenceVectors[entry.key],
          reason:
              'divergence Dart/Python sur « ${entry.key} » — '
              'la reconnaissance embarquée ne correspondrait plus à l\'index',
        );
      });
    }
  });

  group('ArtHash', () {
    test('fait 64 bits', () {
      expect(computeArtHash(gradient()).bytes.length, hashBytes);
      expect(hashBytes * 8, 64);
    });

    test('la conversion hexadécimale est réversible', () {
      final original = computeArtHash(gradient());
      expect(ArtHash.fromHex(original.toHex()), original);
    });

    test('refuse une chaîne hexadécimale de mauvaise longueur', () {
      expect(() => ArtHash.fromHex('ABCD'), throwsArgumentError);
    });

    test('la distance d\'une empreinte à elle-même est nulle', () {
      final h = computeArtHash(gradient());
      expect(h.distanceTo(h), 0);
    });

    test('la distance compte les bits différents', () {
      expect(
        ArtHash.fromHex(
          '0000000000000000',
        ).distanceTo(ArtHash.fromHex('0000000000000007')),
        3,
      );
      expect(
        ArtHash.fromHex(
          '0000000000000000',
        ).distanceTo(ArtHash.fromHex('FFFFFFFFFFFFFFFF')),
        64,
      );
    });

    test('deux illustrations distinctes sont éloignées', () {
      final a = computeArtHash(gradient());
      final b = computeArtHash(damier());
      expect(a.distanceTo(b), greaterThanOrEqualTo(16));
    });

    test('un redimensionnement déplace peu l\'empreinte', () {
      final original = gradient();
      final resized = img.copyResize(original, width: 90, height: 90);
      expect(
        computeArtHash(original).distanceTo(computeArtHash(resized)),
        lessThanOrEqualTo(6),
      );
    });
  });
}
