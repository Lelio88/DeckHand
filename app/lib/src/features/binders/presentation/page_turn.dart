/// Le retournement d'une feuille de classeur.
///
/// **Une feuille se courbe en se tournant, elle ne pivote pas d'un bloc.** La
/// première version faisait tourner un plan rigide autour de sa reliure : la
/// mécanique était juste, le résultat évoquait une carte à jouer qu'on retourne,
/// pas une page qu'on tourne. La différence tient entièrement à la courbure, et
/// c'est ce que ce fichier construit.
///
/// **La courbure est obtenue par bandes.** La feuille est découpée en huit
/// lamelles verticales dont l'angle croît de la reliure vers le bord libre : le
/// bord se soulève avant le milieu, comme une page qu'on pince. Une déformation
/// continue demanderait un maillage et un shader ; huit lamelles suffisent à ce
/// que l'œil lise une courbe, pour huit rectangles à peindre.
///
/// **Elle est nulle aux deux extrémités et maximale à mi-course** —
/// `sin(angle)` : une page est plate quand elle repose, et ne se plie que
/// pendant qu'on la soulève. Sans cette annulation, la feuille arriverait pliée
/// sur la pile, ce qui ne se voit dans aucun classeur.
///
/// **La reliure est à gauche**, comme un classeur à anneaux ouvert à plat.
/// Glisser vers la gauche avance ; vers la droite on revient, et l'axe passe au
/// bord droit — sans quoi la feuille pivoterait autour du mauvais côté et
/// sortirait de la reliure.
///
/// **Le dos d'une feuille est la page suivante, en miroir.** Une feuille porte
/// neuf cases de chaque côté ; retourner la page 3 fait apparaître la page 4 au
/// dos. Sans le miroir, la grille apparaîtrait à l'envers, première case à
/// droite.
///
/// Le geste pilote l'animation, il ne la déclenche pas : la feuille suit le
/// doigt, et l'on peut revenir en arrière en cours de route.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Part du geste au-delà de laquelle la feuille finit de se tourner.
const double _commitFraction = 0.33;

/// Vitesse au-delà de laquelle le geste l'emporte sur la distance, en px/s.
const double _flingVelocity = 600;

/// Lamelles verticales de la feuille.
///
/// Huit est le seuil où l'œil cesse de compter les facettes ; en dessous la
/// courbe se lit comme un pliage, au-dessus on paie des rectangles pour rien.
const int _stripes = 8;

/// Amplitude de la courbure, en radians, au sommet du mouvement.
///
/// Un demi-radian : à mi-course, le bord libre a près de trente degrés de plus
/// que la reliure. Au-delà, la feuille s'enroule comme un parchemin ; en deçà,
/// elle redevient le panneau rigide qu'on cherchait à quitter.
const double _curl = 0.5;

typedef PageBuilder = Widget Function(BuildContext context, int page);

/// Un classeur feuilletable.
class PageTurner extends StatefulWidget {
  const PageTurner({
    super.key,
    required this.page,
    required this.pageCount,
    required this.builder,
    required this.onTurned,
  });

  final int page;
  final int pageCount;
  final PageBuilder builder;

  /// Appelé quand une feuille a fini de se tourner, jamais pendant le geste :
  /// changer de page à mi-course rechargerait la feuille sous le doigt.
  final ValueChanged<int> onTurned;

  @override
  State<PageTurner> createState() => _PageTurnerState();
}

class _PageTurnerState extends State<PageTurner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );

  /// Sens du mouvement : `1` pour avancer, `-1` pour reculer, `0` au repos.
  int _direction = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canAdvance => widget.page < widget.pageCount;
  bool get _canGoBack => widget.page > 1;

  void _onDragUpdate(DragUpdateDetails details, double width) {
    if (width <= 0) return;
    final delta = -details.primaryDelta! / width;

    if (_direction == 0) {
      // Le sens se décide au premier mouvement et ne change plus : une feuille
      // qui hésiterait entre deux axes se plierait en deux.
      if (delta > 0 && _canAdvance) {
        _direction = 1;
      } else if (delta < 0 && _canGoBack) {
        _direction = -1;
      } else {
        return;
      }
    }

    _controller.value = (_controller.value + delta * _direction).clamp(0.0, 1.0);
  }

  Future<void> _onDragEnd(DragEndDetails details, double width) async {
    if (_direction == 0) return;

    final velocity = -details.primaryVelocity! * _direction;
    final commits =
        _controller.value > _commitFraction || velocity > _flingVelocity;

    if (commits) {
      // Une page lâchée finit son mouvement en accélérant puis en ralentissant,
      // comme une feuille qui retombe sous son propre poids.
      await _controller.animateTo(1, curve: Curves.easeOutCubic);
      final next = widget.page + _direction;
      _direction = 0;
      _controller.value = 0;
      widget.onTurned(next);
    } else {
      await _controller.animateBack(0, curve: Curves.easeOutCubic);
      _direction = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => _onDragUpdate(d, width),
          onHorizontalDragEnd: (d) => _onDragEnd(d, width),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              // Au repos, la feuille seule : ni transformation, ni lamelles, ni
              // couche superflue.
              if (_direction == 0 || t == 0) {
                return widget.builder(context, widget.page);
              }

              final under = widget.page + _direction;
              return Stack(
                fit: StackFit.expand,
                children: [
                  widget.builder(context, under),
                  // L'ombre que la feuille levée projette sur celle du dessous.
                  // C'est elle qui donne la profondeur : sans elle, les deux
                  // pages semblent peintes sur le même plan.
                  _CastShadow(t: t, forward: _direction > 0),
                  _CurlingLeaf(
                    t: t,
                    forward: _direction > 0,
                    width: width,
                    height: height,
                    front: widget.builder(context, widget.page),
                    back: widget.builder(context, under),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// L'ombre portée de la feuille sur celle qu'elle découvre.
class _CastShadow extends StatelessWidget {
  const _CastShadow({required this.t, required this.forward});

  final double t;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    // Maximale à mi-course, quand la feuille est dressée au-dessus de l'autre.
    final strength = math.sin(t * math.pi);

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: forward ? Alignment.centerLeft : Alignment.centerRight,
            end: forward ? Alignment.centerRight : Alignment.centerLeft,
            colors: [
              Colors.black.withValues(alpha: 0.45 * strength),
              Colors.black.withValues(alpha: 0.0),
            ],
            stops: const [0, 0.55],
          ),
        ),
      ),
    );
  }
}

/// La feuille en mouvement, découpée en lamelles pour se courber.
class _CurlingLeaf extends StatelessWidget {
  const _CurlingLeaf({
    required this.t,
    required this.forward,
    required this.width,
    required this.height,
    required this.front,
    required this.back,
  });

  final double t;
  final bool forward;
  final double width;
  final double height;
  final Widget front;
  final Widget back;

  @override
  Widget build(BuildContext context) {
    final angle = t * math.pi;
    final showsBack = angle > math.pi / 2;
    final curl = _curl * math.sin(angle);
    final stripeWidth = width / _stripes;

    final face = showsBack
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..rotateY(math.pi),
            child: back,
          )
        : front;

    // Les lamelles sont posées bout à bout : chacune part de l'extrémité de la
    // précédente, si bien que la feuille reste d'un seul tenant malgré les
    // angles qui divergent.
    var x = 0.0;
    var z = 0.0;
    final leaves = <Widget>[];

    for (var i = 0; i < _stripes; i++) {
      // La courbure croît vers le bord libre : le carré donne une inflexion
      // douce près de la reliure et marquée au bout, comme une page pincée.
      final along = (i + 0.5) / _stripes;
      final local = angle + curl * along * along;
      final signed = forward ? -local : local;

      leaves.add(
        Transform(
          alignment: Alignment.topLeft,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0014)
            ..translateByDouble(forward ? x : width - x - stripeWidth, 0, z, 1)
            ..rotateY(signed),
          child: _Stripe(
            index: i,
            width: stripeWidth,
            height: height,
            total: width,
            forward: forward,
            // La lumière rase le creux de la courbe : c'est ce qui fait lire un
            // volume là où huit facettes ne montreraient que des arêtes.
            shade: 0.32 * math.sin(angle) * along,
            child: face,
          ),
        ),
      );

      x += stripeWidth * math.cos(local - angle + (forward ? 0 : 0));
      z -= stripeWidth * math.sin(curl * along * along) * 0.6;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Stack(children: leaves),
      ],
    );
  }
}

/// Une lamelle : une tranche verticale de la feuille, assombrie selon sa place
/// dans la courbe.
class _Stripe extends StatelessWidget {
  const _Stripe({
    required this.index,
    required this.width,
    required this.height,
    required this.total,
    required this.forward,
    required this.shade,
    required this.child,
  });

  final int index;
  final double width;
  final double height;
  final double total;
  final bool forward;
  final double shade;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final offset = forward ? -index * width : -(total - (index + 1) * width);

    return SizedBox(
      width: width,
      height: height,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: total,
              maxWidth: total,
              minHeight: height,
              maxHeight: height,
              child: Transform.translate(
                offset: Offset(offset, 0),
                child: SizedBox(width: total, height: height, child: child),
              ),
            ),
            IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: shade.clamp(0.0, 1.0)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
