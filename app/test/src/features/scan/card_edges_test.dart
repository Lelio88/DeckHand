/// Ce que la détection par droites doit tenir (#8).
///
/// **Trois de ces tests fixent des pièges déjà tombés.** Le premier chantier a
/// cru réussir deux fois de suite alors que la forme retenue était l'image
/// entière — dont le rapport 3:4 ressemble à celui d'une carte. Le deuxième a
/// détouré le bloc de texte au lieu de la carte. Le troisième a rendu un
/// quadrilatère juste mais parcouru à l'envers, ce qui découpe en miroir.
library;

import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Une carte plausible : bordure sombre, illustration claire, bloc de texte.
///
/// Le bloc de texte est là exprès — c'est lui qui détournait la détection.
img.Image carte(int w, int h) {
  final c = img.Image(width: w, height: h);
  img.fill(c, color: img.ColorRgb8(20, 18, 16));
  img.fillRect(
    c,
    x1: (w * 0.08).round(),
    y1: (h * 0.08).round(),
    x2: (w * 0.92).round(),
    y2: (h * 0.55).round(),
    color: img.ColorRgb8(180, 150, 110),
  );
  img.fillRect(
    c,
    x1: (w * 0.08).round(),
    y1: (h * 0.60).round(),
    x2: (w * 0.92).round(),
    y2: (h * 0.90).round(),
    color: img.ColorRgb8(230, 228, 220),
  );
  return c;
}

img.Image surFond(img.Image c, int w, int h, {int x = -1, int y = -1}) {
  final photo = img.Image(width: w, height: h);
  img.fill(photo, color: img.ColorRgb8(120, 95, 70));
  img.compositeImage(
    photo,
    c,
    dstX: x < 0 ? (w - c.width) ~/ 2 : x,
    dstY: y < 0 ? (h - c.height) ~/ 2 : y,
  );
  return photo;
}

void main() {
  test('une carte posée sur une table est détourée à ses bords', () {
    final photo = surFond(carte(200, 279), 340, 460);

    final quad = findCardByEdges(photo);

    expect(quad, isNotNull);
    expect(quad!.topLeft.x, closeTo(70, 8));
    expect(quad.topLeft.y, closeTo(90, 8));
    expect(quad.bottomRight.x, closeTo(270, 8));
    expect(quad.bottomRight.y, closeTo(369, 8));
  });

  test('le bloc de texte de la carte ne passe pas pour la carte', () {
    // Le cadre intérieur a des bords plus francs que le contour ; c'est bien
    // le contour qu'il faut, et l'aire est ce qui les départage.
    final photo = surFond(carte(200, 279), 340, 460);

    final quad = findCardByEdges(photo)!;

    expect(quad.aspect, closeTo(0.716, 0.06));
    expect(quad.area, greaterThan(200 * 279 * 0.85));
  });

  test('les coins sont rendus dans l’ordre où l’on lit une carte', () {
    // Un quadrilatère juste mais parcouru à l'envers découpe l'illustration en
    // miroir, sans que rien ne le signale.
    final quad = findCardByEdges(surFond(carte(200, 279), 340, 460))!;

    expect(quad.topLeft.x, lessThan(quad.topRight.x));
    expect(quad.topLeft.y, lessThan(quad.bottomLeft.y));
    expect(quad.bottomRight.x, greaterThan(quad.bottomLeft.x));
  });

  test('un décor rayé ne fait pas une carte', () {
    // **Le cas mesuré sur photos réelles** : sur douze photos de décor sans
    // aucune carte, cinq en produisaient une, dont trois sur du parquet. Les
    // lames sont des droites parallèles franches, et quatre d'entre elles se
    // croisent en un rectangle plausible.
    //
    // Ce test a d'abord été écrit puis retiré, faute de critère pour le tenir :
    // un plan de travail rayé dessine réellement des rectangles. Ce qui le rend
    // tenable, c'est de regarder la **matière** de part et d'autre du bord —
    // sur un parquet, c'est le même bois des deux côtés.
    final fond = img.Image(width: 340, height: 460);
    img.fill(fond, color: img.ColorRgb8(120, 95, 70));
    for (var y = 40; y < 460; y += 70) {
      img.fillRect(
        fond,
        x1: 0,
        y1: y,
        x2: 339,
        y2: y + 3,
        color: img.ColorRgb8(60, 45, 30),
      );
    }

    expect(findCardByEdges(fond), isNull);
  });

  test('une texture sans carte ne rend rien', () {
    // **Le cas qui compte le plus** : ne jamais rendre une carte là où il n'y
    // en a pas. Un tapis, un drap, un parquet — des gradients partout, aucune
    // structure rectangulaire.
    //
    final fond = img.Image(width: 340, height: 460);
    var graine = 7;
    for (var y = 0; y < 460; y++) {
      for (var x = 0; x < 340; x++) {
        graine = (graine * 1103515245 + 12345) & 0x7fffffff;
        final n = 90 + (graine >> 16) % 60;
        fond.setPixelRgb(x, y, n, (n * 0.8).round(), (n * 0.6).round());
      }
    }

    expect(findCardByEdges(fond), isNull);
  });

  test('une image entière ne passe jamais pour une carte', () {
    // Le piège originel : une photo de téléphone est en 3:4, soit 0,753, à
    // 0,037 du rapport d'une carte — donc dans toutes les tolérances.
    final plein = img.Image(width: 300, height: 400);
    img.fill(plein, color: img.ColorRgb8(200, 200, 200));

    final quad = findCardByEdges(plein);

    expect(
      quad == null || quad.area < 300 * 400 * 0.93,
      isTrue,
      reason: 'le cadre entier ne doit pas être rendu comme une carte',
    );
  });

  test('un doigt sur un bord ne fait pas perdre la carte', () {
    // **Le cas du terrain** : la carte est tenue à la main, le pouce masque le
    // nom *et* le bord haut. Sans quatrième côté, la détection se rabattait sur
    // le pavé de texte — seul rectangle complet restant — et l'empreinte était
    // calculée dessus. Le rapport d'une carte étant connu, trois côtés suffisent
    // à placer le quatrième.
    final photo = surFond(carte(220, 307), 300, 400);
    // Le doigt : une tache claire qui recouvre le bord haut et mord sur le côté.
    img.fillRect(
      photo,
      x1: 30,
      y1: 0,
      x2: 150,
      y2: 60,
      color: img.ColorRgb8(235, 200, 185),
    );

    final quad = findCardByEdges(photo);

    expect(quad, isNotNull);
    expect(quad!.aspect, closeTo(0.716, 0.06));
    expect(
      quad.area,
      greaterThan(220 * 307 * 0.80),
      reason: 'la carte entière, pas la moitié restée visible',
    );
  });

  test('le chemin luminance trouve la même carte que le chemin image', () {
    // **Deux chemins, un seul résultat attendu.** Le flux caméra ne peut pas se
    // payer une image RGB — 10,4 ms mesurés sur l'appareil — et lit donc le plan
    // de luminance directement. Un raccourci plus rapide qui détourerait
    // ailleurs serait pire qu'inutile : il ferait diverger la photo et la vidéo
    // sans que rien ne le signale.
    //
    // La comparaison n'a de sens qu'à conditions égales : même largeur
    // d'analyse, et une image déjà grise, sinon c'est la couleur qu'on mesure.
    final photo = surFond(carte(200, 279), 340, 460);
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        final p = photo.getPixel(x, y);
        final l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
        photo.setPixelRgb(x, y, l, l, l);
      }
    }
    final luma = Uint8List(photo.width * photo.height);
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        luma[y * photo.width + x] = photo.getPixel(x, y).r.toInt();
      }
    }

    final parImage = findCardByEdges(photo, width: 240);
    final parLuma = findCardByEdgesInLuma(
      luma,
      width: photo.width,
      height: photo.height,
      rowStride: photo.width,
      analysisWidth: 240,
    );

    expect(parLuma, isNotNull);
    expect(parImage, isNotNull);
    expect(parLuma!.topLeft.x, closeTo(parImage!.topLeft.x, 2));
    expect(parLuma.topLeft.y, closeTo(parImage.topLeft.y, 2));
    expect(parLuma.bottomRight.x, closeTo(parImage.bottomRight.x, 2));
    expect(parLuma.bottomRight.y, closeTo(parImage.bottomRight.y, 2));
  });

  test('le flux n’accepte pas une carte couchée quand elle serait debout', () {
    // **La régression du matin, fixée par un test.** Accepter les deux
    // orientations double la surface d'acceptation : une carte s'était inventée
    // sur un parquet, dont les lames ont le format d'une carte couchée. Le mode
    // photo doit les accepter — il ignore comment le téléphone était tenu — mais
    // le flux connaît l'orientation de son capteur.
    final couchee = carte(279, 200);
    final photo = surFond(couchee, 460, 340);
    final luma = Uint8List(photo.width * photo.height);
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        final p = photo.getPixel(x, y);
        luma[y * photo.width + x] =
            (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
      }
    }

    final quad = findCardByEdgesInLuma(
      luma,
      width: photo.width,
      height: photo.height,
      rowStride: photo.width,
    );

    expect(
      quad,
      isNull,
      reason: 'Magic n’imprime pas en travers : une forme couchée n’est pas '
          'une carte quand on sait comment le capteur est tenu',
    );
    // La même image, vue par le mode photo, est acceptée : là, l'orientation
    // est une inconnue et non une erreur.
    expect(findCardByEdges(photo), isNotNull);
  });

  test('une carte qui déborde du cadre est détourée jusqu’aux bords', () {
    // Le cas du guide de visée : la carte remplit la hauteur, ses bords haut et
    // bas sont hors champ. On ne peut pas exiger de voir ce qui n'est pas là.
    final c = carte(240, 335);
    final photo = img.Image(width: 384, height: 335);
    img.fill(photo, color: img.ColorRgb8(120, 95, 70));
    img.compositeImage(photo, c, dstX: 72, dstY: 0);

    final quad = findCardByEdges(photo);

    expect(quad, isNotNull);
    expect(quad!.topLeft.x, closeTo(72, 10));
    expect(quad.topRight.x, closeTo(312, 10));
    expect(quad.bottomLeft.y, greaterThan(320));
  });
}
