/// Le retournement d'une feuille de classeur.
///
/// **Une feuille se courbe en se tournant.** Un plan rigide qui pivote évoque
/// une carte à jouer qu'on retourne, pas une page qu'on tourne : la différence
/// tient entièrement à la courbure, et à ce que le bord libre se soulève avant
/// le milieu.
///
/// **La courbure est un pliage, et le pliage doit se composer de proche en
/// proche.** C'est ce qui manquait à la première tentative : les lamelles
/// étaient posées côte à côte puis pivotées chacune autour de son propre bord de
/// l'angle *global*, si bien qu'elles se croisaient au lieu de rester jointes —
/// les cartes apparaissaient coupées en morceaux. Ici, le bord gauche de chaque
/// lamelle est **l'extrémité de la précédente** :
///
/// ```
/// x[i+1] = x[i] + w·cos(θ[i])
/// z[i+1] = z[i] − w·sin(θ[i])
/// ```
///
/// La feuille reste donc d'un seul tenant quels que soient les angles, et le `z`
/// négatif la fait passer **devant** l'œil plutôt que s'enfoncer dans le
/// classeur.
///
/// **Les trois réglages sont isolés ci-dessous** — [_stripes], [_curl],
/// [_curlProfile] — parce qu'ils ne se jugent qu'à l'œil, sur un appareil. Les
/// valeurs de départ sont expliquées, non devinées.
///
/// **Chaque lamelle décide seule de la face qu'elle montre.** Une page à
/// mi-retournement présente son recto d'un côté de la pliure et son verso de
/// l'autre : c'est ce qui distingue une feuille souple d'un panneau.
///
/// **Le verso montre le dos des pochettes, pas des cartes.** Il portait d'abord
/// la page suivante — celle-là même qui apparaît dessous —, si bien qu'on la
/// voyait deux fois et que la feuille semblait transparente : on croyait
/// regarder les cartes par-derrière. Dans un classeur, tourner une feuille
/// découvre le dos de ses pochettes ; ce qu'il y a dedans ne se voit que de
/// l'autre côté.
///
/// **La reliure est à gauche**, comme un classeur à anneaux ouvert à plat :
/// glisser vers la gauche avance, vers la droite on revient et tout est miroité.
///
/// Le geste pilote l'animation, il ne la déclenche pas : la feuille suit le
/// doigt, et l'on peut revenir en arrière en cours de route.
///
/// **En paysage, le classeur s'ouvre à plat.** [facingBuilder] ajoute une face
/// immobile à côté de celle qui tourne : c'est la double page d'un classeur
/// posé sur une table. La géométrie ne change pas d'un iota — la feuille pivote
/// toujours autour de son bord gauche —, mais ce bord tombe désormais au milieu
/// de l'écran, là où sont les anneaux. La feuille déborde sur la moitié voisine
/// en se rabattant, et c'est voulu : c'est ce qui fait qu'on la voit passer
/// par-dessus l'autre page plutôt que disparaître dans une trappe.
///
/// **Quelle face tourne dépend du sens.** En avant on rabat la page de droite
/// vers la gauche ; en arrière on relève celle de gauche vers la droite. Le
/// miroir qui sert déjà au retour échange les deux moitiés sans autre calcul :
/// il suffit d'échanger les deux constructeurs.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Part du geste au-delà de laquelle la feuille finit de se tourner.
const double _commitFraction = 0.33;

/// Vitesse au-delà de laquelle le geste l'emporte sur la distance, en px/s.
const double _flingVelocity = 600;

/// Lamelles verticales de la feuille — **premier réglage**.
///
/// Dix est le seuil où l'œil cesse de compter les facettes sur la largeur d'un
/// téléphone. En dessous, la courbe se lit comme un pliage d'origami ; au-dessus,
/// on paie des rectangles pour une différence qui ne se voit plus.
const int _stripes = 10;

/// Amplitude de la courbure au sommet du mouvement, en radians — **deuxième
/// réglage, le plus sensible**.
///
/// C'est l'écart d'angle entre la reliure et le bord libre quand la feuille est
/// dressée. À 0, la feuille redevient le panneau rigide qu'on cherche à quitter ;
/// au-delà d'un radian, elle s'enroule comme un parchemin et les cases du bord
/// deviennent illisibles.
const double _curl = 0.6;

/// Répartition de la courbure de la reliure vers le bord libre — **troisième
/// réglage**.
///
/// L'exposant d'une puissance : 1 répartit la flexion également et donne un
/// tuyau, 2 la concentre vers le bord libre comme une page qu'on pince, 3 la
/// concentre plus encore et ne plie presque que l'extrémité.
const double _curlProfile = 2;

/// Force de la perspective. Au-delà, la feuille se déforme comme un panneau
/// publicitaire ; en deçà, la rotation paraît plate.
const double _perspective = 0.0016;

typedef PageBuilder = Widget Function(BuildContext context, int page);

/// Où poser une lamelle, et de quel angle la pivoter.
class StripePlacement {
  const StripePlacement({
    required this.x,
    required this.z,
    required this.angle,
  });

  /// Décalage du bord gauche de la lamelle, dans le plan de l'écran.
  final double x;

  /// Profondeur du même bord. Négatif : vers l'œil.
  final double z;

  /// Rotation autour de l'axe vertical, en radians.
  final double angle;
}

/// Découpe la feuille en lamelles **jointes bout à bout**.
///
/// **Une lamelle commence exactement là où la précédente finit**, et c'est la
/// seule propriété qui compte : chacune est posée au bord gauche que la
/// précédente lui laisse, puis pivotée. Le bord droit se déduit alors du même
/// angle que la rotation — d'où la continuité, par construction.
///
/// Le premier essai employait **deux angles différents** : celui du milieu de
/// la lamelle pour la pivoter, celui de son bord droit pour avancer le curseur.
/// Les lamelles ne se rejoignaient donc pas tout à fait, et l'écart s'ouvrait
/// avec la courbure : de fines fentes verticales laissaient voir la page du
/// dessous à travers la feuille, alors même que celle-ci est opaque. On croyait
/// distinguer les cases les unes des autres ; on voyait passer le jour entre
/// deux facettes.
List<StripePlacement> stripePlacements({
  required double t,
  required double width,
  int stripes = _stripes,
  double curl = _curl,
  double curlProfile = _curlProfile,
}) {
  final base = t * math.pi;
  // La courbure naît et meurt avec le mouvement : une page est plate quand elle
  // repose, et n'a aucune raison d'arriver pliée sur la pile.
  final amplitude = curl * math.sin(base);
  final stripeWidth = width / stripes;

  final placements = <StripePlacement>[];
  var x = 0.0;
  var z = 0.0;

  for (var i = 0; i < stripes; i++) {
    // L'angle du segment, pris en son milieu : c'est ce qui approche le mieux
    // une courbe par une ligne brisée.
    final along = (i + 0.5) / stripes;
    final angle = base + amplitude * math.pow(along, curlProfile);
    placements.add(StripePlacement(x: x, z: z, angle: angle));

    x += stripeWidth * math.cos(angle);
    // Négatif : la feuille passe devant l'œil. Positif, elle s'enfoncerait dans
    // le classeur, ce qui donne l'impression de pousser la page.
    z -= stripeWidth * math.sin(angle);
  }

  return placements;
}

/// Un classeur feuilletable.
class PageTurner extends StatefulWidget {
  const PageTurner({
    super.key,
    required this.page,
    required this.pageCount,
    required this.builder,
    required this.onTurned,
    required this.cardAspect,
    this.facingBuilder,
  });

  final int page;
  final int pageCount;

  /// Proportions d'une case, pour le **verso** des feuilles.
  ///
  /// **Reçu plutôt que lu dans un fournisseur d'état**, et c'est délibéré : ce
  /// fichier est une brique d'animation qui n'importe ni Riverpod ni rien du
  /// domaine, et lui faire connaître le jeu saisi le coupleraient au produit
  /// pour la seule forme de neuf pochettes vides. Une donnée de géométrie
  /// entre ; un jeu, non.
  ///
  /// **Exigé, faute de valeur par défaut défendable.** Un défaut serait une
  /// neuvième écriture du format d'une carte Magic, exactement ce que ce
  /// chantier a supprimé partout ailleurs.
  final double cardAspect;

  /// La face qui se rabat quand on avance — la page de droite.
  final PageBuilder builder;

  /// La face immobile posée à côté, ou `null` pour une page simple.
  ///
  /// Non nulle, le composant affiche une **double page** : deux faces côte à
  /// côte, reliure au milieu. C'est la seule chose qui distingue le mode
  /// paysage du mode portrait ici — tout le reste est commun.
  final PageBuilder? facingBuilder;

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
    duration: const Duration(milliseconds: 520),
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
      // qui hésiterait entre deux reliures se plierait en deux.
      if (delta > 0 && _canAdvance) {
        _direction = 1;
      } else if (delta < 0 && _canGoBack) {
        _direction = -1;
      } else {
        return;
      }
    }

    _controller.value = (_controller.value + delta * _direction).clamp(
      0.0,
      1.0,
    );
  }

  Future<void> _onDragEnd(DragEndDetails details, double width) async {
    if (_direction == 0) return;

    final velocity = -details.primaryVelocity! * _direction;
    final commits =
        _controller.value > _commitFraction || velocity > _flingVelocity;

    if (commits) {
      // Une page lâchée retombe sous son propre poids : elle accélère, puis
      // s'arrête sans rebondir.
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

  /// Vrai lorsque deux faces sont montrées côte à côte.
  bool get _isSpread => widget.facingBuilder != null;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // **La largeur de la feuille, pas celle de l'écran.** En double page une
        // feuille n'occupe qu'une moitié : c'est cette largeur qui sert de
        // référence au geste comme à la géométrie, faute de quoi il faudrait
        // parcourir deux largeurs de feuille pour la tourner.
        final width = _isSpread
            ? constraints.maxWidth / 2
            : constraints.maxWidth;
        final height = constraints.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => _onDragUpdate(d, width),
          onHorizontalDragEnd: (d) => _onDragEnd(d, width),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              // Au repos, la feuille seule : ni lamelles, ni couche superflue,
              // et une grille aussi ordinaire qu'une autre.
              if (_direction == 0 || t == 0) {
                return _atRest(context);
              }

              final forward = _direction > 0;

              // En avant, c'est la page de droite qui se rabat ; en arrière,
              // celle de gauche qui se relève. Le miroir replace les deux
              // moitiés, il n'y a donc qu'à échanger les rôles.
              final turning = forward
                  ? widget.builder
                  : (widget.facingBuilder ?? widget.builder);
              // En page simple il n'y a pas de voisine — et la garde compte :
              // sans elle, le retour en portrait poserait la page courante à
              // côté d'elle-même.
              final still = !_isSpread
                  ? null
                  : (forward ? widget.facingBuilder : widget.builder);
              final beneath = forward
                  ? widget.builder(context, widget.page + 1)
                  : (widget.facingBuilder ?? widget.builder)(
                      context,
                      widget.page - 1,
                    );

              // Tout est calculé pour un retournement vers la gauche ; le retour
              // est le même mouvement vu dans un miroir. Une seule géométrie à
              // écrire, donc une seule à régler.
              return Transform(
                alignment: Alignment.center,
                transform: forward
                    ? Matrix4.identity()
                    : (Matrix4.identity()..rotateY(math.pi)),
                child: _beside(
                  still: still == null
                      ? null
                      : _Mirrored(
                          mirrored: !forward,
                          child: still(context, widget.page),
                        ),
                  sheet: Stack(
                    fit: StackFit.expand,
                    children: [
                      _Mirrored(mirrored: !forward, child: beneath),
                      CastShadow(t: t),
                      CurlingLeaf(
                        t: t,
                        width: width,
                        height: height,
                        front: _Mirrored(
                          mirrored: !forward,
                          child: turning(context, widget.page),
                        ),
                        back: _SheetBack(cardAspect: widget.cardAspect),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// Ce qu'on voit tant qu'aucune feuille ne bouge.
  Widget _atRest(BuildContext context) {
    final facing = widget.facingBuilder;
    if (facing == null) return widget.builder(context, widget.page);
    return _beside(
      still: facing(context, widget.page),
      sheet: widget.builder(context, widget.page),
    );
  }

  /// Pose la feuille à droite, sa voisine à gauche.
  ///
  /// **Aucun rognage.** La feuille en mouvement sort de sa moitié et passe
  /// par-dessus l'autre page ; c'est précisément ce qu'on veut voir, et un
  /// `Row` ne rogne rien par défaut. La voisine est dessinée en premier, donc
  /// la feuille lui passe devant.
  Widget _beside({required Widget? still, required Widget sheet}) {
    if (still == null) return sheet;
    return Row(
      children: [
        Expanded(child: still),
        Expanded(child: sheet),
      ],
    );
  }
}

/// Remet à l'endroit ce que le miroir du retour a inversé.
///
/// Le classeur entier est retourné pour traiter les deux sens d'un seul calcul ;
/// son contenu doit l'être une seconde fois, sans quoi les cartes s'afficheraient
/// en miroir pendant tout le mouvement.
class _Mirrored extends StatelessWidget {
  const _Mirrored({required this.mirrored, required this.child});

  final bool mirrored;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!mirrored) return child;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()..rotateY(math.pi),
      child: child,
    );
  }
}

/// Le dos d'une feuille : ses neuf pochettes, vides par nature.
///
/// Ce qu'on voit en tournant une page de classeur — le plastique et ses
/// logements, pas les cartes qui y sont glissées de l'autre côté. Aucune image
/// n'y est chargée : le verso ne coûte donc rien, alors qu'y remettre une page
/// entière doublerait les neuf cartes d'une feuille en mouvement.
class _SheetBack extends StatelessWidget {
  const _SheetBack({required this.cardAspect});

  final double cardAspect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: GridView.count(
          crossAxisCount: 3,
          childAspectRatio: cardAspect,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < 9; i++)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// L'ombre que la feuille levée projette sur celle qu'elle découvre.
///
/// Sans elle, les deux pages semblent peintes sur le même plan : c'est l'ombre,
/// plus que la rotation, qui dit qu'une feuille est passée devant l'autre.
class CastShadow extends StatelessWidget {
  const CastShadow({super.key, required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    final strength = math.sin(t * math.pi);

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.black.withValues(alpha: 0.42 * strength),
              Colors.black.withValues(alpha: 0),
            ],
            stops: const [0, 0.6],
          ),
        ),
      ),
    );
  }
}

/// La feuille en mouvement, pliée en lamelles jointes.
///
/// **Publique parce que le produit feuillette à deux endroits.** Le calque de
/// `!montre` (`binder_reveal.dart`) fait défiler des pages jusqu'à celle de la
/// carte demandée ; il avait sa propre rotation, un plan rigide qui pivotait de
/// l'autre sens et **s'enfonçait dans le classeur** au lieu de venir vers
/// l'œil. Écrire une seconde géométrie de page qui tourne, c'était s'assurer
/// que les deux divergent — et elles avaient déjà divergé. Les deux
/// feuilletages partagent donc le même pliage, à la force de la perspective près.
class CurlingLeaf extends StatelessWidget {
  const CurlingLeaf({
    super.key,
    required this.t,
    required this.width,
    required this.height,
    required this.front,
    required this.back,
    this.perspective = _perspective,
  });

  final double t;
  final double width;
  final double height;
  final Widget front;
  final Widget back;

  /// Force de la perspective — voir [_perspective].
  ///
  /// **Réglable parce que le cadre n'est pas le même.** Une feuille dressée
  /// double de taille sous la perspective de l'application, et c'est bien : le
  /// téléphone n'a rien autour. Le calque, lui, est une planche de taille
  /// connue posée sur une vidéo — une feuille qui en déborde se fait trancher
  /// net par le bord de la couverture.
  final double perspective;

  @override
  Widget build(BuildContext context) {
    final base = t * math.pi;
    final stripeWidth = width / _stripes;
    // Le pliage se compose de proche en proche — voir [stripePlacements], qui
    // porte la géométrie et la garantie que les lamelles restent jointes.
    final placements = stripePlacements(t: t, width: width);
    final leaves = <Widget>[];

    for (var i = 0; i < placements.length; i++) {
      final placement = placements[i];
      final along = (i + 0.5) / _stripes;

      leaves.add(
        Transform(
          alignment: Alignment.topLeft,
          transform: Matrix4.identity()
            ..setEntry(3, 2, perspective)
            ..translateByDouble(placement.x, 0, placement.z, 1)
            ..rotateY(placement.angle),
          child: _Stripe(
            index: i,
            // **Un cheveu de plus que sa part.** Deux lamelles jointes au
            // pixel près laissent quand même filtrer le jour : l'arrondi de la
            // rastérisation ne tombe pas au même endroit de part et d'autre de
            // la couture. Un léger recouvrement coûte un demi-pixel de contenu
            // et ferme la fente pour de bon.
            width: stripeWidth + 0.5,
            height: height,
            total: width,
            // Chaque lamelle choisit sa face : au-delà du quart de tour, c'est
            // son dos qu'on voit. Une feuille souple en montre les deux à la
            // fois, de part et d'autre de la pliure — un panneau rigide, jamais.
            showsBack: placement.angle > math.pi / 2,
            // La lumière rase le creux de la courbe. Sans elle, dix facettes ne
            // montreraient que des arêtes.
            shade: 0.34 * math.sin(base) * along,
            slice: stripeWidth,
            front: front,
            back: back,
          ),
        ),
      );
    }

    // **Contraintes lâches, impérativement.** En `StackFit.expand`, chaque
    // lamelle se voit imposer la largeur entière de la feuille : le
    // `SizedBox(width: stripeWidth)` est ignoré, le découpage avec lui, et
    // chaque lamelle affiche alors la page complète décalée d'un cran — d'où
    // des cartes qui se répètent en escalier à mesure que le doigt avance.
    // Sans `fit`, un enfant non positionné garde la taille qu'il demande.
    return SizedBox.expand(
      child: Stack(alignment: Alignment.topLeft, children: leaves),
    );
  }
}

/// Une tranche verticale de la feuille, prise dans l'une ou l'autre face.
class _Stripe extends StatelessWidget {
  const _Stripe({
    required this.index,
    required this.width,
    required this.height,
    required this.total,
    required this.showsBack,
    required this.shade,
    required this.slice,
    required this.front,
    required this.back,
  });

  final int index;

  /// Largeur peinte, légèrement supérieure à [slice] pour fermer la couture.
  final double width;

  final double height;
  final double total;
  final bool showsBack;
  final double shade;

  /// Part exacte de la feuille qui revient à cette lamelle. C'est elle qui
  /// place la tranche dans la page, [width] ne faisant que déborder d'un
  /// cheveu sur la voisine.
  final double slice;

  final Widget front;
  final Widget back;

  @override
  Widget build(BuildContext context) {
    // Le dos est vu depuis l'autre côté : la face arrière est retournée, et la
    // tranche qu'on y prend est comptée depuis le bord opposé.
    final face = showsBack
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..rotateY(math.pi),
            child: back,
          )
        : front;

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
                offset: Offset(-index * slice, 0),
                child: SizedBox(width: total, height: height, child: face),
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
