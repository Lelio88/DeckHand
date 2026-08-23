/// La zone limite ce qu'on lit, pas ce qu'on rend (#8).
///
/// **Ce que ces tests protègent.** Déclarer où l'on pose ses cartes écarte d'un
/// coup ce qu'aucun critère géométrique ne savait écarter — une boîte de
/// boosters, un tapis imprimé, de vrais rectangles posés à côté. Encore faut-il
/// que les coins rendus restent dans le repère de l'image entière : une
/// détection qui rendrait des coordonnées de zone ferait découper l'illustration
/// ailleurs, sans que rien ne le signale.
library;

import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

const int largeur = 900, hauteur = 700;

/// Un plan de luminance portant une carte sombre à l'endroit demandé.
Uint8List planAvecCarte({
  required int x,
  required int y,
  int w = 200,
  int h = 279,
}) {
  final luma = Uint8List(largeur * hauteur)..fillRange(0, largeur * hauteur, 190);
  for (var j = y; j < y + h; j++) {
    for (var i = x; i < x + w; i++) {
      // Un intérieur qui varie : une carte n'est pas un aplat, et un aplat ne
      // donnerait aucun bord intérieur à confondre avec le contour.
      luma[j * largeur + i] = 30 + ((i ~/ 12 + j ~/ 12) % 2) * 25;
    }
  }
  return luma;
}

CardQuad? chercher(Uint8List luma, {ScanRegion region = ScanRegion.whole}) =>
    findCardByEdgesInLuma(
      luma,
      width: largeur,
      height: hauteur,
      rowStride: largeur,
      region: region,
    );

void main() {
  test('une carte hors de la zone n’est pas vue', () {
    // La carte est à gauche, la zone regarde à droite : c'est tout l'objet du
    // réglage — ce qui n'est pas lu ne peut rien inventer.
    final luma = planAvecCarte(x: 40, y: 60);

    final dehors = chercher(
      luma,
      region: const ScanRegion(left: 0.55, top: 0.1, right: 0.98, bottom: 0.9),
    );

    expect(dehors, isNull);
  });

  test('une carte dans la zone est rendue dans le repère de l’image', () {
    // Le piège : rendre des coordonnées de zone ferait découper l'illustration
    // ailleurs, et rien ne le signalerait.
    final luma = planAvecCarte(x: 520, y: 200);

    final quad = chercher(
      luma,
      region: const ScanRegion(left: 0.5, top: 0.15, right: 0.99, bottom: 0.95),
    );

    expect(quad, isNotNull);
    expect(quad!.topLeft.x, greaterThan(largeur * 0.5));
    expect(quad.topLeft.x, closeTo(520, 30));
    expect(quad.topLeft.y, closeTo(200, 30));
  });

  test('une zone dégénérée retombe sur le champ entier', () {
    // Un rectangle glissé jusqu'à devenir un trait rendrait une image d'un
    // pixel de large, où tout est un bord et rien n'est une carte.
    const trait = ScanRegion(left: 0.4, top: 0.2, right: 0.42, bottom: 0.9);

    expect(trait.sane, ScanRegion.whole);
    expect(ScanRegion.whole.isWhole, isTrue);
  });

  test('la zone entière voit ce que voit une détection sans zone', () {
    final luma = planAvecCarte(x: 300, y: 200);

    final sansZone = chercher(luma);
    final zoneEntiere = chercher(luma, region: ScanRegion.whole);

    expect(sansZone != null, zoneEntiere != null);
    if (sansZone != null && zoneEntiere != null) {
      expect(zoneEntiere.topLeft.x, closeTo(sansZone.topLeft.x, 2));
      expect(zoneEntiere.topLeft.y, closeTo(sansZone.topLeft.y, 2));
    }
  });
}
