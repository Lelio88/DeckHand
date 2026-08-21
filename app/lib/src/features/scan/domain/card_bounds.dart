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
///
/// **Et elle s'est rompue une fois, exactement comme annoncé.** Les deux
/// fichiers ne réduisaient pas la photo de la même manière — voir
/// [_analysisImage] —, et sur une carte photographiée sur un tissu le Dart
/// rendait un quadrilatère couvrant 81 % de l'image quand le Python rendait la
/// carte. Rien ne l'avait signalé : ni les tests, dont les figures sont trop
/// petites pour être réduites, ni le banc, dont les facteurs s'arrêtent juste
/// avant. Ce qui l'a révélée est d'avoir joué la **même photo** dans les deux
/// implémentations et comparé les coins — c'est le seul contrôle qui l'aurait
/// vue, et il ne coûte rien.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'art_box.dart';
import 'card_geometry.dart';

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

  /// Le même quadrilatère, lu comme si la carte était tournée de [turns] quarts
  /// de tour.
  ///
  /// **Aucun pixel ne bouge** : seuls les coins changent de rôle. Lire la carte
  /// dans l'autre sens revient à décider quel côté est le haut, et c'est
  /// exactement ce qui manquait à une carte couchée photographiée droite — le
  /// gabarit était bon, la zone était bonne, mais elle était parcourue de
  /// travers.
  ///
  /// [turns] compte les quarts de tour dans le sens horaire. Les quatre valeurs
  /// sont acceptées ; 2 est le demi-tour, dont on a besoin parce qu'une
  /// empreinte n'y est pas invariante : mesuré sur une carte réelle, la même
  /// photo tournée d'un quart dans un sens sort au rang 1, et au rang 466 dans
  /// l'autre.
  CardQuad quarterTurned(int turns) => switch (turns % 4) {
    1 => CardQuad(
      topLeft: bottomLeft,
      topRight: topLeft,
      bottomRight: topRight,
      bottomLeft: bottomRight,
    ),
    2 => CardQuad(
      topLeft: bottomRight,
      topRight: bottomLeft,
      bottomRight: topLeft,
      bottomLeft: topRight,
    ),
    3 => CardQuad(
      topLeft: topRight,
      topRight: bottomRight,
      bottomRight: bottomLeft,
      bottomLeft: topLeft,
    ),
    _ => this,
  };

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
CardQuad? findCard(
  img.Image photo, {
  String game = 'magic',
  bool sideways = false,
}) {
  if (photo.width < 8 || photo.height < 8) return null;

  final (:small, :scale) = _analysisImage(photo);
  return _findIn(small, scale, game, sideways);
}

/// Coins de la carte, lus **directement dans le plan de luminance** d'une image
/// de caméra.
///
/// **Ce que cela évite.** [findCard] réclame un `img.Image` ; une image de
/// caméra n'en est pas un, et la construire coûte une écriture de trois canaux
/// par pixel pour un plan qui en porte déjà un seul, le bon. Mesuré sur
/// l'appareil, 1280 × 720 : **10,4 ms** pour matérialiser l'image, avant même
/// que la détection commence. Ce chemin-ci descend jusqu'à la taille d'analyse
/// sans jamais bâtir l'image entière.
///
/// C'est le trajet qu'`artHashFromLuma` a déjà emprunté pour l'empreinte, où il
/// avait fait passer 12,4 ms à 0,7.
///
/// **Le résultat est le même, et c'est vérifiable.** `_cardMask` ramène chaque
/// pixel à la moyenne de ses trois canaux ; sur une image grise construite
/// depuis `Y`, cette moyenne vaut `Y`. Les deux chemins produisent donc la même
/// image d'analyse, au bit près — un test le vérifie sur une figure au pas de
/// ligne irrégulier, le cas que seul un vrai capteur produit.
///
/// [rowStride] est le pas d'une ligne en octets, que le capteur choisit et qui
/// dépasse souvent la largeur ; l'ignorer produirait une image cisaillée, pas
/// une erreur.
CardQuad? findCardInLuma(
  Uint8List luma, {
  required int width,
  required int height,
  required int rowStride,
  int pixelStride = 1,
  String game = 'magic',
  bool sideways = false,
}) {
  if (width < 8 || height < 8) return null;

  final scale = width > analysisWidth ? width / analysisWidth : 1.0;
  final target = scale > 1 ? analysisWidth : width;
  final targetHeight = scale > 1
      ? (height / scale).round().clamp(1, height)
      : height;
  final small = _boxReduceLuma(
    luma,
    width: width,
    height: height,
    rowStride: rowStride,
    pixelStride: pixelStride,
    outWidth: target,
    outHeight: targetHeight,
  );
  return _findIn(small, scale, game, sideways);
}

/// Le corps commun aux deux entrées : tout ce qui suit la mise à la taille
/// d'analyse. **Aucune des deux ne doit en diverger** — c'est ce qui garantit
/// qu'elles rendent le même quadrilatère.
CardQuad? _findIn(img.Image small, double scale, String game, bool sideways) {
  final mask = _cardMask(small);
  _fillHoles(mask, small.width, small.height);
  final shape = _largestComponent(mask, small.width, small.height);
  if (shape == null) return null;

  var area = 0;
  for (final on in shape) {
    if (on != 0) area++;
  }
  if (area < minCardArea * small.width * small.height) return null;

  final quad = _cornersOf(shape, small.width, small.height);
  if (quad == null) return null;
  if (!_hasCardAspect(quad.aspect, game, sideways: sideways)) return null;

  return quad.scaled(scale);
}

/// La photo ramenée à la taille d'analyse, et le facteur qui l'y a menée.
///
/// **La réduction moyenne le voisinage entier, elle ne l'interpole pas.**
/// `Interpolation.linear` mélange les quatre pixels immédiats, quel que soit le
/// facteur ; à 1/10 — une photo de téléphone de 4000 px ramenée à 400 — cela
/// revient à n'en regarder que quatre sur cent, et à ignorer les autres. Une
/// texture fine ne disparaît alors pas : elle **replie**. La trame d'un tissu, le grain
/// d'un plateau de bois deviennent un bruit à l'échelle du pixel d'analyse, et
/// le seuillage local, qui compare chaque pixel à la clarté de son voisinage,
/// lit ce bruit comme du carton. `Interpolation.average` moyenne le bloc source
/// entier : la texture s'éteint au lieu de se replier.
///
/// Mesuré sur une carte de papier posée sur un tissu, à seuillage identique :
/// en interpolant, 82,5 % de l'image est tenue pour du carton et la détection
/// rend un quadrilatère couvrant 81 % de l'aire, de rapport 1,258 — que la
/// tolérance d'aspect laisse passer, puisqu'une carte couchée vaut 1,397. En
/// moyennant, la carte ressort seule, à 38 % de l'image et au rapport 0,724.
///
/// **C'est le facteur qui décide, pas le tissu.** Rejouée sur la même photo
/// pré-réduite à des tailles croissantes, l'interpolation tient jusqu'à un
/// facteur de 2,7 et cède à partir de 3 : 38 % de l'image et rapport 0,746 d'un
/// côté, 70 % et 1,276 de l'autre. Or le banc de cadrage compose des photos de
/// 650 à 1100 px de large, soit des facteurs de 1,6 à **2,7** — il s'arrête
/// exactement un cran avant le défaut, et ne pouvait donc pas le voir. Les tests
/// unitaires non plus : leurs figures font 300 px de large, sous [analysisWidth],
/// et ne sont jamais réduites.
///
/// **La leçon existait à côté depuis toujours.** `art_hash.dart` calcule sa
/// réduction à la main, par un filtre de moyenne à bornes entières, précisément
/// parce que deux bibliothèques ne rééchantillonnent pas pareil. Ce module ne
/// l'avait pas appliquée — et son jumeau Python, lui, réduisait avec un filtre
/// dont Pillow élargit le support à mesure que le facteur grandit. La parité
/// était donc rompue **en silence**, dans le sens où le Python avait raison.
///
/// Le prix est une lecture de chaque pixel source, là où l'interpolation en
/// lisait quatre par pixel de sortie : sur une photo de 12 Mpx, `findCard` passe
/// de 26 à 53 ms — voir [_boxReduce], qui explique pourquoi ce n'est pas
/// davantage.
({img.Image small, double scale}) _analysisImage(img.Image photo) {
  final scale = photo.width > analysisWidth ? photo.width / analysisWidth : 1.0;
  if (scale <= 1) return (small: photo, scale: 1.0);
  final height = (photo.height / scale).round().clamp(1, photo.height);
  return (small: _boxReduce(photo, analysisWidth, height), scale: scale);
}

/// Moyenne de bloc, à bornes et divisions entières.
///
/// **Pourquoi à la main plutôt que `Interpolation.average`.** Le paquet `image`
/// sait déjà moyenner, et rend le même résultat — mais il lit chaque pixel
/// source par un accesseur qui recalcule son adresse. Sur une photo de
/// 3072 × 4080, les trois mesurés en alternance pour annuler la dérive de la
/// machine, `findCard` coûte **26 ms** en interpolant — le calcul faux —, **173 ms** avec
/// `Interpolation.average`, et **53 ms** en lisant directement le tampon
/// d'octets. Le calcul est le même que celui du paquet ; seul le chemin d'accès
/// change, et il vaut un facteur trois.
///
/// La correction double donc le coût de la détection sur une photo pleine
/// résolution. C'est le prix juste : c'est là, et là seulement, que le facteur
/// de réduction est assez grand pour que l'interpolation mente.
///
/// **Et à bornes entières, comme `art_hash.dart`.** Ce n'est pas une commodité :
/// c'est ce qui rend la réduction reproductible mot pour mot en Python, où
/// `np.add.reduceat` découpe exactement sur les mêmes bornes. Deux filtres qui
/// ne différeraient que par l'arrondi de leurs bords rendraient des coins
/// différents, donc des empreintes incomparables — la panne silencieuse que
/// l'en-tête de ce module décrit.
///
/// Le repli sur `copyResize` couvre ce que le tampon ne permet pas de lire à
/// plat : une image en 16 bits, une palette, ou moins de trois canaux. Une photo
/// de téléphone décodée depuis un JPEG n'est jamais dans ce cas ; le repli
/// existe pour que le module reste juste hors de son terrain habituel, pas parce
/// qu'on l'y attend.
/// La même moyenne de bloc, mais lue dans un plan de luminance.
///
/// **Les bornes sont celles de [_boxReduce], au caractère près** : c'est la
/// seule chose qui garantit que les deux chemins rendent la même image
/// d'analyse, donc les mêmes coins. Toute divergence ici se paierait en
/// empreintes incomparables, sans qu'aucun test ne s'en aperçoive — la panne
/// silencieuse que l'en-tête de ce module décrit.
///
/// Les trois canaux reçoivent la même valeur, comme le fait `lumaImage` : c'est
/// ce qui rend `_cardMask` indifférent au chemin emprunté.
img.Image _boxReduceLuma(
  Uint8List luma, {
  required int width,
  required int height,
  required int rowStride,
  required int pixelStride,
  required int outWidth,
  required int outHeight,
}) {
  final dx = width / outWidth;
  final dy = height / outHeight;
  final out = img.Image(width: outWidth, height: outHeight);

  for (var y = 0; y < outHeight; y++) {
    final sy0 = (y * dy).toInt();
    final sy1 = y + 1 < outHeight ? ((y + 1) * dy).toInt() : height;

    for (var x = 0; x < outWidth; x++) {
      final sx0 = (x * dx).toInt();
      final sx1 = x + 1 < outWidth ? ((x + 1) * dx).toInt() : width;

      var total = 0;
      for (var sy = sy0; sy < sy1; sy++) {
        var i = sy * rowStride + sx0 * pixelStride;
        for (var sx = sx0; sx < sx1; sx++) {
          total += i < luma.length ? luma[i] : 0;
          i += pixelStride;
        }
      }
      final mean = total ~/ ((sy1 - sy0) * (sx1 - sx0));
      out.setPixelRgb(x, y, mean, mean, mean);
    }
  }
  return out;
}

img.Image _boxReduce(img.Image photo, int width, int height) {
  final data = photo.data;
  if (data is! img.ImageDataUint8 || photo.hasPalette || data.numChannels < 3) {
    return img.copyResize(
      photo,
      width: width,
      height: height,
      interpolation: img.Interpolation.average,
    );
  }

  final bytes = data.toUint8List();
  final channels = data.numChannels;
  final stride = data.rowStride;
  final dx = photo.width / width;
  final dy = photo.height / height;

  // **Le bloc s'arrête où commence le suivant, et le dernier va jusqu'au bord.**
  // Écrire la borne haute `((y + 1) * dy).toInt()` reviendrait au même partout
  // sauf sur le dernier bloc, où `height * dy` peut valoir 4079,999… au lieu de
  // 4080 : le dernier rang de pixels serait alors ignoré côté Dart et pris côté
  // Python. Un rang sur quatre mille ne change pas un masque, mais il suffit à
  // décaler un coin — et un décalage de parité ne se voit pas.
  final out = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    final sy0 = (y * dy).toInt();
    final sy1 = y + 1 < height ? ((y + 1) * dy).toInt() : photo.height;

    for (var x = 0; x < width; x++) {
      final sx0 = (x * dx).toInt();
      final sx1 = x + 1 < width ? ((x + 1) * dx).toInt() : photo.width;

      var r = 0, g = 0, b = 0;
      for (var sy = sy0; sy < sy1; sy++) {
        var i = sy * stride + sx0 * channels;
        for (var sx = sx0; sx < sx1; sx++) {
          r += bytes[i];
          g += bytes[i + 1];
          b += bytes[i + 2];
          i += channels;
        }
      }
      final n = (sy1 - sy0) * (sx1 - sx0);
      out.setPixelRgb(x, y, r ~/ n, g ~/ n, b ~/ n);
    }
  }
  return out;
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
/// **Le rapport attendu vient du jeu**, et non d'une constante du module : les
/// deux jeux couverts impriment en 63 × 88 mm, le suivant n'imprimera pas au
/// même format. Voir `card_geometry.dart`.
///
/// **[sideways] est une seconde orientation, et elle n'a rien à voir avec la
/// première.** Celle du jeu vient de l'*impression* — un champ de bataille
/// Riftbound est imprimé en travers. Celle-ci vient du *capteur* : une caméra
/// livre son buffer en paysage quel que soit le sens du téléphone, et l'écran
/// de scan étant verrouillé en portrait, toute carte debout y apparaît couchée.
/// Les confondre a coûté cher : le flux ne détectait **rien** sur les quatre
/// jeux qui n'impriment aucune carte en travers — Magic, Yu-Gi-Oh, Pokémon,
/// One Piece —, et fonctionnait par accident sur les quatre autres, dont un
/// cadre couché ouvrait la porte. Mesuré sur l'appareil : 978 images d'une
/// carte immobile et nette, zéro détection.
///
/// **Le drapeau ne se déduit pas de l'image.** Une image plus large que haute
/// ne dit pas que le capteur a tourné ; c'est la source qui le sait, et elle
/// seule le déclare. Le mode photo reçoit une image déjà redressée et laisse
/// donc [sideways] à faux — sans quoi il perdrait le garde-fou ci-dessus sans
/// rien gagner.
///
/// **[sideways] bascule l'orientation attendue, il ne l'ajoute pas**, et cette
/// nuance a coûté une passe entière. Une première version acceptait les deux :
/// la surface d'acceptation doublait, et le flux annonçait des cartes sur un
/// parquet — dont les lames ont exactement le format d'une carte couchée. Or le
/// redressement du capteur est *connu* : si l'image est tournée d'un quart de
/// tour, une carte debout y est **forcément** couchée, et l'aspect droit n'y
/// désigne plus rien de réel. L'accepter quand même, c'était rouvrir le mode de
/// défaillance que tout ce contrôle existe pour fermer.
///
/// Les deux orientations restent acceptées pour les seuls jeux qui impriment en
/// travers : chez eux, la carte couchée du jeu et la carte debout tournée par
/// le capteur se présentent bien sous les deux formats.
bool _hasCardAspect(double aspect, String game, {bool sideways = false}) {
  final debout = cardAspectFor(game);
  final couche = 1 / debout;
  // Ce qu'une carte *debout* présente dans cette image-ci.
  final attendu = sideways ? couche : debout;
  if ((aspect - attendu).abs() <= aspectTolerance) return true;

  // Et ce qu'y présente une carte imprimée en travers — si le jeu en a.
  final aussi = sideways ? debout : couche;
  final jeuCouche = CardFrame.values.any((f) => f.game == game && f.landscape);
  return jeuCouche && (aspect - aussi).abs() <= aspectTolerance;
}

/// Ce que la détection voit, avant qu'elle ne conclue.
///
/// **Exposé au seul usage du diagnostic.** Quand `findCard` rend un
/// quadrilatère faux, aucun chiffre ne dit pourquoi : c'est le masque qu'il
/// faut voir. `tool/probe_photo.dart` l'écrit en image, et l'erreur saute alors
/// aux yeux — une ombre qui relie la carte au bord, un fond pris pour du carton.
/// Rien dans l'application n'appelle cette fonction.
({Uint8List mask, Uint8List? shape, double fill, int width, int height})
debugDetection(img.Image image) {
  final (:small, scale: _) = _analysisImage(image);

  final mask = _cardMask(small);
  _fillHoles(mask, small.width, small.height);
  final shape = _largestComponent(mask, small.width, small.height);

  var fill = 0.0;
  if (shape != null) {
    var area = 0;
    var minX = small.width, maxX = -1, minY = small.height, maxY = -1;
    for (var i = 0; i < shape.length; i++) {
      if (shape[i] == 0) continue;
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
Uint8List _cardMask(img.Image image) {
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

  // **Un octet par pixel, non un booléen.** Une `List<bool>` de Dart est un
  // tableau de pointeurs vers les deux objets canoniques `true` et `false` :
  // huit octets par pixel, un déréférencement par accès, et de la pression sur
  // le ramasse-miettes. Tous les autres tampons de ce module — `seen`, `stack`,
  // `members` — sont typés depuis toujours ; le masque, qui est pourtant le plus
  // parcouru, ne l'était pas. Voir [findCard] pour ce que cela coûtait.
  final mask = Uint8List(count);
  for (var i = 0; i < count; i++) {
    final table = litShare[i] > 0 ? litMean[i] / litShare[i] : mean[i];
    if (greys[i] < table * cardCeiling) mask[i] = 1;
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
void _fillHoles(Uint8List mask, int width, int height) {
  final outside = Uint8List(width * height);
  final stack = Int32List(width * height);
  var top = 0;

  void push(int index) {
    if (mask[index] != 0 || outside[index] != 0) return;
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
    if (outside[i] == 0) mask[i] = 1;
  }
}

/// La plus grande forme d'un seul tenant.
///
/// Sur une photo d'une seule carte, c'est elle. Les autres composantes sont des
/// ombres, des reflets, un bout de manche — toutes plus petites, et aucune ne
/// peut fusionner avec la carte puisqu'il n'y a pas de voisine à toucher.
Uint8List? _largestComponent(Uint8List mask, int width, int height) {
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
  Uint8List? best;
  var bestSize = 0;

  for (var start = 0; start < mask.length; start++) {
    if (mask[start] == 0 || seen[start] != 0) continue;

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
        if (mask[next] != 0 && seen[next] == 0) {
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
      final shape = Uint8List(mask.length);
      for (var i = 0; i < size; i++) {
        shape[members[i]] = 1;
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
CardQuad? _cornersOf(Uint8List shape, int width, int height) {
  var minSum = 1 << 30, maxSum = -(1 << 30);
  var minDiff = 1 << 30, maxDiff = -(1 << 30);
  Point? topLeft, bottomRight, topRight, bottomLeft;

  for (var index = 0; index < shape.length; index++) {
    if (shape[index] == 0) continue;
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

/// La même lecture, mais dans un plan de luminance, et rendue à plat.
///
/// **Le dernier `img.Image` du flux libre.** [sampleArt] lit dans une image ;
/// pour une image de caméra, il faut donc la bâtir d'abord — c'est ce que
/// [findCardInLuma] venait d'éviter, et que le hachage réintroduisait aussitôt.
/// Cette variante lit les octets là où ils sont et écrit un tampon serré, que
/// `artHashFromLuma` sait hacher sans rien reconstruire : `rowStride` y vaut la
/// largeur et `pixelStride` vaut un.
///
/// **Elle ne change pas le calcul.** Mêmes coordonnées `(u, v)`, même
/// interpolation des quatre coins, même interpolation bilinéaire des quatre
/// pixels voisins. Un test vérifie l'égalité **bit à bit** de l'empreinte
/// obtenue par les deux chemins ; s'il tombe, c'est celle-ci qui a tort.
///
/// Les trois canaux d'une image grise valant `Y`, l'interpolation rend `Y` :
/// c'est ce qui autorise à n'en porter qu'un.
Uint8List sampleArtFromLuma(
  Uint8List luma, {
  required int width,
  required int height,
  required int rowStride,
  int pixelStride = 1,
  required CardQuad quad,
  required ArtBox box,
  int outWidth = 256,
  int outHeight = 190,
}) {
  final out = Uint8List(outWidth * outHeight);

  for (var row = 0; row < outHeight; row++) {
    final v = box.top + (box.bottom - box.top) * (row + 0.5) / outHeight;
    for (var col = 0; col < outWidth; col++) {
      final u = box.left + (box.right - box.left) * (col + 0.5) / outWidth;

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

      final cx = x.clamp(0.0, (width - 1).toDouble());
      final cy = y.clamp(0.0, (height - 1).toDouble());
      final x0 = cx.floor();
      final y0 = cy.floor();
      final x1 = x0 + 1 < width ? x0 + 1 : x0;
      final y1 = y0 + 1 < height ? y0 + 1 : y0;
      final fx = cx - x0;
      final fy = cy - y0;

      int at(int px, int py) {
        final offset = py * rowStride + px * pixelStride;
        return offset < luma.length ? luma[offset] : 0;
      }

      final top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx;
      final bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx;
      // `setPixelRgb` tronque la valeur flottante qu'on lui passe ; on tronque
      // donc aussi, sans quoi les deux chemins différeraient d'un niveau sur
      // les pixels à mi-chemin — assez pour faire basculer un bit d'empreinte.
      out[row * outWidth + col] = (top * (1 - fy) + bottom * fy).toInt();
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
