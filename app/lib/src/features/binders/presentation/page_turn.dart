/// Le retournement d'une feuille de classeur.
///
/// **Un vrai retournement, pas un fondu ni un glissement.** Ce qu'on reconnaît
/// d'un classeur qu'on feuillette, c'est la feuille qui pivote sur sa reliure :
/// elle se soulève, montre sa tranche, laisse voir la suivante par-dessous, puis
/// retombe de l'autre côté en présentant son dos. Un fondu enchaîné donnerait la
/// même information sans donner la même chose à voir.
///
/// **La reliure est à gauche**, comme sur un classeur à anneaux ouvert à plat.
/// Tourner vers la gauche avance ; vers la droite, on revient. L'axe de rotation
/// est donc le bord gauche pour avancer, le bord droit pour reculer — sans quoi
/// la feuille pivoterait autour du mauvais côté et sortirait de la reliure.
///
/// **La perspective est légère** (`setEntry(3, 2, 0.0012)`). Au-delà, la feuille
/// se déforme comme un panneau publicitaire ; en deçà, la rotation paraît plate
/// et le volume disparaît. C'est le seul réglage esthétique du fichier, et il se
/// voit tout de suite si on le change.
///
/// **Le dos d'une feuille est la page suivante, en miroir.** Une feuille de
/// classeur porte neuf cases de chaque côté ; retourner la page 3 fait apparaître
/// la page 4 au dos. Le miroir est indispensable : sans lui, le dos afficherait
/// la grille à l'envers, la première case à droite.
///
/// Le geste pilote l'animation, il ne la déclenche pas : la feuille suit le
/// doigt, et l'on peut revenir en arrière en cours de route. Une feuille lâchée
/// à mi-course termine son mouvement dans le sens où elle allait.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Part du geste au-delà de laquelle la feuille finit de se tourner.
///
/// À un tiers, un geste franc suffit et un frôlement ne tourne rien. Le seuil
/// est contourné par la vitesse : un mouvement rapide tourne la page même court,
/// comme un vrai coup de pouce sur un classeur.
const double _commitFraction = 0.33;

/// Vitesse au-delà de laquelle le geste l'emporte sur la distance, en pixels
/// par seconde.
const double _flingVelocity = 600;

typedef PageBuilder = Widget Function(BuildContext context, int page);

/// Un classeur feuilletable.
///
/// [page] est la feuille visible, [pageCount] le nombre total. [builder]
/// construit la face d'une feuille — il est appelé pour la feuille courante et
/// ses voisines, jamais pour les 97 autres.
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
    duration: const Duration(milliseconds: 420),
  );

  /// Sens du mouvement en cours : `1` pour avancer, `-1` pour reculer, `0` au
  /// repos.
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
      // Le sens se décide au premier mouvement, et ne change plus : une feuille
      // qui hésiterait entre deux axes de rotation se plierait en deux.
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
      await _controller.forward();
      final next = widget.page + _direction;
      _direction = 0;
      _controller.value = 0;
      widget.onTurned(next);
    } else {
      await _controller.reverse();
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
              // Au repos, la feuille courante seule : pas de transformation, pas
              // de couche superflue, et le défilement d'une page reste aussi
              // fluide qu'une grille ordinaire.
              if (_direction == 0 || t == 0) {
                return widget.builder(context, widget.page);
              }

              final under = widget.page + _direction;
              return Stack(
                fit: StackFit.expand,
                children: [
                  // La feuille du dessous est déjà là : c'est elle qu'on découvre
                  // à mesure que l'autre se soulève.
                  widget.builder(context, under),
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
    // En marche arrière, la feuille vient de la gauche et pivote sur le bord
    // droit : c'est la page précédente qui se rabat vers nous.
    final hinge = forward ? Alignment.centerLeft : Alignment.centerRight;
    final signed = forward ? -angle : angle;

    final face = showsBack
        // Le dos est vu depuis l'autre côté : sans ce miroir, la grille
        // apparaîtrait inversée, première case à droite.
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..rotateY(math.pi),
            child: back,
          )
        : front;

    return Transform(
      alignment: hinge,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..rotateY(signed),
      child: Stack(
        fit: StackFit.expand,
        children: [
          face,
          // L'ombre s'accentue jusqu'à la tranche puis s'efface : c'est elle qui
          // donne le relief, la rotation seule paraissant plate.
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: forward ? Alignment.centerLeft : Alignment.centerRight,
                  end: forward ? Alignment.centerRight : Alignment.centerLeft,
                  colors: [
                    Colors.black.withValues(alpha: 0.35 * math.sin(angle)),
                    Colors.black.withValues(alpha: 0.05 * math.sin(angle)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
