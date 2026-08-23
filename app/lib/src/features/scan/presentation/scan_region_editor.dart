/// Régler à la main l'endroit où l'on pose ses cartes (#8).
///
/// **Ce que l'utilisateur sait et que la machine ignore.** Il pose ses cartes
/// toujours au même endroit — sous une potence, au centre d'un tapis. Le
/// déclarer écarte d'un coup ce qu'aucun critère géométrique ne savait écarter :
/// mesuré, deux photos de décor sur douze produisaient encore un quadrilatère,
/// une boîte de boosters et une serviette imprimée. Ce sont de vrais rectangles
/// posés ; les distinguer d'une carte demanderait de regarder leur contenu,
/// alors qu'il suffit de ne plus les regarder du tout.
///
/// **Le repère du capteur n'est pas celui de l'écran.** La zone est mémorisée
/// dans le repère du capteur — celui où la détection travaille — mais se règle
/// dans celui de l'aperçu, redressé. Les deux conversions vivent ici, et nulle
/// part ailleurs : c'est le seul endroit où un doigt rencontre des pixels de
/// capteur.
///
/// Exemple :
/// ```dart
/// ScanRegionEditor(
///   region: _region,
///   quarterTurns: scanner.uprightTurns,
///   onChanged: (r) => setState(() => _region = r),
/// )
/// ```
library;

import 'package:flutter/material.dart';

import '../domain/card_geometry.dart';

/// Rayon, en pixels d'écran, où un doigt saisit un coin plutôt que le cadre.
const double _prise = 44;

class ScanRegionEditor extends StatelessWidget {
  const ScanRegionEditor({
    super.key,
    required this.region,
    required this.quarterTurns,
    required this.onChanged,
  });

  final ScanRegion region;
  final int quarterTurns;
  final ValueChanged<ScanRegion> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, contraintes) {
        final taille = Size(contraintes.maxWidth, contraintes.maxHeight);
        final vue = _versEcran(region);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _debut = _saisir(details.localPosition, vue, taille),
          onPanUpdate: (details) => _glisser(details, vue, taille),
          child: CustomPaint(
            painter: _RegionPainter(vue),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  /// Ce que le doigt a saisi au début du glissement.
  static _Prise _debut = _Prise.cadre;

  _Prise _saisir(Offset p, Rect vue, Size taille) {
    final r = Rect.fromLTRB(
      vue.left * taille.width,
      vue.top * taille.height,
      vue.right * taille.width,
      vue.bottom * taille.height,
    );
    // Les coins d'abord : à l'intérieur d'un petit rectangle, ils tombent tous
    // sous le doigt, et déplacer serait alors impossible à obtenir.
    if ((p - r.topLeft).distance < _prise) return _Prise.hautGauche;
    if ((p - r.topRight).distance < _prise) return _Prise.hautDroit;
    if ((p - r.bottomLeft).distance < _prise) return _Prise.basGauche;
    if ((p - r.bottomRight).distance < _prise) return _Prise.basDroit;
    return _Prise.cadre;
  }

  void _glisser(DragUpdateDetails details, Rect vue, Size taille) {
    final dx = details.delta.dx / taille.width;
    final dy = details.delta.dy / taille.height;
    var l = vue.left, t = vue.top, r = vue.right, b = vue.bottom;
    switch (_debut) {
      case _Prise.cadre:
        // **Le cadre se déplace sans changer de taille.** Le décaler en butée
        // reviendrait à le rétrécir, et l'utilisateur perdrait le réglage qu'il
        // vient de faire en passant simplement trop loin.
        final dl = dx.clamp(-l, 1 - r);
        final dt = dy.clamp(-t, 1 - b);
        l += dl;
        r += dl;
        t += dt;
        b += dt;
      case _Prise.hautGauche:
        l = (l + dx).clamp(0.0, r - minRegionSide);
        t = (t + dy).clamp(0.0, b - minRegionSide);
      case _Prise.hautDroit:
        r = (r + dx).clamp(l + minRegionSide, 1.0);
        t = (t + dy).clamp(0.0, b - minRegionSide);
      case _Prise.basGauche:
        l = (l + dx).clamp(0.0, r - minRegionSide);
        b = (b + dy).clamp(t + minRegionSide, 1.0);
      case _Prise.basDroit:
        r = (r + dx).clamp(l + minRegionSide, 1.0);
        b = (b + dy).clamp(t + minRegionSide, 1.0);
    }
    onChanged(_versCapteur(Rect.fromLTRB(l, t, r, b)));
  }

  /// La zone, vue dans le repère de l'aperçu redressé.
  Rect _versEcran(ScanRegion z) {
    final coins = [
      _tourne(z.left, z.top),
      _tourne(z.right, z.bottom),
    ];
    return Rect.fromLTRB(
      coins.map((c) => c.dx).reduce((a, b) => a < b ? a : b),
      coins.map((c) => c.dy).reduce((a, b) => a < b ? a : b),
      coins.map((c) => c.dx).reduce((a, b) => a > b ? a : b),
      coins.map((c) => c.dy).reduce((a, b) => a > b ? a : b),
    );
  }

  /// Le chemin inverse : ce que le doigt a dessiné, dit au capteur.
  ScanRegion _versCapteur(Rect vue) {
    final coins = [
      _detourne(vue.left, vue.top),
      _detourne(vue.right, vue.bottom),
    ];
    final xs = coins.map((c) => c.dx).toList()..sort();
    final ys = coins.map((c) => c.dy).toList()..sort();
    return ScanRegion(left: xs.first, top: ys.first, right: xs.last, bottom: ys.last);
  }

  Offset _tourne(double x, double y) => switch (quarterTurns % 4) {
    1 => Offset(1 - y, x),
    2 => Offset(1 - x, 1 - y),
    3 => Offset(y, 1 - x),
    _ => Offset(x, y),
  };

  Offset _detourne(double x, double y) => switch (quarterTurns % 4) {
    1 => Offset(y, 1 - x),
    2 => Offset(1 - x, 1 - y),
    3 => Offset(1 - y, x),
    _ => Offset(x, y),
  };
}

enum _Prise { cadre, hautGauche, hautDroit, basGauche, basDroit }

class _RegionPainter extends CustomPainter {
  const _RegionPainter(this.vue);

  final Rect vue;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      vue.left * size.width,
      vue.top * size.height,
      vue.right * size.width,
      vue.bottom * size.height,
    );

    // **Assombrir le dehors plutôt que souligner le dedans.** Ce qui compte est
    // ce que l'appareil cesse de regarder ; le montrer en creux le dit mieux
    // qu'un trait de plus.
    canvas
      ..drawPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(Offset.zero & size),
          Path()..addRect(r),
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      )
      ..drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white,
      );

    final poignee = Paint()..color = Colors.white;
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(c, 7, poignee);
    }
  }

  @override
  bool shouldRepaint(_RegionPainter old) => old.vue != vue;
}
