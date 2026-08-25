/// La face d'une feuille de classeur en vol : neuf dos de cartes, ou neuf
/// pochettes vides.
///
/// **Un peintre, et non des widgets — c'est une mesure, pas un goût.** La
/// feuille qui tourne est découpée en dix lamelles, et chacune **reconstruit la
/// face entière** pour n'en garder qu'une tranche. Avec une `GridView` de neuf
/// cases, une image en plein feuilletage comptait **2 100 widgets** dont 1 688
/// pour les seules feuilles, et coûtait 33 ms quand le budget est de 16,7. Un
/// `CustomPaint` par lamelle rend la même image pour une poignée d'ordres de
/// dessin, que le rognage de la lamelle écarte pour la plupart avant même de
/// les exécuter : **530 widgets**, et le `pump` divisé par trois. Mesuré par
/// `test/bench_montre_test.dart`.
///
/// **Le vrai dos du jeu quand il existe, un motif dessiné sinon.** Ce qu'on
/// attend d'un classeur Magic, c'est le dos Magic ; d'un classeur Pokémon, le
/// dos Pokémon. [back] est cette image — pointée chez la source qui la publie,
/// jamais réhébergée (§IV.3, §IV.9) — et `card_back.dart` dit lesquels des huit
/// jeux en ont un et pourquoi les autres n'en ont pas.
///
/// **Le motif dessiné reste, comme repli.** Six jeux sur huit n'ont pas de dos
/// publié, et l'image peut ne pas être arrivée : dans les deux cas la feuille
/// doit quand même ressembler à une feuille de cartes. Ce motif-ci n'imite
/// personne — la face cachée d'une carte Magic est une œuvre de l'éditeur.
///
/// **Il doit se voir, et une première version ne se voyait pas.** Elle était
/// faite de traits gris à 45 % sur un carton gris : à l'arrêt on distinguait le
/// motif, à cent quatre-vingts millisecondes le tour il n'en restait rien, et le
/// feuilletage montrait neuf rectangles vides. Un dos de carte se lit à sa
/// **structure**, pas à ses détails : une tranche sombre qui borde, un panneau
/// plus clair au milieu, un médaillon qui accroche l'œil. Le filet reprend la
/// couleur d'accent du thème — c'est la seule teinte franche de la planche, et
/// la seule qui survive à la vitesse.
///
/// **Deux faces, un seul peintre.** Le recto d'une feuille montre le dos des
/// cartes ; son verso montre les **pochettes**, vides par nature — c'est ce
/// qu'on voit en tournant une page de classeur, le plastique et ses logements,
/// pas les cartes qui y sont glissées de l'autre côté. Les deux partagent la
/// page, sa marge et sa grille : les séparer en deux peintres aurait fait deux
/// géométries à garder d'accord.
///
/// **La grille se déduit de la taille reçue.** Rien n'est écrit en dur : neuf
/// cases dans ce qui reste de la page une fois la marge retirée. À la taille
/// nominale du calque (308 × 413, marge 14, gouttière 8), cela retombe
/// exactement sur les 88 × 123 d'une case de classeur — et si la planche change
/// de proportions, la face suit au lieu de déborder.
///
/// Exemple :
///
/// ```dart
/// SheetFace(
///   colors: Theme.of(context).colorScheme,
///   padding: RevealMetrics.pagePad,
///   gap: RevealMetrics.gap,
/// )
/// ```
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Une page de feuille, recto (dos de cartes) ou verso (pochettes).
class SheetFace extends StatelessWidget {
  const SheetFace({
    super.key,
    required this.colors,
    required this.padding,
    required this.gap,
    this.back,
    this.pockets = false,
  });

  final ColorScheme colors;

  /// Le vrai dos du jeu, ou `null` — voir `card_back.dart`.
  final ui.Image? back;

  /// Marge de la page autour de ses neuf cases.
  final double padding;

  /// Espace entre deux cases.
  final double gap;

  /// Vrai pour le verso : les pochettes vides, sans motif.
  final bool pockets;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: SheetFacePainter(
      colors: colors,
      padding: padding,
      gap: gap,
      back: back,
      pockets: pockets,
    ),
    // **La taille vient du parent.** La lamelle impose déjà celle de la page
    // entière ; un `size` par défaut ferait dessiner dans le vide le jour où
    // ce peintre servirait ailleurs.
    size: Size.infinite,
  );
}

/// Le dessin d'une face de feuille.
///
/// **Immuable et comparable** : `shouldRepaint` ne rend vrai que si l'un des
/// quatre paramètres a bougé. Les dix lamelles d'une feuille reçoivent la même
/// instance, et aucune ne repeint tant que le thème ne change pas.
@immutable
class SheetFacePainter extends CustomPainter {
  const SheetFacePainter({
    required this.colors,
    required this.padding,
    required this.gap,
    required this.pockets,
    this.back,
  });

  final ColorScheme colors;
  final double padding;
  final double gap;
  final bool pockets;

  /// Le vrai dos du jeu, ou `null` pour le motif dessiné.
  final ui.Image? back;

  /// Rayon des coins d'une case, en points.
  static const double _cellRadius = 8;

  /// Rayon des coins de la page.
  static const double _pageRadius = 10;

  /// Part de la case occupée par la tranche sombre qui la borde.
  ///
  /// C'est ce liseré qui fait lire « carte » plutôt que « case » : un dos de
  /// carte est toujours un panneau posé dans un cadre.
  static const double _borderShare = 0.085;

  /// Force du filet d'accent. Assez pour se voir en mouvement, assez peu pour
  /// que neuf cartes ne fassent pas un vitrail.
  static const double _accentAlpha = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    _paintPage(canvas, size);

    final inner = Rect.fromLTWH(
      padding,
      padding,
      size.width - 2 * padding,
      size.height - 2 * padding,
    );
    if (inner.width <= 0 || inner.height <= 0) return;

    final cellWidth = (inner.width - 2 * gap) / 3;
    final cellHeight = (inner.height - 2 * gap) / 3;
    if (cellWidth <= 0 || cellHeight <= 0) return;

    // **Les pinceaux sont montés une fois pour les neuf cases.** Chaque lamelle
    // rejoue `paint` en entier ; fabriquer un dégradé par case y coûtait deux
    // cent soixante-dix `createShader` par image, pour une différence qu'on ne
    // voit pas. Le dégradé court sur la page entière : les cases du haut sont
    // plus claires que celles du bas, ce qui suffit à les détacher.
    final tranche = Paint()..color = colors.surfaceContainerLow;
    final carton = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [colors.surfaceContainerHighest, colors.surfaceContainerHigh],
      ).createShader(inner);
    final creux = Paint()..color = colors.surfaceContainerLow;
    final filet = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = colors.primary.withValues(alpha: _accentAlpha);
    final bord = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.outlineVariant;
    final plastique = Paint()
      ..color = colors.surfaceContainerHighest.withValues(alpha: 0.5);
    final encoche = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.outline.withValues(alpha: 0.4);
    final dos = back;
    final photo = Paint()..filterQuality = FilterQuality.medium;

    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        final cell = Rect.fromLTWH(
          inner.left + col * (cellWidth + gap),
          inner.top + row * (cellHeight + gap),
          cellWidth,
          cellHeight,
        );
        if (pockets) {
          _paintPocket(canvas, cell, plastique, bord, encoche);
        } else if (dos != null) {
          _paintDos(canvas, cell, dos, photo);
        } else {
          _paintCardBack(canvas, cell, tranche, carton, creux, filet);
        }
      }
    }
  }

  /// La feuille elle-même. Opaque : sans fond plein, on verrait par
  /// transparence la page du dessous pendant le retournement.
  void _paintPage(Canvas canvas, Size size) {
    final page = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(_pageRadius),
    );
    canvas.drawRRect(page, Paint()..color = colors.surface);
    canvas.drawRRect(
      page.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.outlineVariant,
    );
  }

  /// Le vrai dos du jeu, posé dans la case.
  ///
  /// **Recadré, jamais étiré.** Le dos Magic fait 0,7157 de rapport, celui de
  /// Yu-Gi-Oh 0,6971, la case 0,7154 : un `drawImageRect` naïf écraserait le
  /// second de deux et demi pour cent. On prend donc dans l'image le plus grand
  /// rectangle centré au rapport de la case.
  ///
  /// **Et rogné aux coins.** La case est arrondie ; sans cela, quatre coins
  /// carrés dépasseraient de la pochette.
  void _paintDos(Canvas canvas, Rect cell, ui.Image image, Paint photo) {
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(cell, const Radius.circular(_cellRadius)),
    );
    canvas.drawImageRect(image, _couvre(image, cell), cell, photo);
    canvas.restore();
  }

  /// Le plus grand rectangle centré de l'image qui ait le rapport de [dst].
  Rect _couvre(ui.Image image, Rect dst) {
    final l = image.width.toDouble();
    final h = image.height.toDouble();
    final rapport = dst.width / dst.height;
    var w = l;
    var t = l / rapport;
    if (t > h) {
      t = h;
      w = h * rapport;
    }
    return Rect.fromCenter(center: Offset(l / 2, h / 2), width: w, height: t);
  }

  /// Le dos d'une carte : une tranche sombre, un panneau, un médaillon.
  ///
  /// **Trois masses avant tout détail.** C'est le contraste entre la tranche et
  /// le panneau qui dit « carte » de loin ; le médaillon et son losange ne font
  /// que donner un centre au regard. Un dos entièrement fait de traits fins,
  /// lui, disparaît dès que la feuille bouge — c'était le défaut de la première
  /// version.
  void _paintCardBack(
    Canvas canvas,
    Rect cell,
    Paint tranche,
    Paint carton,
    Paint creux,
    Paint filet,
  ) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(cell, const Radius.circular(_cellRadius)),
      tranche,
    );

    final panneau = cell.deflate(cell.shortestSide * _borderShare);
    final panneauBox = RRect.fromRectAndRadius(
      panneau,
      const Radius.circular(_cellRadius * 0.55),
    );
    canvas.drawRRect(panneauBox, carton);
    canvas.drawRRect(panneauBox.deflate(0.6), filet);

    // Le médaillon : un disque creusé, cerclé, avec son losange.
    final cote = panneau.shortestSide * 0.52;
    final medaillon = Rect.fromCenter(
      center: cell.center,
      width: cote,
      height: cote,
    );
    canvas.drawOval(medaillon, creux);
    canvas.drawOval(medaillon, filet);
    canvas.drawPath(_losange(medaillon.deflate(cote * 0.24)), filet);

    // Deux barres, au-dessus et au-dessous : ce qui reste d'un dos de carte
    // quand on le regarde une fraction de seconde.
    final barre = panneau.width * 0.42;
    for (final y in [
      panneau.top + panneau.height * 0.13,
      panneau.bottom - panneau.height * 0.13,
    ]) {
      canvas.drawLine(
        Offset(cell.center.dx - barre / 2, y),
        Offset(cell.center.dx + barre / 2, y),
        filet,
      );
    }
  }

  /// Une pochette vide : le plastique, son logement, et l'échancrure par
  /// laquelle le pouce sort la carte.
  void _paintPocket(
    Canvas canvas,
    Rect cell,
    Paint plastique,
    Paint bord,
    Paint encoche,
  ) {
    final box = RRect.fromRectAndRadius(
      cell,
      const Radius.circular(_cellRadius),
    );
    canvas.drawRRect(box, plastique);
    canvas.drawRRect(box.deflate(0.5), bord);
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(cell.center.dx, cell.top),
        width: cell.width * 0.42,
        height: cell.height * 0.14,
      ),
      0,
      math.pi,
      false,
      encoche,
    );
  }

  Path _losange(Rect box) => Path()
    ..moveTo(box.center.dx, box.top)
    ..lineTo(box.right, box.center.dy)
    ..lineTo(box.center.dx, box.bottom)
    ..lineTo(box.left, box.center.dy)
    ..close();

  @override
  bool shouldRepaint(SheetFacePainter old) =>
      old.colors != colors ||
      old.padding != padding ||
      old.gap != gap ||
      old.pockets != pockets ||
      old.back != back;
}
