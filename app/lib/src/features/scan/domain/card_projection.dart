/// Où tombe, dans la photo, un point de la carte donné en proportions `(u, v)`.
///
/// **Une homographie, et non l'interpolation des quatre coins.** Une carte
/// photographiée de biais n'est pas un quadrilatère quelconque : c'est un
/// rectangle vu en perspective, et la moitié éloignée y paraît plus courte que
/// la moitié proche. Interpoler les coins linéairement place le milieu du carton
/// au milieu du quadrilatère, donc trop près du bord proche. Sur une carte
/// chinoise de Prophecy prise en trapèze — haut 7 % plus étroit que le bas —,
/// le bas de l'illustration était lu à 0,514 au lieu de 0,531 : assez pour que
/// l'empreinte tombe à 18 bits de la bonne carte, rang 29 dans l'index. Lue par
/// homographie, elle tombe à 10 bits, en tête.
///
/// **Mesuré sur le banc de photos réelles** (`.deckhand-bench`, 42 photos dont
/// la carte est connue et détourée) : la bonne carte arrive en tête 13 fois au
/// lieu de 10, et sa distance s'améliore sur 17 photos contre 8 où elle se
/// dégrade.
///
/// **Invariant** : sur un parallélogramme — un rectangle vu de face —, la
/// lecture est l'interpolation des coins **au bit près**, et non seulement
/// en droit. L'homographie s'y réduit mathématiquement, mais pas l'arrondi :
/// sur un motif régulier, un pixel lu à 301,999 999 au lieu de 302 fait
/// basculer des bits d'empreinte. Seules les photos en perspective changent
/// donc de lecture.
///
/// ```dart
/// final projection = CardProjection(quad);
/// final (:x, :y) = projection.map(0.5, 0.5); // le centre du carton
/// ```
library;

import 'card_bounds.dart';

/// La transformation projective du carré unité vers un [CardQuad].
///
/// Les huit coefficients sont calculés une fois ; `map` est ensuite appelée
/// pour chaque pixel lu, d'où la classe plutôt qu'une fonction.
class CardProjection {
  factory CardProjection(CardQuad quad) {
    final x0 = quad.topLeft.x, y0 = quad.topLeft.y;
    final x1 = quad.topRight.x, y1 = quad.topRight.y;
    final x2 = quad.bottomRight.x, y2 = quad.bottomRight.y;
    final x3 = quad.bottomLeft.x, y3 = quad.bottomLeft.y;

    // Heckbert, « Fundamentals of Texture Mapping », §2.2.3 : le carré unité
    // (0,0) (1,0) (1,1) (0,1) vers les quatre coins, dans cet ordre.
    final sx = x0 - x1 + x2 - x3;
    final sy = y0 - y1 + y2 - y3;
    final dx1 = x1 - x2, dx2 = x3 - x2;
    final dy1 = y1 - y2, dy2 = y3 - y2;
    final den = dx1 * dy2 - dx2 * dy1;

    // Un dénominateur nul désigne un quadrilatère dégénéré — trois coins
    // alignés. Aucune détection n'en rend, mais la lecture ne doit pas pour
    // autant diviser par zéro : on retombe sur la transformation affine.
    final g = den.abs() < 1e-9 ? 0.0 : (sx * dy2 - dx2 * sy) / den;
    final h = den.abs() < 1e-9 ? 0.0 : (dx1 * sy - sx * dy1) / den;

    return CardProjection._(
      quad,
      sx == 0 && sy == 0,
      x1 - x0 + g * x1,
      x3 - x0 + h * x3,
      x0,
      y1 - y0 + g * y1,
      y3 - y0 + h * y3,
      y0,
      g,
      h,
    );
  }

  const CardProjection._(
    this._quad,
    this._parallelogramme,
    this._a,
    this._b,
    this._c,
    this._d,
    this._e,
    this._f,
    this._g,
    this._h,
  );

  final CardQuad _quad;
  final bool _parallelogramme;
  final double _a, _b, _c, _d, _e, _f, _g, _h;

  /// Le point de la photo qui porte le point `(u, v)` de la carte.
  ({double x, double y}) map(double u, double v) {
    if (_parallelogramme) {
      final q = _quad;
      return (
        x:
            (1 - u) * (1 - v) * q.topLeft.x +
            u * (1 - v) * q.topRight.x +
            u * v * q.bottomRight.x +
            (1 - u) * v * q.bottomLeft.x,
        y:
            (1 - u) * (1 - v) * q.topLeft.y +
            u * (1 - v) * q.topRight.y +
            u * v * q.bottomRight.y +
            (1 - u) * v * q.bottomLeft.y,
      );
    }
    final w = _g * u + _h * v + 1;
    return (x: (_a * u + _b * v + _c) / w, y: (_d * u + _e * v + _f) / w);
  }
}
