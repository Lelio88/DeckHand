/// Tests de la projection carte → photo.
///
/// Deux propriétés suffisent à la verrouiller : elle ne change rien à une carte
/// vue de face, et elle place le centre d'une carte vue en perspective là où la
/// géométrie le met — au croisement des diagonales, et non au milieu du
/// quadrilatère.
library;

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('les quatre coins de la carte tombent sur ceux du quadrilatère', () {
    const quad = CardQuad(
      topLeft: (x: 324, y: 167),
      topRight: (x: 2892, y: 212),
      bottomRight: (x: 2955, y: 3840),
      bottomLeft: (x: 196, y: 3840),
    );
    final p = CardProjection(quad);

    for (final (u, v, coin) in [
      (0.0, 0.0, quad.topLeft),
      (1.0, 0.0, quad.topRight),
      (1.0, 1.0, quad.bottomRight),
      (0.0, 1.0, quad.bottomLeft),
    ]) {
      final (:x, :y) = p.map(u, v);
      expect(x, closeTo(coin.x, 1e-6));
      expect(y, closeTo(coin.y, 1e-6));
    }
  });

  test('sur un parallélogramme, elle rejoint l\'interpolation des coins', () {
    // Une carte vue de face : aucune photo de ce genre ne doit changer de
    // lecture.
    const quad = CardQuad(
      topLeft: (x: 100, y: 50),
      topRight: (x: 400, y: 80),
      bottomRight: (x: 380, y: 500),
      bottomLeft: (x: 80, y: 470),
    );
    final p = CardProjection(quad);

    for (final (u, v) in [(0.2, 0.1), (0.5, 0.5), (0.9, 0.54)]) {
      final bx =
          (1 - u) * (1 - v) * 100 +
          u * (1 - v) * 400 +
          u * v * 380 +
          (1 - u) * v * 80;
      final by =
          (1 - u) * (1 - v) * 50 +
          u * (1 - v) * 80 +
          u * v * 500 +
          (1 - u) * v * 470;
      final (:x, :y) = p.map(u, v);
      expect(x, closeTo(bx, 1e-6));
      expect(y, closeTo(by, 1e-6));
    }
  });

  test(
    'en perspective, le centre du carton est au croisement des diagonales',
    () {
      // Un trapèze : haut plus étroit que le bas, comme une carte dont le haut
      // s'éloigne de l'objectif. La moitié éloignée paraît plus courte, et le
      // centre du carton remonte au-dessus du milieu du quadrilatère.
      const quad = CardQuad(
        topLeft: (x: 20, y: 0),
        topRight: (x: 80, y: 0),
        bottomRight: (x: 100, y: 100),
        bottomLeft: (x: 0, y: 100),
      );
      final (:x, :y) = CardProjection(quad).map(0.5, 0.5);

      // Diagonales : (20,0)→(100,100) et (80,0)→(0,100). Elles se croisent en
      // x = 50, y = 37,5.
      expect(x, closeTo(50, 1e-9));
      expect(y, closeTo(37.5, 1e-9));
      expect(y, lessThan(50), reason: 'l\'interpolation des coins disait 50');
    },
  );
}
