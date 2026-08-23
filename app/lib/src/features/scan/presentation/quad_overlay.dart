/// Dessine, sur l'aperçu, le quadrilatère que la détection a retenu (#8).
///
/// **Pourquoi cela existe.** Un cadre faux ne se voit pas dans un compteur. Une
/// journée de mise au point du mode vidéo a coûté six captures d'écran de
/// diagnostic, dont cinq auraient été inutiles si ce tracé avait été là :
/// « l'empreinte tombe à 14 bits » ne dit pas si la fenêtre est prise sur la
/// carte, sur son bloc de texte ou sur le parquet à côté. Le tracé le dit d'un
/// coup d'œil, et il le dit aussi à l'utilisateur — qui comprend alors pourquoi
/// une carte n'est pas reconnue, et corrige son geste.
///
/// **Le repère du capteur n'est pas celui de l'écran.** Le buffer d'une caméra
/// Android arrive en paysage quel que soit le sens du téléphone, et l'écran de
/// scan est verrouillé en portrait : une carte posée droite y est couchée. Les
/// coins arrivent donc dans le repère du **capteur**, et c'est ici qu'on les
/// redresse — [quarterTurns] est le même nombre que celui dont la détection se
/// sert, `sensorOrientation ~/ 90`.
///
/// Exemple :
/// ```dart
/// CustomPaint(painter: QuadOverlay(corners: seen.corners, quarterTurns: 1))
/// ```
library;

import 'package:flutter/material.dart';

/// Trace le quadrilatère détecté, redressé pour l'aperçu.
class QuadOverlay extends CustomPainter {
  const QuadOverlay({required this.corners, required this.quarterTurns});

  /// Les quatre coins, en fractions de l'image du capteur.
  final List<({double x, double y})>? corners;

  /// Quarts de tour horaires qui redressent l'image du capteur.
  final int quarterTurns;

  @override
  void paint(Canvas canvas, Size size) {
    final coins = corners;
    if (coins == null || coins.length != 4) return;

    final chemin = Path();
    for (var i = 0; i < 4; i++) {
      final p = redresse(coins[i]);
      final point = Offset(p.x * size.width, p.y * size.height);
      i == 0 ? chemin.moveTo(point.dx, point.dy) : chemin.lineTo(point.dx, point.dy);
    }
    chemin.close();

    // Deux traits plutôt qu'un : le fin par-dessus le large donne un liseré
    // lisible sur une illustration claire comme sur un parquet sombre, sans
    // masquer la carte que l'on regarde.
    canvas
      ..drawPath(
        chemin,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = Colors.black.withValues(alpha: 0.45),
      )
      ..drawPath(
        chemin,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.greenAccent,
      );
  }

  /// Le même point, dans le repère de l'aperçu redressé.
  ///
  /// Publique pour être éprouvée directement : un test qui referait ce calcul
  /// de son côté ne vérifierait que sa propre copie.
  ({double x, double y}) redresse(({double x, double y}) p) =>
      switch (quarterTurns % 4) {
        1 => (x: 1 - p.y, y: p.x),
        2 => (x: 1 - p.x, y: 1 - p.y),
        3 => (x: p.y, y: 1 - p.x),
        _ => p,
      };

  @override
  bool shouldRepaint(QuadOverlay old) =>
      old.corners != corners || old.quarterTurns != quarterTurns;
}
