/// Tests de la lecture d'une image de caméra.
///
/// **Ce qu'ils protègent est l'égalité des empreintes.** L'index embarqué est
/// calculé par le jumeau Python sur des illustrations RGB ; si le chemin
/// caméra produisait une empreinte seulement *proche*, la reconnaissance se
/// dégraderait sans que rien ne le signale — la panne que tout ce dépôt
/// cherche à rendre impossible.
///
/// Le second point est le **pas de ligne**. Un capteur choisit un `rowStride`
/// supérieur à la largeur ; l'ignorer ne lève aucune erreur, cela cisaille
/// l'image. Un test qui n'utiliserait qu'un pas égal à la largeur laisserait
/// passer exactement cette faute.
library;

import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/camera_frame.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Un plan de luminance avec du remplissage en fin de ligne, comme un capteur.
Uint8List planeWithPadding(
  int width,
  int height,
  int rowStride,
  int Function(int x, int y) value,
) {
  final bytes = Uint8List(rowStride * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      bytes[y * rowStride + x] = value(x, y);
    }
    // Le remplissage porte une valeur bien visible : s'il entrait dans l'image,
    // l'empreinte changerait.
    for (var x = width; x < rowStride; x++) {
      bytes[y * rowStride + x] = 255;
    }
  }
  return bytes;
}

void main() {
  group('lumaImage', () {
    test('rend exactement la luminance, sans arrondi ajouté', () {
      // `computeArtHash` calcule (r·299 + g·587 + b·114) ÷ 1000. Avec les trois
      // canaux à la même valeur, cela doit rendre cette valeur.
      final plane = planeWithPadding(4, 4, 4, (x, y) => x * 17 + y * 5);
      final image = lumaImage(plane, width: 4, height: 4, rowStride: 4);

      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final pixel = image.getPixel(x, y);
          final grey =
              (pixel.r.toInt() * 299 +
                  pixel.g.toInt() * 587 +
                  pixel.b.toInt() * 114) ~/
              1000;
          expect(grey, x * 17 + y * 5);
        }
      }
    });

    test('le remplissage de fin de ligne n\'entre pas dans l\'image', () {
      // Un `rowStride` ignoré cisaille l'image sans lever d'erreur.
      final plane = planeWithPadding(8, 8, 32, (x, y) => (x * 8 + y * 3) % 200);
      final read = lumaImage(plane, width: 8, height: 8, rowStride: 32);

      final expected = img.Image(width: 8, height: 8, numChannels: 3);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final v = (x * 8 + y * 3) % 200;
          expected.setPixelRgb(x, y, v, v, v);
        }
      }
      expect(computeArtHash(read), computeArtHash(expected));
    });

    test('une fenêtre ne lit que ses octets', () {
      final plane = planeWithPadding(16, 16, 16, (x, y) => x * 4 + y);
      final cropped = lumaImage(
        plane,
        width: 16,
        height: 16,
        rowStride: 16,
        crop: (left: 4, top: 2, width: 6, height: 5),
      );

      expect(cropped.width, 6);
      expect(cropped.height, 5);
      expect(cropped.getPixel(0, 0).r, (4 * 4 + 2));
      expect(cropped.getPixel(5, 4).r, (9 * 4 + 6));
    });

    test('une fenêtre qui déborde est ramenée, jamais vide', () {
      final plane = planeWithPadding(8, 8, 8, (x, y) => x + y);
      final cropped = lumaImage(
        plane,
        width: 8,
        height: 8,
        rowStride: 8,
        crop: (left: 6, top: 6, width: 40, height: 40),
      );
      expect(cropped.width, 2);
      expect(cropped.height, 2);
    });
  });

  group('la plage vidéo ne change pas l\'empreinte', () {
    test('une transformation affine croissante préserve les comparaisons', () {
      // Le `Y` d'un capteur court souvent de 16 à 235 là où une luminance RGB
      // pleine plage court de 0 à 255. Le passage est affine et croissant :
      // l'empreinte, faite de comparaisons entre voisins, doit y survivre.
      var seed = 7;
      int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;

      var identiques = 0;
      const essais = 40;
      for (var essai = 0; essai < essais; essai++) {
        final full = planeWithPadding(64, 64, 64, (_, _) => next() % 256);
        final video = Uint8List.fromList([
          for (final v in full) 16 + (v * 219) ~/ 255,
        ]);

        final a = computeArtHash(
          lumaImage(full, width: 64, height: 64, rowStride: 64),
        );
        final b = computeArtHash(
          lumaImage(video, width: 64, height: 64, rowStride: 64),
        );
        if (a == b) identiques++;
      }

      // On n'affirme pas l'égalité parfaite : les divisions entières peuvent
      // faire basculer un bit là où deux cases sont à égalité. On affirme que
      // le chemin reste utilisable — l'écart doit rester très inférieur au
      // seuil de confiance de l'index (12 bits).
      expect(
        identiques,
        greaterThanOrEqualTo((essais * 0.9).round()),
        reason: 'la mise à l\'échelle vidéo ne doit pas déplacer l\'empreinte',
      );
    });
  });

  group('rgbImage', () {
    test('une image sans chrominance est grise, et vaut la luminance', () {
      final luma = planeWithPadding(8, 8, 8, (x, y) => 10 + x * 20 + y);
      final neutral = Uint8List(4 * 4)..fillRange(0, 16, 128);

      final rgb = rgbImage(
        luma,
        neutral,
        neutral,
        width: 8,
        height: 8,
        lumaRowStride: 8,
        chromaRowStride: 4,
        chromaPixelStride: 1,
      );
      final grey = lumaImage(luma, width: 8, height: 8, rowStride: 8);
      expect(computeArtHash(rgb), computeArtHash(grey));
    });
  });

  group('artHashFromLuma', () {
    test('rend bit à bit ce que rend le chemin par img.Image', () {
      // C'est l'assertion qui autorise le raccourci. Si elle tombe, c'est le
      // chemin direct qui a tort : la parité avec le jumeau Python appartient
      // à `computeArtHash`.
      var seed = 42;
      int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;

      for (final geometry in [
        (w: 64, h: 64, stride: 64),
        (w: 100, h: 37, stride: 128),
        (w: 320, h: 240, stride: 384),
        (w: 9, h: 5, stride: 16),
        (w: 3, h: 3, stride: 4),
      ]) {
        final plane = planeWithPadding(
          geometry.w,
          geometry.h,
          geometry.stride,
          (_, _) => next() % 256,
        );
        final viaImage = computeArtHash(
          lumaImage(
            plane,
            width: geometry.w,
            height: geometry.h,
            rowStride: geometry.stride,
          ),
        );
        final direct = artHashFromLuma(
          plane,
          width: geometry.w,
          height: geometry.h,
          rowStride: geometry.stride,
        );
        expect(
          direct,
          viaImage,
          reason: 'divergence sur ${geometry.w}×${geometry.h}',
        );
      }
    });

    test('la fenêtre donne le même résultat que découper puis hacher', () {
      var seed = 99;
      int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final plane = planeWithPadding(200, 150, 256, (_, _) => next() % 256);
      const window = (left: 17, top: 23, width: 111, height: 64);

      expect(
        artHashFromLuma(
          plane,
          width: 200,
          height: 150,
          rowStride: 256,
          crop: window,
        ),
        computeArtHash(
          lumaImage(
            plane,
            width: 200,
            height: 150,
            rowStride: 256,
            crop: window,
          ),
        ),
      );
    });
  });
}
