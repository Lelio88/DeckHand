/// Une image de caméra devenue une image que l'empreinte sait lire.
///
/// **Le goulot annoncé est la conversion YUV→RGB, et il est évitable.** Le
/// paquet `camera` sert des `CameraImage` en YUV420 sur Android : trois plans,
/// dont le premier — `Y` — est déjà la luminance. Or `computeArtHash` commence
/// précisément par ramener chaque pixel à sa luminance BT.601. Convertir en RGB
/// pour reconvertir en gris ensuite, c'est payer deux fois un aller-retour dont
/// on connaît le point de départ.
///
/// [lumaImage] lit donc `Y` directement. Sur une image dont les trois canaux
/// valent `Y`, le calcul de `computeArtHash` rend exactement `Y` :
/// `(Y·299 + Y·587 + Y·114) ÷ 1000 = Y`. **L'empreinte n'est pas approchée,
/// elle est identique** — ce qui compte, l'index embarqué étant calculé par le
/// jumeau Python sur des illustrations RGB.
///
/// **Le détour par RGB, lui, perd de l'information.** Algébriquement il rend
/// `Y` : les coefficients de la conversion et ceux de la luminance s'annulent.
/// Mais il écrête — mesuré sur des triplets tirés au hasard, **77 % des pixels**
/// sortent de l'intervalle 0–255 avant d'y être ramenés, et l'écart moyen monte
/// alors à 14 valeurs. Sur l'appareil, les deux chemins divergent en
/// conséquence de 3 bits en médiane et jusqu'à 14. C'est l'erreur du détour, pas
/// celle du raccourci.
///
/// La nuance qui reste, et que seule une carte de papier tranchera : le `Y` d'un
/// capteur est souvent en plage vidéo (16–235) là où l'index est calculé sur du
/// RGB pleine plage. Le passage de l'une à l'autre est affine et croissant, donc
/// il préserve les comparaisons de voisins dont l'empreinte est faite — aux
/// arrondis près, qui peuvent faire basculer un bit là où deux cases sont à
/// égalité. Vérifié en test de synthèse ; à éprouver devant un booster réel.
///
/// **Le découpage précède la conversion, et c'est tout l'intérêt.** L'empreinte
/// ne porte que sur l'illustration — 84 % de la largeur, 43 % de la hauteur
/// d'une carte. Lire les seuls octets de cette fenêtre rend le coût
/// proportionnel à elle, et non à l'image entière. Une conversion RGB complète,
/// elle, paye la totalité du capteur avant de jeter les deux tiers.
///
/// [rgbImage] existe pour la comparaison, pas pour la production : c'est le
/// chemin qu'on cherche à ne pas prendre, et on ne peut affirmer qu'il coûte
/// cher qu'en le chronométrant aussi.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'art_hash.dart';

/// Fenêtre en pixels dans une image de caméra.
typedef PixelBox = ({int left, int top, int width, int height});

/// La fenêtre entière.
PixelBox wholeFrame(int width, int height) =>
    (left: 0, top: 0, width: width, height: height);

/// Ramène une fenêtre dans les bornes de l'image, et jamais vide.
PixelBox clampBox(PixelBox box, int width, int height) {
  final left = box.left.clamp(0, width - 1);
  final top = box.top.clamp(0, height - 1);
  return (
    left: left,
    top: top,
    width: box.width.clamp(1, width - left),
    height: box.height.clamp(1, height - top),
  );
}

/// Image grise construite depuis le seul plan de luminance.
///
/// [rowStride] est le pas d'une ligne en octets, que le capteur choisit et qui
/// dépasse souvent la largeur : l'ignorer produirait une image cisaillée, pas
/// une erreur. [pixelStride] vaut 1 sur tous les capteurs rencontrés, mais le
/// paquet `camera` le déclare, donc on le respecte.
img.Image lumaImage(
  Uint8List luma, {
  required int width,
  required int height,
  required int rowStride,
  int pixelStride = 1,
  PixelBox? crop,
}) {
  final box = clampBox(crop ?? wholeFrame(width, height), width, height);
  final out = img.Image(width: box.width, height: box.height, numChannels: 3);

  for (var y = 0; y < box.height; y++) {
    final row = (box.top + y) * rowStride;
    for (var x = 0; x < box.width; x++) {
      final offset = row + (box.left + x) * pixelStride;
      final value = offset < luma.length ? luma[offset] : 0;
      // Les trois canaux à la même valeur : `computeArtHash` en tire exactement
      // `value`, sans arrondi ajouté.
      out.setPixelRgb(x, y, value, value, value);
    }
  }
  return out;
}

/// Empreinte calculée depuis le plan de luminance, sans image intermédiaire.
///
/// **Mesuré sur l'appareil : l'empreinte devenait le poste dominant.** Une fois
/// la conversion RGB écartée et la recherche ramenée à une milliseconde, il
/// restait 12,2 ms pour hacher une fenêtre de 333 000 pixels — les trois quarts
/// du budget d'une image. Le coût ne venait pas de l'arithmétique, qui tient en
/// quelques additions par pixel, mais du trajet : construire un `img.Image` de
/// la fenêtre, y écrire trois canaux par pixel, puis les relire un par un
/// à travers `getPixel`.
///
/// Cette fonction lit les octets là où ils sont. **Elle ne change pas le
/// calcul** : mêmes bornes de cellule entières, mêmes moyennes en division
/// entière, même comparaison de voisins que [computeArtHash] — dont elle reste
/// le miroir, et à qui la parité avec le jumeau Python appartient. Un test
/// vérifie l'égalité **bit à bit** des deux chemins sur des images tirées au
/// hasard ; s'il tombe, c'est celle-ci qui a tort.
///
/// Les trois canaux valant `Y`, `computeArtHash` en tire exactement `Y` :
/// `(Y·299 + Y·587 + Y·114) ÷ 1000 = Y`. C'est ce qui autorise à sauter
/// l'étape, et non une approximation jugée acceptable.
ArtHash artHashFromLuma(
  Uint8List luma, {
  required int width,
  required int height,
  required int rowStride,
  int pixelStride = 1,
  PixelBox? crop,
  int size = hashSize,
}) {
  final box = clampBox(crop ?? wholeFrame(width, height), width, height);
  final outW = size + 1;
  final outH = size;
  final cells = Int32List(outW * outH);

  for (var dy = 0; dy < outH; dy++) {
    final yb = _cellBounds(dy, outH, box.height);
    for (var dx = 0; dx < outW; dx++) {
      final xb = _cellBounds(dx, outW, box.width);
      var sum = 0;
      var count = 0;
      for (var y = yb.start; y < yb.end; y++) {
        final row = (box.top + y) * rowStride + box.left * pixelStride;
        for (var x = xb.start; x < xb.end; x++) {
          final offset = row + x * pixelStride;
          sum += offset < luma.length ? luma[offset] : 0;
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

/// Bornes de la cellule [index] sur [count] — copie conforme de celles de
/// `art_hash.dart`, dont elles sont l'invariant partagé avec le jumeau Python.
({int start, int end}) _cellBounds(int index, int count, int length) {
  final start = index * length ~/ count;
  var end = (index + 1) * length ~/ count;
  if (end < start + 1) end = start + 1;
  if (end > length) end = length;
  return (start: start, end: end);
}

/// Image couleur reconstruite depuis les trois plans — le chemin coûteux.
///
/// Conversion BT.601 pleine plage, en arithmétique entière. Elle n'est utile
/// qu'à l'affichage et à la comparaison : l'empreinte n'a jamais besoin des
/// couleurs.
img.Image rgbImage(
  Uint8List luma,
  Uint8List chromaU,
  Uint8List chromaV, {
  required int width,
  required int height,
  required int lumaRowStride,
  required int chromaRowStride,
  required int chromaPixelStride,
  PixelBox? crop,
}) {
  final box = clampBox(crop ?? wholeFrame(width, height), width, height);
  final out = img.Image(width: box.width, height: box.height, numChannels: 3);

  for (var y = 0; y < box.height; y++) {
    final sourceY = box.top + y;
    final lumaRow = sourceY * lumaRowStride;
    final chromaRow = (sourceY >> 1) * chromaRowStride;
    for (var x = 0; x < box.width; x++) {
      final sourceX = box.left + x;
      final yy = luma[lumaRow + sourceX];
      final chromaOffset = chromaRow + (sourceX >> 1) * chromaPixelStride;
      final u =
          (chromaOffset < chromaU.length ? chromaU[chromaOffset] : 128) - 128;
      final v =
          (chromaOffset < chromaV.length ? chromaV[chromaOffset] : 128) - 128;

      out.setPixelRgb(
        x,
        y,
        (yy + 1.402 * v).round().clamp(0, 255),
        (yy - 0.344136 * u - 0.714136 * v).round().clamp(0, 255),
        (yy + 1.772 * u).round().clamp(0, 255),
      );
    }
  }
  return out;
}
