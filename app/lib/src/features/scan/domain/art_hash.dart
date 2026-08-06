/// Empreinte perceptuelle d'illustration — jumeau Dart de `api/app/vision/dhash.py`.
///
/// **Les deux implémentations doivent produire exactement les mêmes bits.**
/// L'index est calculé côté serveur en Python ; si le calcul embarqué diverge,
/// même d'un bit, la reconnaissance se dégrade sans prévenir. Des vecteurs de
/// référence générés depuis Python verrouillent cette parité — voir
/// `test/src/features/scan/art_hash_test.dart`.
///
/// **Pourquoi le redimensionnement est fait à la main.** Une première version
/// s'appuyait sur `copyResize` du paquet `image` côté Dart et sur Lanczos côté
/// Pillow : les empreintes divergeaient sur 3 images de test sur 5. Deux
/// bibliothèques n'implémentent pas le même rééchantillonnage. La réduction est
/// donc effectuée ici par un filtre de moyenne à **bornes et divisions
/// entières**, reproductible à l'identique dans les deux langages.
///
/// **Pourquoi des octets et non un `int`.** Sur Flutter web, `int` est un double
/// IEEE-754 : au-delà de 2^53 les valeurs perdent des bits **silencieusement**.
/// Une empreinte de 64 bits stockée dans un `int` serait corrompue sur le web et
/// correcte sur mobile — le pire des bugs, invisible et dépendant de la
/// plateforme. L'empreinte est portée par huit octets, identiques partout.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Côté de la grille d'empreinte. 8 donne 8×8 = 64 bits.
const int hashSize = 8;
const int hashBytes = hashSize * hashSize ~/ 8;

/// Coefficients de luminance ITU-R BT.601, en millièmes pour rester entiers.
/// Doivent rester alignés sur `_GREY_*` dans dhash.py.
const int _greyR = 299;
const int _greyG = 587;
const int _greyB = 114;
const int _greyDiv = 1000;

/// Nombre de bits à 1 dans un octet, précalculé.
final Uint8List _popcount = Uint8List.fromList([
  for (var i = 0; i < 256; i++)
    i.toRadixString(2).split('').where((c) => c == '1').length,
]);

/// Empreinte de 64 bits d'une illustration.
class ArtHash {
  const ArtHash(this.bytes);

  final Uint8List bytes;

  /// Représentation hexadécimale, 16 caractères. Format d'échange avec le
  /// serveur et avec les vecteurs de test.
  String toHex() => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  factory ArtHash.fromHex(String hex) {
    final clean = hex.replaceAll(' ', '');
    if (clean.length != hashBytes * 2) {
      throw ArgumentError(
        'empreinte attendue sur ${hashBytes * 2} caractères : $hex',
      );
    }
    return ArtHash(
      Uint8List.fromList([
        for (var i = 0; i < clean.length; i += 2)
          int.parse(clean.substring(i, i + 2), radix: 16),
      ]),
    );
  }

  /// Nombre de bits qui diffèrent entre deux empreintes.
  int distanceTo(ArtHash other) {
    var total = 0;
    for (var i = 0; i < bytes.length; i++) {
      total += _popcount[bytes[i] ^ other.bytes[i]];
    }
    return total;
  }

  @override
  bool operator ==(Object other) =>
      other is ArtHash && toHex() == other.toHex();

  @override
  int get hashCode => toHex().hashCode;

  @override
  String toString() => 'ArtHash(${toHex()})';
}

/// Bornes de la cellule [index] sur [count], dans une dimension de [length].
///
/// Bornes entières, donc identiques à `_cell_bounds` en Python. Le `max`
/// garantit une cellule non vide même quand l'image source est plus petite que
/// la grille.
({int start, int end}) _cellBounds(int index, int count, int length) {
  final start = index * length ~/ count;
  var end = (index + 1) * length ~/ count;
  if (end < start + 1) end = start + 1;
  if (end > length) end = length;
  return (start: start, end: end);
}

/// Calcule l'empreinte d'une illustration.
///
/// L'image est réduite à `(size + 1) × size` par moyenne de blocs, puis chaque
/// pixel est comparé à son voisin de droite. Comparer des voisins plutôt que des
/// valeurs absolues rend l'empreinte insensible à un éclairage global — ce qui
/// compte quand la référence est un scan officiel et la requête une photo.
ArtHash computeArtHash(img.Image image, {int size = hashSize}) {
  final srcW = image.width;
  final srcH = image.height;
  final outW = size + 1;
  final outH = size;

  // Niveaux de gris en arithmétique entière explicite, comme en Python.
  final grey = Int32List(srcW * srcH);
  for (var y = 0; y < srcH; y++) {
    for (var x = 0; x < srcW; x++) {
      final p = image.getPixel(x, y);
      grey[y * srcW + x] =
          (p.r.toInt() * _greyR +
              p.g.toInt() * _greyG +
              p.b.toInt() * _greyB) ~/
          _greyDiv;
    }
  }

  // Réduction par moyenne de blocs, en divisions entières.
  final cells = Int32List(outW * outH);
  for (var dy = 0; dy < outH; dy++) {
    final yb = _cellBounds(dy, outH, srcH);
    for (var dx = 0; dx < outW; dx++) {
      final xb = _cellBounds(dx, outW, srcW);
      var sum = 0;
      var count = 0;
      for (var y = yb.start; y < yb.end; y++) {
        final row = y * srcW;
        for (var x = xb.start; x < xb.end; x++) {
          sum += grey[row + x];
          count++;
        }
      }
      cells[dy * outW + dx] = sum ~/ count;
    }
  }

  final bytes = Uint8List(size * size ~/ 8);
  var bitIndex = 0;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (cells[y * outW + x] > cells[y * outW + x + 1]) {
        bytes[bitIndex ~/ 8] |= 1 << (7 - (bitIndex % 8));
      }
      bitIndex++;
    }
  }

  return ArtHash(bytes);
}
