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
/// Ce module doit rester le jumeau de `api/app/vision/card_bounds.py`, **et
/// c'est lui qui fait foi** : le seuillage local a été conçu, balayé et retenu
/// ici, sur le banc `tool/framing_bench.dart`, parce que c'est ce code qui
/// tourne sur l'appareil. Une divergence se corrige donc en ramenant le Python
/// vers ce fichier, jamais l'inverse — et elle ne se voit pas : elle produit
/// des coins différents, donc une empreinte différente, et le scan échoue en
/// silence.
///
/// Parité vérifiée sur une photo réelle : les deux implémentations rendent des
/// empreintes distantes d'**un bit**, ce qui est l'ordre de grandeur imputable
/// aux seuls décodeurs JPEG (mesuré ailleurs : 0 bit en médiane, 5 au maximum).
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
///
/// **Ce garde-fou ne rattrape pas un masque faux.** Une photo de téléphone en
/// portrait vaut 0,750 et une carte 63:88 vaut 0,716 : 0,034 d'écart, quand la
/// tolérance en accepte 0,30. Un masque qui retient l'image entière passe donc
/// le contrôle sans broncher. C'est au seuillage de ne pas produire ce
/// masque-là — pas à cette constante de le rattraper.
const double aspectTolerance = 0.30;

/// Fenêtre du seuillage local, en fraction du petit côté de l'image d'analyse.
///
/// Elle doit être assez large pour qu'un pixel de bordure « voie » la table
/// autour de lui — sinon la bordure, uniforme sur sa propre épaisseur, ne se
/// distingue plus de son voisinage —, et assez étroite pour suivre l'éclairage
/// plutôt que le subir. Balayée sur le banc de cadrage (40 cartes × 8 régimes)
/// à 6, 12, 20, 30 et 45 %, elle donne 105, 105, 102, 91 puis 60 cartes
/// reconnues sur les 120 régimes à lampe : plat en deçà de 20 %, puis la
/// fenêtre devient trop large pour épouser l'éclairage. 12 % est pris au milieu
/// du plateau.
const double localWindow = 0.12;

/// Sous quelle fraction du niveau local de la table un pixel compte pour du
/// carton.
///
/// **C'est l'ancien seuil global de 0,72, rendu local** — même forme, même rôle,
/// seule la référence a changé (voir [_cardMask]). La valeur diffère parce que
/// la référence n'est plus la même : un niveau de table estimé sur un voisinage
/// tombe plus bas que la médiane claire de toute l'image, il faut donc un
/// plafond plus haut pour rattraper la même bordure.
///
/// **Balayée de 0,60 à 1,00** sur le banc de cadrage (40 cartes × 8 régimes),
/// elle rend, en cartes reconnues sur 320 : 268, 278, 283, 287, **291**, 296,
/// 275, 183, 69. Le sommet nominal est à 0,88 — et pourtant 0,84 est retenu.
///
/// **Parce que 0,88 n'a plus de marge.** Sur une table nue, sans carte, ce
/// plafond marque déjà 10 % des pixels : le grain du bois y passe pour du
/// carton, et seules la recherche de composante et l'aire minimale empêchent la
/// détection d'inventer une carte. À 0,84 la même table ne marque **aucun
/// pixel**. À 0,96 elle en marque 53 % et la détection rend un quadrilatère de
/// la taille de l'image, de rapport 0,735 — que la tolérance d'aspect laisse
/// passer sans broncher, exactement le mode de défaillance que ce module
/// existe pour éviter.
///
/// Rejoué sur une table au grain doublé, le classement s'inverse : 283, 286,
/// **292**, 283, 221 pour 0,72 à 0,92. 0,84 est le seul point haut des deux
/// tirages, quand 0,88 gagne 5 cartes sur l'un et en perd 9 sur l'autre. On
/// prend le sommet stable, pas le sommet d'un seul bruit.
const double cardCeiling = 0.84;

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
CardQuad? findCard(img.Image photo, {String game = 'magic'}) {
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
  if (!_hasCardAspect(quad.aspect, game)) return null;

  return quad.scaled(scale);
}

/// Ce rapport est-il celui d'une carte de ce jeu, dans l'une de ses
/// orientations ?
///
/// **Une carte couchée a le rapport inverse d'une carte debout**, et rien de
/// plus : mesuré sur le catalogue, 1039 × 744 contre 744 × 1039, soit 1,397
/// contre 0,716. Les 64 champs de bataille Riftbound étaient donc rejetés à
/// 0,68 du rapport attendu, pour une tolérance de 0,30 — et leur gabarit,
/// mesuré de longue date, n'avait jamais pu servir.
///
/// **L'orientation couchée n'est ouverte qu'aux jeux qui en ont une.** En
/// Magic, toutes les cartes sont debout : y accepter les deux reviendrait à
/// laisser passer n'importe quel rectangle, alors que le mode de défaillance
/// connu de ce module est justement le quadrilatère faux qui franchit le
/// contrôle d'aspect — une photo de téléphone en portrait vaut 0,750, à 0,034
/// seulement d'une carte.
bool _hasCardAspect(double aspect, String game) {
  if ((aspect - cardAspect).abs() <= aspectTolerance) return true;
  final couche = CardFrame.values.any((f) => f.game == game && f.landscape);
  return couche && (aspect - 1 / cardAspect).abs() <= aspectTolerance;
}

/// Proportions d'une carte Magic, 63 × 88 mm.
const double cardAspect = 63 / 88;

/// Ce que la détection voit, avant qu'elle ne conclue.
///
/// **Exposé au seul usage du diagnostic.** Quand `findCard` rend un
/// quadrilatère faux, aucun chiffre ne dit pourquoi : c'est le masque qu'il
/// faut voir. `tool/probe_photo.dart` l'écrit en image, et l'erreur saute alors
/// aux yeux — une ombre qui relie la carte au bord, un fond pris pour du carton.
/// Rien dans l'application n'appelle cette fonction.
({List<bool> mask, List<bool>? shape, double fill, int width, int height})
debugDetection(img.Image image) {
  final scale = image.width > analysisWidth ? image.width / analysisWidth : 1.0;
  final small = scale > 1
      ? img.copyResize(
          image,
          width: analysisWidth,
          height: (image.height / scale).round().clamp(1, image.height),
          interpolation: img.Interpolation.linear,
        )
      : image;

  final mask = _cardMask(small);
  _fillHoles(mask, small.width, small.height);
  final shape = _largestComponent(mask, small.width, small.height);

  var fill = 0.0;
  if (shape != null) {
    var area = 0;
    var minX = small.width, maxX = -1, minY = small.height, maxY = -1;
    for (var i = 0; i < shape.length; i++) {
      if (!shape[i]) continue;
      area++;
      final x = i % small.width;
      final y = i ~/ small.width;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    final box = (maxX - minX + 1) * (maxY - minY + 1);
    fill = box > 0 ? area / box : 0;
  }

  return (
    mask: mask,
    shape: shape,
    fill: fill,
    width: small.width,
    height: small.height,
  );
}

/// Ce qui est carte plutôt que table.
///
/// **Une seule signature : le carton est plus sombre que la table qui
/// l'entoure.** Une carte, dans les deux jeux, porte un cadre sombre fermé sur
/// tout son pourtour ; cet anneau suffit à la délimiter, car [_fillHoles] rend
/// ensuite plein tout ce qu'il cerne — ni l'illustration ni le pavé de règles
/// n'ont à être reconnus pour eux-mêmes.
///
/// **Pourquoi la référence est locale.** Elle était l'image entière : un pixel
/// comptait pour du carton s'il tombait sous 72 % de la clarté médiane de la
/// table. Sous éclairage latéral, c'est intenable — le coin de table le plus
/// sombre passe sous ce seuil, rejoint la carte, et [_largestComponent] rend
/// une forme couvrant la photo entière. Le banc de cadrage le chiffre : sur les
/// 120 photos à lampe, 14 cartes reconnues avec la référence globale, 111 avec
/// une référence locale.
///
/// **Pourquoi la moitié claire du voisinage, et non sa moyenne.** Comparer
/// chaque pixel à la moyenne de son voisinage corrige bien l'éclairage, mais
/// c'est une règle de **contraste**, pas de niveau : elle retient par
/// construction à peu près la moitié la plus sombre de tout voisinage, où qu'il
/// soit. La carte en ressort **creuse** — son pourtour et ses détails sombres,
/// rien d'autre —, et si elle finit pleine c'est uniquement parce que
/// [_fillHoles] bouche ce que ce pourtour cerne. Tout tient alors à un anneau
/// d'un pixel.
///
/// Le banc montre ce que cela coûte quand l'anneau cède. Sur une carte à fond
/// perdu, dont l'illustration claire touche la table sans marche de clarté — 126
/// à 160 de part et d'autre du bord, mesuré —, il n'y a rien à cerner : le fond
/// s'engouffre, remplit l'intérieur vide, et la plus grande composante n'est
/// plus qu'un bas de carte. Forme retenue : 41,7 % de l'image au lieu de 68 %,
/// coins hauts à `y = 187` au lieu de `y = 41`, rapport 1,02 quand une carte
/// vaut 0,716 — donc abandon. À l'échelle du banc, la moyenne simple perd 4
/// cartes sur les 200 photos sans lampe et fait passer les abandons de 5 à 23.
///
/// La référence retenue est donc la clarté moyenne de la **seule moitié claire**
/// du voisinage : le niveau local de la table, estimé en écartant ce que la
/// carte y met de sombre. C'est une règle de **niveau**, et elle se resserre ou
/// se relâche exactement où il faut. Sur un voisinage plat, la moitié claire ne
/// dépasse sa moyenne que de 3 % : la règle reste aussi stricte qu'avant, et une
/// table nue ne marque aucun pixel. Sur un voisinage contrasté, la moitié claire
/// s'en détache largement, le seuil monte avec elle, et le corps de la carte
/// sort plein au lieu de creux. Sur la même photo : 56,2 % de pixels marqués au
/// lieu de 43,0 %, forme retenue 69,3 %, coins à un pixel près de la vérité.
/// Sur le banc entier : 181 cartes reconnues sur les 200 photos sans lampe
/// (contre 179 à la référence globale et 175 à la moyenne locale), 110 sur les
/// 120 à lampe, et les abandons ramenés de 23 à 14.
///
/// **Une image intégrale, donc un coût linéaire.** La moyenne d'une fenêtre
/// quelconque se lit en quatre accès dans la table des sommes cumulées ; le coût
/// ne dépend plus de la taille de la fenêtre, et les trois moyennes de boîte
/// restent au même ordre de grandeur que la lecture des pixels.
///
/// **Ce qui a été retiré, et pourquoi.** Un second critère faisait entrer tout
/// pixel de saturation supérieure à 0,38, au motif qu'une illustration est plus
/// colorée qu'un plateau de bois. C'est l'inverse qui se mesure : un bureau de
/// bois clair dépasse ce seuil sur la quasi-totalité de sa surface, et ce
/// critère à lui seul reconduit l'échec — 29 bits de la bonne carte en le
/// gardant, 8 en le retirant, à seuillage local identique.
///
/// **Limite assumée** : une carte à bordure *blanche* — le cadre Magic d'avant
/// 1993 —, ou une carte à fond perdu dont l'illustration claire touche le bord,
/// n'a sur cette portion aucun pourtour plus sombre que la table. C'est alors
/// son cadre intérieur qui forme l'anneau, et le quadrilatère rendu est
/// légèrement plus petit que la carte.
List<bool> _cardMask(img.Image image) {
  final width = image.width;
  final height = image.height;
  final count = width * height;
  final greys = Float32List(count);

  var index = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final pixel = image.getPixel(x, y);
      greys[index++] =
          (pixel.r.toDouble() + pixel.g.toDouble() + pixel.b.toDouble()) / 3;
    }
  }

  // Le petit côté fixe le rayon : sur une photo en portrait, se caler sur la
  // largeur donnerait la même fenêtre, alors que se caler sur la hauteur la
  // rendrait plus grossière sans rien apporter.
  final radius = math.max(
    1,
    (math.min(width, height) * localWindow / 2).round(),
  );

  final mean = _boxMean(greys, width, height, radius);

  // Ne retenir que ce qui dépasse sa propre moyenne locale : sur la table, à peu
  // près la moitié des pixels ; le long d'un bord de carte, la table seule.
  final lit = Float32List(count);
  final share = Float32List(count);
  for (var i = 0; i < count; i++) {
    if (greys[i] > mean[i]) {
      lit[i] = greys[i];
      share[i] = 1;
    }
  }
  // Les deux moyennes portent sur la même fenêtre : leur quotient est donc
  // exactement la moyenne des seuls pixels clairs, sans avoir à les compter à
  // part. Une fenêtre qui n'en contient aucun — un aplat parfaitement uni —
  // retombe sur la moyenne, qui y vaut la même chose.
  final litMean = _boxMean(lit, width, height, radius);
  final litShare = _boxMean(share, width, height, radius);

  final mask = List<bool>.filled(count, false, growable: false);
  for (var i = 0; i < count; i++) {
    final table = litShare[i] > 0 ? litMean[i] / litShare[i] : mean[i];
    mask[i] = greys[i] < table * cardCeiling;
  }
  return mask;
}

/// Moyenne de [source] sur la fenêtre carrée de rayon [radius], par image
/// intégrale — quatre accès par pixel, quelle que soit la fenêtre.
///
/// **La fenêtre est écrêtée au cadre, et la moyenne divisée par ce qui reste.**
/// La tentation est de voir là un artefact de bord : un pixel proche du cadre
/// verrait un voisinage tronqué, donc moins fiable. Mesuré, ce n'en est pas un.
/// Les trois traitements possibles — écrêter, glisser la fenêtre vers
/// l'intérieur pour lui garder sa taille, ou prolonger l'image en miroir — ont
/// été joués sur le banc entier : **résultats identiques à la carte près**, sur
/// les huit régimes. Ce n'est pas là que se jouent les cadrages à marge large.
Float32List _boxMean(Float32List source, int width, int height, int radius) {
  // Sommes cumulées, décalées d'une ligne et d'une colonne pour que la fenêtre
  // collée au bord n'ait pas besoin d'un cas particulier.
  final sums = Float64List((width + 1) * (height + 1));
  for (var y = 0; y < height; y++) {
    var row = 0.0;
    for (var x = 0; x < width; x++) {
      row += source[y * width + x];
      sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + row;
    }
  }

  final out = Float32List(width * height);
  for (var y = 0; y < height; y++) {
    final y0 = y - radius < 0 ? 0 : y - radius;
    final y1 = y + radius > height - 1 ? height - 1 : y + radius;
    for (var x = 0; x < width; x++) {
      final x0 = x - radius < 0 ? 0 : x - radius;
      final x1 = x + radius > width - 1 ? width - 1 : x + radius;
      final total =
          sums[(y1 + 1) * (width + 1) + x1 + 1] -
          sums[y0 * (width + 1) + x1 + 1] -
          sums[(y1 + 1) * (width + 1) + x0] +
          sums[y0 * (width + 1) + x0];
      out[y * width + x] = total / ((x1 - x0 + 1) * (y1 - y0 + 1));
    }
  }
  return out;
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
  // **Un seul tampon, réutilisé.** Il était alloué à l'intérieur de la boucle,
  // soit une fois par composante rencontrée, chacune payant un tableau de la
  // taille de l'image entière. Le contenu n'a pas à être remis à zéro : `size`
  // dit jusqu'où il est rempli, et rien au-delà n'est jamais relu.
  //
  // **Le gain dépend entièrement du nombre de composantes**, et il est donc
  // modeste là où on l'attendrait le plus. Mesuré sur une photo réelle de
  // 3072 × 4080, dont le masque tient en quelques formes : `findCard` passe de
  // 88,9 à 83,6 ms de médiane, soit 6 %. Sur une scène morcelée — table
  // texturée, reflets multiples — le même changement vaut bien davantage. Il
  // reste juste dans tous les cas : une allocation par composante ne sert à
  // rien, quel qu'en soit le prix.
  final members = Int32List(width * height);
  List<bool>? best;
  var bestSize = 0;

  for (var start = 0; start < mask.length; start++) {
    if (!mask[start] || seen[start] != 0) continue;

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
