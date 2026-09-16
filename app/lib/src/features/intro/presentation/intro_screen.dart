/// L'écran d'ouverture : trois cartes se distribuent et se rangent en logo.
///
/// **Portage fidèle de `tools/mockups/deckhand_intro.html`**, validé à l'œil
/// avant d'être écrit ici — la méthode qui a donné `dewdrop_loader.dart`. Les
/// constantes de temps, les poses et les couleurs sont reprises telles quelles :
/// ce fichier traduit, il n'invente pas. Toute retouche du mouvement se fait
/// dans la maquette d'abord, où on la voit sans recompiler.
///
/// **Ce n'est pas un ornement, c'est du temps déjà payé.** Mesuré sous le rôle
/// réel, le premier appel d'une session froide coûte jusqu'à 7,4 s — le serveur
/// n'ayant que 224 Mio de cache pour 742 Mo de base. L'accueil est monté
/// **sous** l'intro dès le premier frame : ses requêtes partent pendant
/// l'animation, et les 2,2 s qu'elle dure sont autant de retranché à l'attente.
/// C'est la raison pour laquelle [IntroGate] empile plutôt qu'il n'aiguille.
///
/// **Six notes, comme DewDrop, et une autre couleur.** Les deux applications
/// partagent une grammaire — environ 2,2 s, six notes, le logo qui apparaît
/// dedans. DewDrop monte un arpège de do majeur en onde carrée 8-bit ; DeckHand
/// descend sur du bois, en sol mixolydien pincé. Le son est généré par
/// `tools/sounds/gen_intro_jingle.py`, dont les battues sont jumelles de
/// [_gestes] : déplacer l'une sans l'autre désynchronise l'intro, et cela ne
/// s'entend qu'à l'oreille.
///
/// **Rendu au `CustomPaint`, sans une seule image.** Le logo est dessiné, comme
/// `api/make_store_assets.py` le dessine pour le Play Store — d'où des couleurs
/// et une fenêtre d'illustration identiques, et une dernière image figée qui
/// *est* l'icône.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Durée totale de l'animation.
///
/// 2 200 ms : exactement celle de `DewDropLoader` (arc 1,2 s + tenue 1,0 s).
const Duration introDuration = Duration(milliseconds: 2200);

/// Temps minimum pendant lequel l'intro occupe l'écran.
///
/// Cent millisecondes de plus que l'animation, pour qu'on voie sa dernière
/// image plutôt que de la quitter sur sa fin. Même écart que DewDrop.
const Duration introFloor = Duration(milliseconds: 2300);

/// Instant de la première carte posée — et de la première note.
const Duration _introSoundStart = Duration(milliseconds: 200);

/// Les six battues, en millisecondes depuis l'ouverture.
///
/// **Jumelles de `BATTUES` dans `tools/sounds/gen_intro_jingle.py`**, décalées
/// de [_introSoundStart] : le jingle commence à la première carte, pas à
/// l'ouverture de l'écran.
const List<int> _gestes = [200, 500, 800, 1100, 1300, 1600];

// Durées d'exécution de chaque geste, en millisecondes.
const int _glisse = 260;
const int _retourne = 200;
const int _resserre = 250;
const int _mot = 400;

// Couleurs relevées sur `api/make_store_assets.py` : l'identité vient de
// l'icône réelle, pas d'un nuancier inventé.
const Color _fond = Color(0xFF12101A);
const Color _fondHaut = Color(0xFF1E1A28);
const Color _creme = Color(0xFFEDE3C8);
const Color _or = Color(0xFFC9A961);
const Color _orSombre = Color(0xFF8A7343);

/// Carte Magic : 63 × 88 mm.
const double _ratioCarte = 63 / 88;

/// Fenêtre d'illustration du cadre moderne, en proportions de la carte.
///
/// Reprise de `CardFrame.modern` : c'est la zone que la reconnaissance découpe
/// pour calculer une empreinte. La dessiner fait lire le rectangle du dessus
/// comme une **carte** et non comme une page blanche.
const double _fenetreG = 0.080, _fenetreH = 0.120;
const double _fenetreD = 0.920, _fenetreB = 0.550;

/// Une pose de carte : décalage en fractions de la scène, et inclinaison.
@immutable
class _Pose {
  const _Pose(this.x, this.y, this.r);
  final double x;
  final double y;

  /// Inclinaison en degrés.
  final double r;

  static _Pose lerp(_Pose a, _Pose b, double t) =>
      _Pose(_lerp(a.x, b.x, t), _lerp(a.y, b.y, t), _lerp(a.r, b.r, t));
}

// « posée » : là où une carte atterrit. « logo » : là où l'éventail la range,
// c'est-à-dire l'icône du Play Store.
//
// **Les décalages sont petits parce que le pivot fait le travail.** Une carte
// tenue en main tourne autour de son bas, pas de son centre : c'est ce qui fait
// qu'un éventail s'ouvre en haut et reste serré en bas. Tourner autour du
// centre donnait trois cartes décalées côte à côte — lisible, mais ce n'était
// pas un éventail, et ce n'était pas l'icône. Vu sur capture, pas déduit.
const _gauchePosee = _Pose(-0.075, 0.020, -29);
const _gaucheLogo = _Pose(-0.022, 0.014, -21);
const _droitePosee = _Pose(0.075, 0.020, 29);
const _droiteLogo = _Pose(0.022, 0.014, 21);
const _centre = _Pose(0, 0, 0);

/// Où se trouve le pivot d'une carte, en fractions de sa hauteur sous son
/// centre. 0,55 le place juste sous le bord inférieur — le point où les doigts
/// tiennent la main.
const double _pivot = 0.55;

double _lerp(double a, double b, double t) => a + (b - a) * t;
double _clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);
double _sortieCubique(double t) => 1 - math.pow(1 - t, 3).toDouble();
double _entreeQuad(double t) => t * t;

/// Léger dépassement : l'éventail claque au lieu de glisser.
double _sortieDos(double t) {
  const c = 1.70158;
  final u = t - 1;
  return 1 + (c + 1) * u * u * u + c * u * u;
}

/// L'animation d'ouverture, seule. [IntroGate] l'empile au-dessus de l'accueil.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key, this.onTap, this.playSound = true});

  /// Appelé quand on touche l'écran, pour sauter l'attente.
  final VoidCallback? onTap;

  /// Joue le jingle une fois. Faux dans les tests, où l'audio n'existe pas.
  final bool playSound;

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  AudioPlayer? _player;
  Timer? _son;

  @override
  void initState() {
    super.initState();
    // Une seule passe, puis l'image se fige sur le logo. Rien ne reboucle.
    _ctrl = AnimationController(vsync: this, duration: introDuration)..forward();
    if (widget.playSound) _programmerLeSon();
  }

  void _programmerLeSon() {
    _player = AudioPlayer();
    // **Le son part avec la première carte, pas avec l'écran.** Les battues du
    // jingle sont comptées depuis cet instant.
    _son = Timer(_introSoundStart, () {
      // Un son manqué ne vaut pas une erreur : le navigateur peut refuser de
      // jouer avant un geste, et un téléphone en silencieux ne doit rien lever.
      unawaited(
        _player
            ?.play(AssetSource('audio/deckhand_intro.mp3'))
            .catchError((_) {}),
      );
    });
  }

  @override
  void dispose() {
    _son?.cancel();
    _ctrl.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: ColoredBox(
        color: _fond,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _IntroPainter(_ctrl),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _IntroPainter extends CustomPainter {
  _IntroPainter(this.anim) : super(repaint: anim);

  final Animation<double> anim;

  late double _l, _h, _s;

  @override
  void paint(Canvas canvas, Size size) {
    _l = size.width;
    _h = size.height;
    _s = math.min(_l, _h);
    final ms = anim.value * introDuration.inMilliseconds;

    _tapis(canvas);

    // Où en est le resserrement de l'éventail ?
    final k = ms >= _gestes[4]
        ? _sortieDos(_clamp01((ms - _gestes[4]) / _resserre))
        : 0.0;

    if (ms >= _gestes[0]) {
      final u = _clamp01((ms - _gestes[0]) / _glisse);
      final cible = _Pose.lerp(_gauchePosee, _gaucheLogo, k);
      _carte(canvas, u < 1 ? _arrivee(cible, -0.85, u) : cible,
          face: false, teinte: _orSombre);
    }

    if (ms >= _gestes[1]) {
      final u = _clamp01((ms - _gestes[1]) / _glisse);
      final cible = _Pose.lerp(_droitePosee, _droiteLogo, k);
      _carte(canvas, u < 1 ? _arrivee(cible, 0.85, u) : cible,
          face: false, teinte: _or);
    }

    if (ms >= _gestes[2]) {
      final u = _clamp01((ms - _gestes[2]) / _glisse);
      var pose = _centre;
      var pince = 1.0;
      var face = false;

      if (u < 1) {
        // Elle tombe d'en haut plutôt que de glisser de côté : c'est le geste de
        // poser une carte, pas de la faire entrer en scène.
        final e = _entreeQuad(u);
        pose = _Pose(_centre.x, _lerp(_centre.y - 0.22, _centre.y, e),
            _lerp(-8, _centre.r, e));
      }
      if (ms >= _gestes[3]) {
        final f = _clamp01((ms - _gestes[3]) / _retourne);
        pince = (math.cos(math.pi * f)).abs();
        face = f >= 0.5;
      }
      _carte(canvas, pose, face: face, teinte: _orSombre, pince: pince);
    }

    _wordmark(canvas, _clamp01((ms - _gestes[5]) / _mot));
  }

  /// Une carte qui arrive : depuis [depuisX] vers sa pose.
  _Pose _arrivee(_Pose p, double depuisX, double u) {
    final e = _sortieCubique(u);
    return _Pose(_lerp(depuisX, p.x, e), _lerp(p.y - 0.06, p.y, e),
        _lerp(p.r * 2.2, p.r, e));
  }

  void _tapis(Canvas canvas) {
    final rect = Offset.zero & Size(_l, _h);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, _h),
          const [_fondHaut, _fond],
        ),
    );
    // Halo chaud sous l'éventail : le tapis, et la lumière qui tombe dessus.
    final centre = Offset(_l / 2, _h * 0.46);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(centre, _s * 1.05, const [
          Color(0x1AC9A961),
          Color(0x00C9A961),
        ]),
    );
    // Vignette, pour que les bords ne concurrencent pas les cartes.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(_l / 2, _h * 0.5),
          _s * 1.2,
          const [Color(0x00000000), Color(0x8C000000)],
          const [0.3, 1.0],
        ),
    );
  }

  Path _cheminCarte(double largeur, double hauteur, double rayon) {
    return Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: largeur,
            height: hauteur,
          ),
          Radius.circular(rayon),
        ),
      );
  }

  /// Une carte, face ou dos, à sa pose.
  ///
  /// [pince] écrase la largeur pour le retournement — c'est la seule façon
  /// d'avoir une carte vue par la tranche.
  void _carte(
    Canvas canvas,
    _Pose pose, {
    required bool face,
    required Color teinte,
    double pince = 1,
  }) {
    final hauteur = _h * 0.235;
    final largeur = hauteur * _ratioCarte;
    final cx = _l / 2 + pose.x * _l;
    final cy = _h * 0.44 + pose.y * _h;

    canvas.save();
    // Pivoter sous la carte, tourner, puis remonter : la rotation s'applique au
    // point de tenue et non au centre du carton.
    canvas.translate(cx, cy + hauteur * _pivot);
    canvas.rotate(pose.r * math.pi / 180);
    canvas.translate(0, -hauteur * _pivot);
    canvas.scale(math.max(pince, 0.001), 1);

    final chemin = _cheminCarte(largeur, hauteur, hauteur * 0.045);

    canvas.drawPath(
      chemin.shift(Offset(0, _s * 0.018)),
      Paint()
        ..color = const Color(0x8C000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, _s * 0.02),
    );

    if (face) {
      canvas.drawPath(chemin, Paint()..color = _creme);
      canvas.drawPath(
        chemin,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, _s * 0.004)
          ..color = _orSombre,
      );
      final fx = -largeur / 2 + largeur * _fenetreG;
      final fy = -hauteur / 2 + hauteur * _fenetreH;
      final fl = largeur * (_fenetreD - _fenetreG);
      final fh = hauteur * (_fenetreB - _fenetreH);
      canvas.drawRect(
        Rect.fromLTWH(fx, fy, fl, fh),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(fx, fy),
            Offset(fx, fy + fh),
            const [_or, _orSombre],
          ),
      );
      // Deux lignes de texte, comme sur l'icône.
      final encre = Paint()..color = const Color(0x8C8A7343);
      canvas.drawRect(
        Rect.fromLTWH(fx, fy + fh + hauteur * 0.075, fl, hauteur * 0.028),
        encre,
      );
      canvas.drawRect(
        Rect.fromLTWH(
          fx,
          fy + fh + hauteur * 0.135,
          fl * 0.66,
          hauteur * 0.028,
        ),
        encre,
      );
    } else {
      canvas.drawPath(
        chemin,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(-largeur / 2, -hauteur / 2),
            Offset(largeur / 2, hauteur / 2),
            [teinte, const Color(0xFF5E4E2C)],
          ),
      );
      canvas.drawPath(
        chemin,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, _s * 0.004)
          ..color = const Color(0x8CC9A961),
      );
      // Cartouche central du dos.
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: largeur * 0.60,
          height: hauteur * 0.60,
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, _s * 0.003)
          ..color = const Color(0x47EDE3C8),
      );
    }
    canvas.restore();
  }

  void _wordmark(Canvas canvas, double alpha) {
    if (alpha <= 0) return;
    // Poids 300 et interlettrage léger : le traitement de DewDrop, pour que les
    // deux applications se reconnaissent comme sœurs.
    final tp = TextPainter(
      text: TextSpan(
        text: 'DeckHand',
        style: TextStyle(
          color: _creme.withValues(alpha: 0.96 * alpha),
          fontSize: _s * 0.095,
          fontWeight: FontWeight.w300,
          letterSpacing: _s * 0.006,
          // **La famille est nommée, et c'est un choix de logo.** Laisser le
          // champ vide fait suivre la police système — Roboto sur Android,
          // autre chose ailleurs, et sous `flutter test` la police Ahem, qui
          // dessine un rectangle par lettre. La première capture l'a montré.
          // Un nom de marque ne se rend pas différemment selon l'appareil ;
          // c'est d'ailleurs la police que le thème de l'application emploie
          // déjà partout.
          fontFamily: 'Roboto',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(_l / 2 - tp.width / 2, _h * 0.735 - tp.height / 2));
  }

  @override
  bool shouldRepaint(_IntroPainter old) => false;
}
