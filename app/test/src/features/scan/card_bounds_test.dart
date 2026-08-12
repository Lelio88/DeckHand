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

import 'dart:math' as math;

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

/// La même carte, mais sur une table **inégalement éclairée**.
///
/// Reproduit le défaut mesuré sur une vraie photo de bureau : la clarté du bois
/// tombe de 235 à 71 du haut vers le bas, puis se stabilise dans l'ombre du
/// dernier sixième. Un seuil calé sur la clarté médiane de toute l'image coupe
/// forcément quelque part dans cette pente — ici vers `y = 236`. Tout ce qui est
/// plus bas passe alors pour du carton, touche la carte, et la forme retenue
/// s'étend jusqu'au bord de l'image.
///
/// **Et le garde-fou d'aspect ne le voit pas passer** : la boîte englobante qui
/// en résulte a un rapport de 0,968, à 0,252 de celui d'une carte, quand la
/// tolérance en accepte 0,30. C'est bien au seuillage, et à lui seul, de ne pas
/// produire ce masque.
img.Image _photoEnPente() {
  final photo = img.Image(width: 300, height: 400);

  for (var y = 0; y < 400; y++) {
    // L'ombre s'assombrit jusqu'à `y = 340` puis reste plate : une pente qui
    // courrait jusqu'au bord ferait mentir le voisinage des dernières lignes,
    // dont la fenêtre est tronquée — un artefact de bord, pas le défaut qu'on
    // cherche à reproduire.
    final ombre = 1 - 0.70 * (y / 340).clamp(0.0, 1.0);
    photo.setPixelRgb(
      0,
      y,
      (235 * ombre).round(),
      (218 * ombre).round(),
      (192 * ombre).round(),
    );
    final teinte = photo.getPixel(0, y);
    for (var x = 1; x < 300; x++) {
      photo.setPixelRgb(x, y, teinte.r, teinte.g, teinte.b);
    }
  }
  for (var y = 0; y < 176; y++) {
    for (var x = 0; x < 126; x++) {
      photo.setPixelRgb(70 + x, 90 + y, 18, 16, 20);
    }
  }
  for (var y = 0; y < 74; y++) {
    for (var x = 0; x < 100; x++) {
      photo.setPixelRgb(80 + x, 111 + y, 200, 60, 40);
    }
  }
  return photo;
}

/// Une table nue et **grenue**, sans aucune carte.
///
/// Le grain vaut ±14 niveaux, comme celui du banc de cadrage — l'ordre de
/// grandeur d'un plateau de bois sous une photo compressée. La graine est fixée
/// pour que le test ne dépende pas du tirage.
img.Image _tableGrenue() {
  final rng = math.Random(7);
  final photo = img.Image(width: 300, height: 400);
  for (var y = 0; y < 400; y++) {
    for (var x = 0; x < 300; x++) {
      final grain = rng.nextInt(29) - 14;
      photo.setPixelRgb(
        x,
        y,
        (170 + grain).clamp(0, 255),
        (152 + grain).clamp(0, 255),
        (126 + grain).clamp(0, 255),
      );
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

  group('éclairage inégal', () {
    test('l\'ombre de la table ne s\'ajoute pas à la carte', () {
      // Le défaut d'origine : sur cette figure, un seuil calé sur l'image
      // entière rendait un quadrilatère de la taille de l'image. Une référence
      // prise dans le voisinage ramène les coins sur la carte, à un pixel près —
      // la marge tient au fait que l'ombre rapproche localement le coin de table
      // de la bordure.
      final quad = findCard(_photoEnPente());

      expect(quad, isNotNull);
      expect(quad!.topLeft.x, closeTo(70, 2));
      expect(quad.topLeft.y, closeTo(90, 2));
      expect(quad.bottomRight.x, closeTo(195, 2));
      expect(quad.bottomRight.y, closeTo(265, 2));
    });

    test('la forme retenue remplit sa boîte englobante', () {
      // **Le discriminant le plus parlant.** Une carte est un rectangle plein :
      // sa forme remplit sa boîte. Mesuré sur la photo qui a servi à corriger
      // ce module, une détection qui déborde sur le décor remplit 79 % de sa
      // boîte, une détection juste 96 %. Ce seul nombre sépare les deux cas là
      // où le rapport d'aspect échoue.
      expect(debugDetection(_photoEnPente()).fill, greaterThan(0.90));
    });
  });

  group('marge du plafond de carton', () {
    // **Ce que ces deux tests gardent, c'est une constante.** Le seuil de
    // carton est une fraction du niveau local de la table ; plus il monte, plus
    // il reconnaît de cartes — jusqu'à ce qu'il rattrape le grain du bois, qui
    // devient carton à son tour. Le banc de cadrage donne son sommet nominal à
    // 0,88, mais c'est là qu'il n'a plus de marge : mesuré sur cette figure, ce
    // plafond marque déjà 10 % d'une table nue, et 0,96 en marque 53 % puis rend
    // un quadrilatère de la taille de l'image. À 0,84, la même table ne marque
    // aucun pixel. Ces tests échouent dès qu'on remonte au-delà.

    test('une table grenue ne devient jamais du carton', () {
      final vu = debugDetection(_tableGrenue());
      final marques = vu.mask.where((on) => on).length;

      // Zéro pixel à 0,84 ; 10 % à 0,88. Le seuil de 1 % laisse la place au
      // hasard du tirage sans laisser passer un cran de plus.
      expect(marques / (vu.width * vu.height), lessThan(0.01));
    });

    test('une table grenue ne fait pas inventer une carte', () {
      // Le garde-fou d'aspect ne rattraperait rien : la forme qu'un plafond
      // trop haut retient est l'image entière, de rapport 0,735, à 0,019 d'une
      // carte. C'est au seuillage de ne pas la produire.
      expect(findCard(_tableGrenue()), isNull);
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
