/// Le retournement d'une feuille de classeur.
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
/// **Le volume vient de la lumière, pas de la géométrie.** Une tentative de
/// courbure par découpage en lamelles verticales a été faite et retirée : les
/// tranches, pivotées chacune autour de son propre bord, se croisaient au lieu
/// de rester jointes, et les cartes apparaissaient coupées en morceaux pendant
/// le geste. Un pliage juste demande de composer les transformations de proche
/// en proche et de le régler à l'œil sur l'appareil ; une feuille franchement
/// plane, correctement éclairée et correctement ombrée, vaut mieux qu'une
/// courbure approximative qui déchire ce qu'elle montre.
///
/// Restent donc trois choses qui donnent le relief, et qui ne peuvent rien
/// casser : un **reflet** qui balaie la feuille au rythme de sa rotation, une
/// **ombre portée** sur la page qu'elle découvre, et une **arête sombre** le
/// long de la reliure, là où une page réelle s'incurve toujours.
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
                  _TurningLeaf(
                    t: t,
                    forward: _direction > 0,
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

/// La feuille en mouvement : son recto jusqu'à la tranche, son dos ensuite.
class _TurningLeaf extends StatelessWidget {
  const _TurningLeaf({
    required this.t,
    required this.forward,
    required this.front,
    required this.back,
  });

  final double t;
  final bool forward;
  final Widget front;
  final Widget back;

  @override
  Widget build(BuildContext context) {
    final angle = t * math.pi;
    final showsBack = angle > math.pi / 2;
    final hinge = forward ? Alignment.centerLeft : Alignment.centerRight;
    // **La feuille se soulève vers nous, elle ne s'enfonce pas.** Les deux sens
    // partaient en arrière : le bord libre s'éloignait de l'œil au lieu de
    // passer devant, ce qui donnait l'impression de pousser la page dans le
    // classeur plutôt que de la tourner. Le défaut se remarquait surtout en
    // revenant en arrière, où le geste et le mouvement se contredisaient, mais
    // il valait pour les deux — c'est le signe de la rotation qui était inversé,
    // le `z` de la perspective devenant positif là où il devait être négatif.
    final signed = forward ? angle : -angle;
    // Le relief culmine quand la feuille est dressée, et s'efface à plat.
    final relief = math.sin(angle);

    final face = showsBack
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..rotateY(math.pi),
            child: back,
          )
        : front;

    return Transform(
      alignment: hinge,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0014)
        ..rotateY(signed),
      child: Stack(
        fit: StackFit.expand,
        children: [
          face,
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: forward ? Alignment.centerLeft : Alignment.centerRight,
                  end: forward ? Alignment.centerRight : Alignment.centerLeft,
                  colors: [
                    // L'arête sombre de la reliure : une page réelle s'y
                    // incurve toujours, et c'est ce pli qu'on reconnaît.
                    Colors.black.withValues(alpha: 0.42 * relief),
                    Colors.black.withValues(alpha: 0.06 * relief),
                    // Le reflet qui balaie la feuille : c'est lui qui suggère
                    // une surface qui se gauchit, là où l'ombre seule
                    // aplatirait tout.
                    Colors.white.withValues(alpha: 0.20 * relief),
                    Colors.black.withValues(alpha: 0.16 * relief),
                  ],
                  stops: const [0, 0.34, 0.72, 1],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
