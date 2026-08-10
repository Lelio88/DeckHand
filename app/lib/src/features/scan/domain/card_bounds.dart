/// Retrouver les quatre coins d'une carte dans une photo, et y lire son
/// illustration.
///
/// **Ce que ce module remplace.** Le pipeline découpait l'illustration à une
/// position fixe dans le plus grand rectangle aux proportions d'une carte,
/// centré dans la photo — donc en supposant que la carte y tienne exactement.
/// Mesuré, cet espoir tolère 2 à 3 % d'écart, soit 2,6 mm sur la hauteur d'une
/// carte. Le banc `api/app/measure/framing_bench.py` chiffre ce que cela
/// coûte : à 8 % de marge et 2° de travers — un cadrage ordinaire —, **aucune
/// carte sur quarante n'était reconnue**. Avec les coins détectés, la médiane
/// tombe à 4 bits et ne bouge plus, quel que soit le soin apporté à la photo.
///
/// **Pourquoi ce cas réussit là où l'étalement a échoué.** Les impasses de
/// `docs/spread-detection.md` portent toutes sur une photo de plusieurs cartes,
/// et ce qui y ruine la segmentation est le **contact** : deux voisines se
/// soudent en une forme unique, de proche en proche. Ici il n'y a qu'un objet,
/// occupant l'essentiel de l'image. La difficulté disparaît avec la voisine.
///
/// **Les quatre coins plutôt que la boîte englobante.** Une carte tournée de
/// cinq degrés a une boîte nettement plus large qu'elle ; y découper une zone
/// en proportions raterait l'illustration autant qu'avant.
///
/// **On n'redresse jamais l'image.** Redresser demanderait de résoudre une
/// homographie puis de rééchantillonner toute la photo pour n'en garder qu'un
/// huitième. La zone voulue est lue directement, en interpolant les quatre
/// coins : exact pour une carte photographiée de face, même tournée, et
/// suffisant pour la perspective légère d'une photo à main levée.
///
/// Ce module doit rester le jumeau de `api/app/vision/card_bounds.py`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'art_box.dart';

/// Largeur à laquelle l'analyse travaille. La carte y reste assez grande pour
/// que ses bords soient nets, et le parcours de composantes — le seul point
/// coûteux — y coûte quatre fois moins que sur la photo entière.
const int analysisWidth = 400;

/// Une carte occupe au moins cette fraction de la photo. En deçà, ce qu'on a
/// trouvé est une tache sur la table, pas une carte.
const double minCardArea = 0.10;

/// Écart toléré au rapport d'une carte. Large à dessein : une carte vue de
/// biais s'écarte de ses proportions nominales, et rejeter trop strictement
/// reviendrait à ne détecter que les photos déjà parfaites.
const double aspectTolerance = 0.30;

/// Un point de l'image, en pixels.
typedef Point = ({double x, double y});

/// Les quatre coins d'une carte, dans l'ordre où on la lit.
class CardQuad {
  const CardQuad({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  final Point topLeft;
  final Point topRight;
  final Point bottomRight;
  final Point bottomLeft;

  CardQuad scaled(double factor) => CardQuad(
    topLeft: (x: topLeft.x * factor, y: topLeft.y * factor),
    topRight: (x: topRight.x * factor, y: topRight.y * factor),
    bottomRight: (x: bottomRight.x * factor, y: bottomRight.y * factor),
    bottomLeft: (x: bottomLeft.x * factor, y: bottomLeft.y * factor),
  );

  /// Largeur sur hauteur, moyennée sur les deux paires de côtés.
  double get aspect {
    final top = _distance(topLeft, topRight);
    final bottom = _distance(bottomLeft, bottomRight);
    final left = _distance(topLeft, bottomLeft);
    final right = _distance(topRight, bottomRight);
    final height = (left + right) / 2;
    return height == 0 ? 0 : ((top + bottom) / 2) / height;
  }

  static double _distance(Point a, Point b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}

/// Coins de la carte, en pixels de [photo].
///
/// Rend `null` plutôt qu'un quadrilatère douteux : l'appelant retombe alors sur
/// le cadrage centré, c'est-à-dire sur le comportement d'avant. **Une détection
/// qui échoue ne doit jamais faire moins bien que son absence.**
CardQuad? findCard(img.Image photo) {
  if (photo.width < 8 || photo.height < 8) return null;

  final scale = photo.width > analysisWidth ? photo.width / analysisWidth : 1.0;
  final small = scale > 1
      ? img.copyResize(
          photo,
          width: analysisWidth,
          height: (photo.height / scale).round().clamp(1, photo.height),
          interpolation: img.Interpolation.linear,
        )
      : photo;

  final mask = _cardMask(small);
  _fillHoles(mask, small.width, small.height);
  final shape = _largestComponent(mask, small.width, small.height);
  if (shape == null) return null;

  var area = 0;
  for (final on in shape) {
    if (on) area++;
  }
  if (area < minCardArea * small.width * small.height) return null;

  final quad = _cornersOf(shape, small.width, small.height);
  if (quad == null) return null;
  if ((quad.aspect - cardAspect).abs() > aspectTolerance) return null;

  return quad.scaled(scale);
}

/// Proportions d'une carte Magic, 63 × 88 mm.
const double cardAspect = 63 / 88;

/// Ce qui est carte plutôt que table.
///
/// Deux signatures, réunies : une carte porte une **bordure sombre** sur tout
/// son pourtour, et son illustration est plus **saturée** qu'un plateau de bois
/// ou une nappe. L'une sans l'autre laisse passer les cartes claires ou les
/// tables colorées ; ensemble elles tiennent. Le seuil de table est pris sur la
/// moitié la plus lumineuse de l'image, pour qu'une carte sombre occupant la
/// moitié du cadre ne tire pas la référence vers le bas.
List<bool> _cardMask(img.Image image) {
  final count = image.width * image.height;
  final greys = Float32List(count);
  final saturations = Float32List(count);

  var index = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      final r = pixel.r.toDouble();
      final g = pixel.g.toDouble();
      final b = pixel.b.toDouble();
      greys[index] = (r + g + b) / 3;
      final high = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final low = r < g ? (r < b ? r : b) : (g < b ? g : b);
      saturations[index] = high > 0 ? (high - low) / high : 0;
      index++;
    }
  }

  final sorted = Float32List.fromList(greys)..sort();
  final floor = sorted[(sorted.length * 0.40).floor().clamp(0, count - 1)];
  final bright = <double>[];
  for (final g in greys) {
    if (g > floor) bright.add(g);
  }
  bright.sort();
  final table = bright.isEmpty ? floor : bright[bright.length ~/ 2];

  return List<bool>.generate(
    count,
    (i) => greys[i] < table * 0.72 || saturations[i] > 0.38,
    growable: false,
  );
}

/// Bouche ce qui est cerné par la forme.
///
/// Le panneau de règles d'une carte est clair comme la table : sans ce
/// bouchage, il creuse la forme et la coupe en deux. Un trou se reconnaît à ce
/// qu'il **ne touche pas le bord de l'image** ; on inonde donc le fond depuis
/// les bords, et ce qui reste sec appartient à la carte qui l'entoure.
void _fillHoles(List<bool> mask, int width, int height) {
  final outside = Uint8List(width * height);
  final stack = Int32List(width * height);
  var top = 0;

  void push(int index) {
    if (mask[index] || outside[index] != 0) return;
    outside[index] = 1;
    stack[top++] = index;
  }

  for (var x = 0; x < width; x++) {
    push(x);
    push((height - 1) * width + x);
  }
  for (var y = 0; y < height; y++) {
    push(y * width);
    push(y * width + width - 1);
  }

  while (top > 0) {
    final index = stack[--top];
    final x = index % width;
    final y = index ~/ width;
    if (x > 0) push(index - 1);
    if (x < width - 1) push(index + 1);
    if (y > 0) push(index - width);
    if (y < height - 1) push(index + width);
  }

  for (var i = 0; i < mask.length; i++) {
    if (outside[i] == 0) mask[i] = true;
  }
}

/// La plus grande forme d'un seul tenant.
///
/// Sur une photo d'une seule carte, c'est elle. Les autres composantes sont des
/// ombres, des reflets, un bout de manche — toutes plus petites, et aucune ne
/// peut fusionner avec la carte puisqu'il n'y a pas de voisine à toucher.
List<bool>? _largestComponent(List<bool> mask, int width, int height) {
  final seen = Uint8List(width * height);
  final stack = Int32List(width * height);
  List<bool>? best;
  var bestSize = 0;

  for (var start = 0; start < mask.length; start++) {
    if (!mask[start] || seen[start] != 0) continue;

    final members = Int32List(width * height);
    var size = 0;
    var top = 0;
    seen[start] = 1;
    stack[top++] = start;

    while (top > 0) {
      final index = stack[--top];
      members[size++] = index;
      final x = index % width;
      final y = index ~/ width;

      void visit(int next) {
        if (mask[next] && seen[next] == 0) {
          seen[next] = 1;
          stack[top++] = next;
        }
      }

      if (x > 0) visit(index - 1);
      if (x < width - 1) visit(index + 1);
      if (y > 0) visit(index - width);
      if (y < height - 1) visit(index + width);
    }

    if (size > bestSize) {
      bestSize = size;
      final shape = List<bool>.filled(mask.length, false);
      for (var i = 0; i < size; i++) {
        shape[members[i]] = true;
      }
      best = shape;
    }
  }

  return best;
}

/// Les quatre coins d'une forme rectangulaire, même tournée.
///
/// **Par les extrêmes des sommes et des différences.** Le coin haut-gauche
/// minimise `x + y`, le bas-droit le maximise ; le haut-droit maximise `x - y`,
/// le bas-gauche le minimise. C'est exact pour un rectangle quelle que soit sa
/// rotation, et insensible au bruit du contour — un pixel isolé ne peut décaler
/// un coin que de lui-même.
CardQuad? _cornersOf(List<bool> shape, int width, int height) {
  var minSum = 1 << 30, maxSum = -(1 << 30);
  var minDiff = 1 << 30, maxDiff = -(1 << 30);
  Point? topLeft, bottomRight, topRight, bottomLeft;

  for (var index = 0; index < shape.length; index++) {
    if (!shape[index]) continue;
    final x = index % width;
    final y = index ~/ width;
    final sum = x + y;
    final diff = x - y;

    if (sum < minSum) {
      minSum = sum;
      topLeft = (x: x.toDouble(), y: y.toDouble());
    }
    if (sum > maxSum) {
      maxSum = sum;
      bottomRight = (x: x.toDouble(), y: y.toDouble());
    }
    if (diff > maxDiff) {
      maxDiff = diff;
      topRight = (x: x.toDouble(), y: y.toDouble());
    }
    if (diff < minDiff) {
      minDiff = diff;
      bottomLeft = (x: x.toDouble(), y: y.toDouble());
    }
  }

  if (topLeft == null ||
      topRight == null ||
      bottomRight == null ||
      bottomLeft == null) {
    return null;
  }
  return CardQuad(
    topLeft: topLeft,
    topRight: topRight,
    bottomRight: bottomRight,
    bottomLeft: bottomLeft,
  );
}

/// Lit la zone [box] de la carte décrite par [quad], sans redresser la photo.
///
/// Chaque pixel de sortie correspond à un couple `(u, v)` en proportions de la
/// carte ; sa position dans la photo s'obtient en interpolant les quatre coins,
/// puis la couleur en interpolant les quatre pixels voisins. **Le plus proche
/// voisin coûterait trois bits** — mesuré — sur un seuil de confiance qui n'en
/// compte que douze.
img.Image sampleArt(
  img.Image photo,
  CardQuad quad,
  ArtBox box, {
  int width = 256,
  int height = 190,
}) {
  final out = img.Image(width: width, height: height);

  for (var row = 0; row < height; row++) {
    final v = box.top + (box.bottom - box.top) * (row + 0.5) / height;
    for (var col = 0; col < width; col++) {
      final u = box.left + (box.right - box.left) * (col + 0.5) / width;

      final x =
          (1 - u) * (1 - v) * quad.topLeft.x +
          u * (1 - v) * quad.topRight.x +
          u * v * quad.bottomRight.x +
          (1 - u) * v * quad.bottomLeft.x;
      final y =
          (1 - u) * (1 - v) * quad.topLeft.y +
          u * (1 - v) * quad.topRight.y +
          u * v * quad.bottomRight.y +
          (1 - u) * v * quad.bottomLeft.y;

      _writeBilinear(photo, x, y, out, col, row);
    }
  }
  return out;
}

/// Écrit dans [out] la couleur lue en `(x, y)` de [source], interpolée entre
/// les quatre pixels voisins.
void _writeBilinear(
  img.Image source,
  double x,
  double y,
  img.Image out,
  int col,
  int row,
) {
  final cx = x.clamp(0.0, (source.width - 1).toDouble());
  final cy = y.clamp(0.0, (source.height - 1).toDouble());
  final x0 = cx.floor();
  final y0 = cy.floor();
  final x1 = x0 + 1 < source.width ? x0 + 1 : x0;
  final y1 = y0 + 1 < source.height ? y0 + 1 : y0;
  final fx = cx - x0;
  final fy = cy - y0;

  final p00 = source.getPixel(x0, y0);
  final p10 = source.getPixel(x1, y0);
  final p01 = source.getPixel(x0, y1);
  final p11 = source.getPixel(x1, y1);

  double blend(num a, num b, num c, num d) =>
      (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;

  out.setPixelRgb(
    col,
    row,
    blend(p00.r, p10.r, p01.r, p11.r),
    blend(p00.g, p10.g, p01.g, p11.g),
    blend(p00.b, p10.b, p01.b, p11.b),
  );
}
