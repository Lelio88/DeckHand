/// Banc de mesure du flux caméra — la première tâche de l'issue #8.
///
/// **On mesure avant de dessiner autour.** L'inconnue du temps réel n'est pas
/// l'empreinte, dont le coût est connu, c'est ce que coûte *une image* depuis le
/// capteur jusqu'à un identifiant de carte. Si elle coûte 200 ms, il n'y a pas
/// de temps réel, et mieux vaut le savoir avant d'avoir écrit un écran autour.
///
/// **Trois chemins chronométrés côte à côte**, parce qu'un chiffre seul ne dit
/// pas s'il est bon :
///
/// - `luma` — lecture du seul plan de luminance, découpé à la fenêtre
///   d'illustration. C'est le chemin qu'on espère.
/// - `rgb` — conversion YUV→RGB complète de la même fenêtre. C'est le goulot
///   annoncé, et le point de comparaison.
/// - `rgb_full` — la même conversion sur l'image entière, ce que ferait un code
///   qui convertit d'abord et découpe ensuite. La différence entre les deux dit
///   ce que le découpage-avant-conversion fait gagner.
///
/// Chaque chemin est suivi de l'empreinte et de la recherche dans l'index
/// embarqué, pour que le total soit celui d'une image *reconnue*, pas
/// *convertie*.
///
/// **Deux flux, et non un.** Les trois chemins ci-dessus découpent la fenêtre
/// d'illustration à une position convenue : ils décrivent le mode à **caméra
/// fixe**, où la carte se présente toujours au même endroit. Un flux **libre**,
/// où l'on promène l'appareil, doit d'abord retrouver la carte — `frame` puis
/// `find` mesurent ce que cela ajoute, et c'est de loin le poste dominant.
///
/// **Et il mesure le suivi.** Une fois le budget tenu, la question restante
/// n'était plus le coût d'une image mais celui d'une *séquence* : faut-il
/// redétecter la carte à chaque image ? Le banc de poste de travail
/// (`tool/stream_bench.dart`) a tranché ce qui se compte en bits — écarts
/// d'empreinte, reconnaissances perdues, cartes annoncées à tort — mais il ne
/// peut pas rendre de millisecondes, un cœur de bureau n'étant pas un cœur de
/// téléphone. Le coût du suivi y restait donc **composé** à partir de durées
/// mesurées ailleurs. Ce banc-ci exécute `QuadTracker` sur le flux réel, dans
/// la même exécution que la chaîne qui redétecte tout, et rend enfin les deux
/// côte à côte.
///
/// **Le banc compare aussi les empreintes**, pas seulement les durées. Un
/// chemin deux fois plus rapide qui rendrait une empreinte différente serait
/// inutilisable : l'index est calculé par le jumeau Python sur du RGB.
///
/// Il ne fait pas partie de l'application : il s'ouvre par
/// `--dart-define=DECKHAND_BENCH=true`, et n'écrit que dans le journal de
/// diagnostic.
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../diagnostics/diagnostics.dart';
import '../domain/art_box.dart';
import '../domain/art_hash.dart';
import '../domain/art_hash_index.dart';
import '../domain/camera_frame.dart';
import '../domain/card_bounds.dart';
import '../domain/card_edges.dart';
import '../domain/quad_tracker.dart';

/// Images mesurées avant de rendre le bilan. Assez pour que les percentiles
/// aient un sens, assez peu pour tenir dans un tampon de journal.
const int benchFrames = 60;

/// Les premières images sont plus lentes : allocation des tampons, montée en
/// fréquence du processeur. Les compter fausserait la médiane vers le haut.
const int benchWarmup = 10;

/// Résolution du flux, réglable sans recompiler la logique.
///
/// **C'est le levier du flux libre.** Les deux postes dominants — matérialiser
/// l'image, puis y chercher la carte — lisent chaque pixel source : leur coût
/// suit l'aire du capteur, pas la taille d'analyse. Passer de `high` à `medium`
/// divise cette aire par 2,7, et c'est la seule manière d'en juger.
///
/// `--dart-define=DECKHAND_BENCH_RES=medium`
const String benchResolution = String.fromEnvironment(
  'DECKHAND_BENCH_RES',
  defaultValue: 'high',
);

ResolutionPreset get _preset => switch (benchResolution) {
  'low' => ResolutionPreset.low,
  'medium' => ResolutionPreset.medium,
  'veryHigh' => ResolutionPreset.veryHigh,
  _ => ResolutionPreset.high,
};

class FrameBenchScreen extends StatefulWidget {
  const FrameBenchScreen({super.key, this.indexSize = 32000});

  /// Taille de l'index simulé. La recherche est linéaire : son coût dépend du
  /// nombre d'entrées, pas de leur contenu.
  final int indexSize;

  @override
  State<FrameBenchScreen> createState() => _FrameBenchScreenState();
}

class _FrameBenchScreenState extends State<FrameBenchScreen> {
  CameraController? _controller;
  ArtHashIndex? _index;
  String _status = 'ouverture de la caméra…';

  final _luma = <int>[];
  final _rgb = <int>[];
  final _rgbFull = <int>[];
  final _hash = <int>[];
  final _search = <int>[];
  final _direct = <int>[];

  /// Le flux **libre**, où l'appareil se promène et où la carte n'est pas au
  /// même endroit d'une image à l'autre.
  ///
  /// Les autres mesures décrivent le flux à **caméra fixe** : elles découpent la
  /// fenêtre d'illustration à une position convenue, donc supposent le problème
  /// résolu. Un flux libre doit d'abord retrouver la carte, et ce coût-là n'a
  /// jamais été mesuré sur un appareil — seulement au poste de travail, où les
  /// rapports entre résolutions transfèrent mais pas les durées.
  ///
  /// Il se paie en deux temps, mesurés séparément parce qu'ils se réduisent par
  /// des moyens opposés : matérialiser l'image entière (`frame`), puis y
  /// chercher les quatre coins (`find`).
  final _frame = <int>[];
  final _find = <int>[];
  int _found = 0;

  /// Le même flux libre, mais sans matérialiser l'image : la détection lit le
  /// plan de luminance là où il est. Mesuré dans la **même exécution** que le
  /// chemin ci-dessus, seule façon de les comparer sans que l'échauffement de
  /// l'appareil s'en mêle.
  final _findDirect = <int>[];
  int _sameQuad = 0;

  /// La chaîne du flux libre **de bout en bout**, sans aucune image
  /// intermédiaire : détecter, découper l'illustration dans le quadrilatère,
  /// hacher, chercher.
  ///
  /// Les autres totaux additionnent des postes mesurés séparément, dont un
  /// hachage pris sur la fenêtre fixe — 333 000 pixels, alors que le
  /// quadrilatère n'en fait échantillonner que 48 640. Ils surestiment donc ce
  /// que le flux libre coûte vraiment. Celui-ci est le seul honnête.
  final _chain = <int>[];

  /// La même chaîne, mais **en suivant le quadrilatère** au lieu de le refaire.
  ///
  /// C'est la seule mesure qui manquait à la décision de l'issue #8. Le banc de
  /// poste de travail (`tool/stream_bench.dart`) a tranché ce qui se compte —
  /// écarts d'empreinte, reconnaissances perdues, cartes annoncées à tort — mais
  /// il ne peut pas donner de millisecondes : un cœur de bureau n'est pas un
  /// cœur de téléphone. Le coût du suivi y était donc **composé** à partir de
  /// deux durées mesurées ailleurs (22,9 ms pour détecter, 4,5 ms pour le
  /// reste), et non chronométré. Ici il l'est.
  ///
  /// Mesuré **dans la même exécution** que `_chain`, sur les mêmes images :
  /// c'est la seule façon de comparer sans que l'échauffement de l'appareil
  /// s'en mêle, et le fichier applique déjà cette règle aux deux chemins de
  /// détection.
  final _tracked = <int>[];

  /// Combien de fois la détection a réellement tourné sous le suivi, et sur
  /// combien d'images. **Un compte, pas un booléen** : une image peut en
  /// déclencher deux — une par âge, une par saut — et un oui/non les
  /// confondrait, sous-estimant le coût sans que rien ne le dise.
  int _trackedDetections = 0;
  int _trackedFrames = 0;
  final _tracker = QuadTracker();

  /// Écart entre l'empreinte lue sur la luminance et celle du chemin RGB.
  final _drift = <int>[];

  /// Durées de la détection **par droites**, sur le plan de luminance.
  ///
  /// **Le chiffre qui décide du branchement.** Cette chaîne trouve la carte sur
  /// 38 photos réelles sur 39 quand celle par clarté en trouve 4 ; mais elle
  /// coûte, sur poste, quatre fois plus. Un poste n'est pas un téléphone, et
  /// c'est ici que se mesure ce qu'elle vaut vraiment.
  final _edges = <int>[];

  /// Combien d'images rendent un quadrilatère, par chacune des deux chaînes.
  ///
  /// **Sans ce couple, la durée ne veut rien dire** : une chaîne qui ne trouve
  /// jamais rien est instantanée. C'est la leçon du compteur d'écran, qui a
  /// affiché 3 % de détections quand le poste tournait sur 86 % des images.
  int _edgesFound = 0;
  int _lumaFound = 0;
  var _frames = 0;
  var _sameHash = 0;
  var _busy = false;
  var _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    // Un index de la bonne taille, au contenu quelconque : la recherche parcourt
    // toutes les entrées quoi qu'il arrive, et c'est ce parcours qu'on mesure.
    _index = ArtHashIndex.fromEntries([
      for (var i = 0; i < widget.indexSize; i++)
        (
          oracleId: 'card-$i',
          hash: ArtHash.fromHex(
            (i * 2654435761 % 0xFFFFFFFF).toRadixString(16).padLeft(16, '0'),
          ),
        ),
    ]);

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      _report('aucune caméra');
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      back,
      // Ce que verrait un téléphone en potence : assez pour que l'illustration
      // porte du détail, pas au point de payer un capteur entier par image.
      _preset,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    if (!mounted) return;
    _controller = controller;
    setState(() => _status = 'mesure en cours…');

    diagnose('bench_start', {
      'resolution':
          '${controller.value.previewSize?.width.toInt()}'
          '×${controller.value.previewSize?.height.toInt()}',
      'index': widget.indexSize,
      'frames': benchFrames,
      'warmup': benchWarmup,
    });

    await controller.startImageStream(_onFrame);
  }

  void _onFrame(CameraImage image) {
    // Une image à la fois : la file du flux se vide toute seule, et mesurer
    // deux conversions concurrentes ne dirait rien du coût de l'une.
    if (_busy || _done) return;
    _busy = true;
    try {
      _measure(image);
    } finally {
      _busy = false;
    }
  }

  /// Une image du flux, traitée **selon la politique de suivi**.
  ///
  /// C'est l'ordre exact que suivrait le mode temps réel : demander au suivi
  /// s'il faut détecter, hacher avec le quadrilatère tenu, et ne redétecter que
  /// si l'empreinte a sauté. Rend le nombre de détections effectuées.
  ///
  /// **Aucune logique n'est réécrite ici** : la décision appartient entière à
  /// `QuadTracker`, et ce banc ne fait que l'exécuter. En porter une réplique
  /// reviendrait à chronométrer un code que personne n'exécutera, et à laisser
  /// les deux diverger en silence.
  int _trackedStep(CameraImage image, ArtHashIndex index, ArtBox art) {
    final plane = image.planes[0];
    CardQuad? detect() => findCardInLuma(
      plane.bytes,
      width: image.width,
      height: image.height,
      rowStride: plane.bytesPerRow,
      pixelStride: plane.bytesPerPixel ?? 1,
    );
    ArtHash hashWith(CardQuad quad) => artHashFromLuma(
      sampleArtFromLuma(
        plane.bytes,
        width: image.width,
        height: image.height,
        rowStride: plane.bytesPerRow,
        pixelStride: plane.bytesPerPixel ?? 1,
        quad: quad,
        box: art,
      ),
      width: 256,
      height: 190,
      rowStride: 256,
    );

    var detections = 0;
    if (_tracker.needsDetection) {
      _tracker.adopt(detect());
      detections++;
    }

    var quad = _tracker.quad;
    if (quad == null) return detections;

    var fingerprint = hashWith(quad);
    if (_tracker.jumped(fingerprint)) {
      // La scène a changé sous le quadrilatère. On ne cherche pas à savoir
      // quoi : la réponse est la même dans tous les cas, redétecter.
      _tracker.adopt(detect());
      detections++;
      quad = _tracker.quad;
      if (quad == null) return detections;
      fingerprint = hashWith(quad);
    }

    _tracker.keep(fingerprint);
    index.search(fingerprint);
    return detections;
  }

  void _measure(CameraImage image) {
    final index = _index;
    if (index == null) return;

    final width = image.width;
    final height = image.height;
    final planes = image.planes;
    if (planes.isEmpty) return;

    // La fenêtre d'illustration d'une carte qui remplirait l'image. Ce n'est
    // pas le cadrage définitif — c'est la bonne *proportion*, donc le bon coût.
    final art = CardFrame.modern.box;
    final crop = (
      left: (art.left * width).round(),
      top: (art.top * height).round(),
      width: ((art.right - art.left) * width).round(),
      height: ((art.bottom - art.top) * height).round(),
    );

    final watch = Stopwatch()..start();

    // Le chemin retenu : les octets sont lus là où ils sont, sans image
    // intermédiaire. Le test de parité garantit qu'il rend le même bit.
    final fingerprint = artHashFromLuma(
      planes[0].bytes,
      width: width,
      height: height,
      rowStride: planes[0].bytesPerRow,
      pixelStride: planes[0].bytesPerPixel ?? 1,
      crop: crop,
    );
    final tDirect = watch.elapsedMicroseconds;

    // Le chemin par `img.Image`, gardé pour la comparaison : c'est celui du
    // mode photo, et il faut savoir ce que le raccourci fait gagner.
    watch.reset();
    final grey = lumaImage(
      planes[0].bytes,
      width: width,
      height: height,
      rowStride: planes[0].bytesPerRow,
      pixelStride: planes[0].bytesPerPixel ?? 1,
      crop: crop,
    );
    final tLuma = watch.elapsedMicroseconds;

    watch.reset();
    computeArtHash(grey);
    final tHash = watch.elapsedMicroseconds;

    watch.reset();
    index.search(fingerprint);
    final tSearch = watch.elapsedMicroseconds;

    var tRgb = 0;
    var tRgbFull = 0;
    var same = false;
    if (planes.length >= 3) {
      watch.reset();
      final colour = rgbImage(
        planes[0].bytes,
        planes[1].bytes,
        planes[2].bytes,
        width: width,
        height: height,
        lumaRowStride: planes[0].bytesPerRow,
        chromaRowStride: planes[1].bytesPerRow,
        chromaPixelStride: planes[1].bytesPerPixel ?? 2,
        crop: crop,
      );
      tRgb = watch.elapsedMicroseconds;
      // **La distance, pas l'égalité.** Une première version ne comptait que
      // les empreintes identiques : sur une image de synthèse à chrominance
      // neutre elles le sont toutes, sur un vrai capteur non — la conversion
      // RGB arrondit et écrête. Or ce qui décide n'est pas « identique ou
      // non », c'est l'écart comparé au seuil de confiance de l'index (12
      // bits). Un chemin qui s'écarterait d'un bit reste utilisable ; un qui
      // s'écarterait de dix ne l'est pas.
      final fromRgb = computeArtHash(colour);
      _drift.add(fingerprint.distanceTo(fromRgb));
      same = fromRgb == fingerprint;

      watch.reset();
      rgbImage(
        planes[0].bytes,
        planes[1].bytes,
        planes[2].bytes,
        width: width,
        height: height,
        lumaRowStride: planes[0].bytesPerRow,
        chromaRowStride: planes[1].bytesPerRow,
        chromaPixelStride: planes[1].bytesPerPixel ?? 2,
      );
      tRgbFull = watch.elapsedMicroseconds;
    }

    // Le flux libre : l'image entière, puis la recherche des quatre coins.
    watch.reset();
    final full = lumaImage(
      planes[0].bytes,
      width: width,
      height: height,
      rowStride: planes[0].bytesPerRow,
      pixelStride: planes[0].bytesPerPixel ?? 1,
    );
    final tFrame = watch.elapsedMicroseconds;

    watch.reset();
    final quad = findCard(full);
    final tFind = watch.elapsedMicroseconds;

    // Le même travail, sans l'image intermédiaire.
    watch.reset();
    final direct = findCardInLuma(
      planes[0].bytes,
      width: width,
      height: height,
      rowStride: planes[0].bytesPerRow,
      pixelStride: planes[0].bytesPerPixel ?? 1,
    );
    final tFindDirect = watch.elapsedMicroseconds;
    if (direct != null) _lumaFound++;

    // **La détection par droites, sur le même plan et sans image
    // intermédiaire.** 240 px et non 400 : mesuré sur le banc de photos
    // réelles, la qualité y est meilleure et le calcul deux fois moindre.
    watch.reset();
    final byEdges = findCardByEdgesInLuma(
      planes[0].bytes,
      width: width,
      height: height,
      rowStride: planes[0].bytesPerRow,
      pixelStride: planes[0].bytesPerPixel ?? 1,
    );
    _edges.add(watch.elapsedMicroseconds);
    if (byEdges != null) _edgesFound++;

    // La chaîne entière, chronométrée d'un bloc. Quand la détection renonce, il
    // n'y a rien à hacher : ces images-là ne sont pas comptées, sans quoi la
    // médiane décrirait un travail qui n'a pas eu lieu.
    var tChain = 0;
    if (direct != null) {
      watch.reset();
      final quad2 = findCardInLuma(
        planes[0].bytes,
        width: width,
        height: height,
        rowStride: planes[0].bytesPerRow,
        pixelStride: planes[0].bytesPerPixel ?? 1,
      );
      if (quad2 != null) {
        index.search(
          artHashFromLuma(
            sampleArtFromLuma(
              planes[0].bytes,
              width: width,
              height: height,
              rowStride: planes[0].bytesPerRow,
              pixelStride: planes[0].bytesPerPixel ?? 1,
              quad: quad2,
              box: art,
            ),
            width: 256,
            height: 190,
            rowStride: 256,
          ),
        );
      }
      tChain = watch.elapsedMicroseconds;
    }

    // La même chaîne sous suivi. **Le suivi tourne sur toutes les images**,
    // y compris celles où rien n'est trouvé — sa machine à états a besoin de
    // voir le flux entier —, mais la durée n'est retenue que sur les images
    // comparables à `_chain`, sinon les deux médianes porteraient sur des
    // sous-ensembles différents.
    watch.reset();
    final detections = _trackedStep(image, index, art);
    final tTracked = watch.elapsedMicroseconds;

    _frames++;
    if (_frames <= benchWarmup) return;

    _frame.add(tFrame);
    _find.add(tFind);
    _findDirect.add(tFindDirect);
    if (tChain > 0) _chain.add(tChain);
    if (direct != null) {
      _tracked.add(tTracked);
      _trackedDetections += detections;
      _trackedFrames++;
    }
    if (quad != null) _found++;
    // **Les deux chemins doivent conclure pareil**, sur une vraie image et pas
    // seulement sur la figure de test. Un raccourci plus rapide qui trouverait
    // ailleurs serait inutilisable.
    if ((quad == null) == (direct == null) &&
        (quad == null ||
            (quad.topLeft == direct!.topLeft &&
                quad.bottomRight == direct.bottomRight))) {
      _sameQuad++;
    }

    _luma.add(tLuma);
    _direct.add(tDirect);
    _hash.add(tHash);
    _search.add(tSearch);
    _rgb.add(tRgb);
    _rgbFull.add(tRgbFull);
    if (same) _sameHash++;

    if (_luma.length >= benchFrames) {
      _done = true;
      unawaited(_controller?.stopImageStream());
      _report(
        'terminé — $width×$height\n'
        'caméra fixe : ${_median(_direct) ~/ 1000} ms  (rgb ${_median(_rgb) ~/ 1000} ms)\n'
        'flux libre : image ${_median(_frame) ~/ 1000} ms '
        '+ détection ${_median(_find) ~/ 1000} ms\n'
        'sans image : ${_median(_findDirect) ~/ 1000} ms '
        '($_sameQuad/${_findDirect.length} identiques)\n'
        'chaîne entière : ${_median(_chain) ~/ 1000} ms '
        'sur ${_chain.length} images\n'
        'suivi : ${_median(_tracked) ~/ 1000} ms '
        '($_trackedDetections détections / $_trackedFrames images)\n'
        'DROITES : ${_median(_edges) ~/ 1000} ms '
        '— $_edgesFound/${_edges.length} trouvées '
        '(clarté $_lumaFound)
'
        'budget 33 ms à 30 img/s',
      );
      diagnose('bench_result', {
        'frame': '$width×$height',
        'frame_us': _stats(_frame),
        'find_us': _stats(_find),
        'find_direct_us': _stats(_findDirect),
        'droites_us': _stats(_edges),
        'droites_trouvees': _edgesFound,
        'clarte_trouvees': _lumaFound,
        'found': _found,
        'same_quad': _sameQuad,
        'total_libre_us':
            _median(_frame) +
            _median(_find) +
            _median(_hash) +
            _median(_search),
        'total_libre_direct_us':
            _median(_findDirect) + _median(_hash) + _median(_search),
        'chaine_us': _stats(_chain),
        'chaine_n': _chain.length,
        'suivi_us': _stats(_tracked),
        'suivi_n': _trackedFrames,
        'suivi_detections': _trackedDetections,
        'suivi_saut_bits': _tracker.jumpBits,
        'suivi_age_max': _tracker.maxAge,
        'index': widget.indexSize,
        'n': _luma.length,
        'direct_us': _stats(_direct),
        'luma_us': _stats(_luma),
        'rgb_us': _stats(_rgb),
        'rgb_full_us': _stats(_rgbFull),
        'hash_us': _stats(_hash),
        'search_us': _stats(_search),
        'total_direct_us': _median(_direct) + _median(_search),
        'total_luma_us': _median(_luma) + _median(_hash) + _median(_search),
        'total_rgb_us': _median(_rgb) + _median(_hash) + _median(_search),
        'same_hash': _sameHash,
        'drift_bits': _stats(_drift),
        'drift_max': _drift.isEmpty ? 0 : (List.of(_drift)..sort()).last,
        'trusted': maxTrustedDistance,
      });
    }
  }

  Map<String, int> _stats(List<int> values) {
    if (values.isEmpty) return const {'p50': 0, 'p90': 0, 'max': 0};
    final sorted = [...values]..sort();
    return {
      'p50': sorted[sorted.length ~/ 2],
      'p90': sorted[(sorted.length * 9) ~/ 10],
      'max': sorted.last,
    };
  }

  int _median(List<int> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  void _report(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Banc — flux caméra')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_status, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                '${_luma.length} / $benchFrames images',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
