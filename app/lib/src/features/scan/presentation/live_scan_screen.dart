/// Le viseur devient un mode vidéo : reconnaître au fil des cartes (#8).
///
/// **Ce que cet écran promet.** La caméra tourne, les cartes défilent devant
/// elle, et le panier se remplit seul. Rien n'entre en collection : le §IV.8
/// est intact, l'utilisateur confirme à la fin d'un booster — c'est la liste à
/// cocher de l'étalement, dont le rôle est précisément de rendre décochable la
/// carte qu'un seuil a laissé passer.
///
/// **Pourquoi ce mode est le plus facile pour la reconnaissance, et non le plus
/// dur.** L'empreinte décroche au-delà de 3 % d'écart de cadrage, soit deux
/// millimètres et demi — une précision qu'aucune photo à main levée n'atteint.
/// Une caméra tenue au-dessus du tapis, carte toujours au même endroit, **est**
/// cette précision.
///
/// **Tout le calcul vient d'ailleurs, et a été mesuré ailleurs.**
/// [LiveScanner] assemble détection, suivi du quadrilatère, empreinte, index et
/// suivi temporel ; cet écran ne fait que lui donner des images et afficher ce
/// qu'il rend. Une image coûte 12,3 ms sur l'appareil, pour 33 disponibles.
///
/// **Une image à la fois.** Le flux de la caméra ne se met pas en attente : si
/// deux images entraient de front dans la machine à états, sa série et son
/// écart perdraient leur sens. Les images en trop sont donc laissées tomber, ce
/// qui est le bon comportement — la suivante arrive dans 33 ms.
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/selected_game.dart';
import '../../../diagnostics/diagnostics.dart';
import '../../card_search/data/card_repository.dart';
import '../../card_search/domain/card_hit.dart';
import '../../collection/data/collection_repository.dart';
import '../../printings/data/printing_repository.dart';
import '../../printings/domain/scryfall_image.dart';
import '../../printings/presentation/printing_picker.dart';
import '../data/art_index_repository.dart';
import '../domain/live_scanner.dart';
import '../domain/scan_basket.dart';
import '../domain/scan_tally.dart';
import 'scan_basket_grid.dart';
import 'scan_trouble_bar.dart';

class LiveScanScreen extends ConsumerStatefulWidget {
  const LiveScanScreen({super.key});

  @override
  ConsumerState<LiveScanScreen> createState() => _LiveScanScreenState();
}

class _LiveScanScreenState extends ConsumerState<LiveScanScreen> {
  CameraController? _controller;
  LiveScanner? _scanner;
  final _basket = ScanBasket();

  /// Ce qu'on sait des cartes du panier. Résolu au fil de l'eau : une carte
  /// retenue est affichée par son identifiant le temps que son nom arrive.
  final Map<String, CardHit> _known = {};
  final Map<String, PrintingChoice> _sole = {};

  /// Ce que la passe a produit, ventilé par cause d'échec. **Lisible à
  /// l'écran** : le journal passe par `adb logcat`, donc par un débogage sans
  /// fil qui retombe régulièrement, et une passe de terrain qu'on ne peut pas
  /// relire est une passe perdue.
  final _tally = ScanTally();
  DateTime _lastTallyPaint = DateTime.fromMillisecondsSinceEpoch(0);
  FrameOutcome? _lastOutcome;

  String? _status = 'ouverture de la caméra…';
  String? _watching;
  bool _busy = false;
  bool _saving = false;
  String? _saveError;

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
    try {
      final index = await ref.read(artHashIndexProvider.future);
      final game = ref.read(selectedGameProvider);
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _status = 'Aucune caméra disponible.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        // Ce que verrait un téléphone en potence : assez pour que
        // l'illustration porte du détail, pas au point de payer un capteur
        // entier par image. Mesuré : la détection coûte le même prix quelle que
        // soit la résolution, son travail étant payé à la taille d'analyse.
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      setState(() {
        _controller = controller;
        _scanner = LiveScanner(
          index: index,
          game: game.id,
          // **Le capteur ne livre pas ce que l'écran montre.** Son buffer
          // arrive en paysage, et l'écran de scan est verrouillé en portrait
          // (`AndroidManifest.xml`) : une carte posée droite y est couchée.
          // Sans cette valeur, le contrôle d'aspect la rejetait, et le flux ne
          // détectait rien du tout sur les jeux qui n'impriment aucune carte en
          // travers. Flutter définit `sensorOrientation` comme l'angle horaire
          // qui redresse l'image, ce que [LiveScanner.uprightTurns] attend tel
          // quel.
          uprightTurns: back.sensorOrientation ~/ 90,
        );
        _status = null;
      });
      await controller.startImageStream(_onFrame);
    } catch (e) {
      if (mounted) setState(() => _status = 'Caméra indisponible : $e');
    }
  }

  void _onFrame(CameraImage image) {
    final scanner = _scanner;
    if (_busy || scanner == null || image.planes.isEmpty) return;
    _busy = true;
    try {
      final plane = image.planes.first;
      final seen = scanner.observe(
        plane.bytes,
        width: image.width,
        height: image.height,
        rowStride: plane.bytesPerRow,
        pixelStride: plane.bytesPerPixel ?? 1,
      );

      _tally.record(seen);

      final accepted = seen.accepted;
      if (accepted != null) {
        _basket.add(accepted);
        unawaited(_resolve(accepted));
        diagnose('live_accepted', {
          'oracle_id': accepted,
          'distance': seen.distance,
          'marge': seen.margin,
          'images': _tally.frames,
        });
      }

      // **Le journal ne consigne que les changements.** Une carte reste devant
      // l'objectif des dizaines d'images ; en journaliser chacune rendrait le
      // relevé illisible pour la raison même qui rend le mode utile.
      if (seen.outcome != _lastOutcome) {
        _lastOutcome = seen.outcome;
        diagnose('live_frame', {
          'issue': seen.outcome.name,
          'candidat': seen.best,
          'distance': seen.distance,
          'marge': seen.margin,
        });
      }

      // L'écran ne se reconstruit que lorsque quelque chose a changé : à trente
      // images par seconde, un `setState` par image ferait tourner la mise en
      // page plus souvent que la reconnaissance. Le compteur, lui, se rafraîchit
      // au rythme de la seconde — assez pour être lu, pas assez pour coûter.
      final now = DateTime.now();
      final refresh =
          now.difference(_lastTallyPaint) > const Duration(seconds: 1);
      if (accepted != null || seen.watching != _watching || refresh) {
        if (refresh) _lastTallyPaint = now;
        if (mounted) setState(() => _watching = seen.watching);
      }
    } finally {
      _busy = false;
    }
  }

  /// Va chercher le nom, et l'édition quand il n'y en a qu'une.
  ///
  /// **Une seule édition se remplit d'office** : la désigner n'apporte rien que
  /// la carte ne porte déjà, et demander le geste reviendrait à faire ouvrir
  /// une liste d'un seul élément quinze fois par booster. Garde-fou §IV.8
  /// intact — c'est l'édition qui se déduit, jamais la carte.
  Future<void> _resolve(String oracleId) async {
    if (_known.containsKey(oracleId)) return;
    try {
      final hits = await ref.read(cardRepositoryProvider).byOracleIds([
        oracleId,
      ]);
      if (!mounted || hits.isEmpty) return;
      setState(() => _known[oracleId] = hits.first);

      final sole = await ref.read(printingRepositoryProvider).soleEditions({
        oracleId,
      }, lang: hits.first.matchedLang);
      final only = sole[oracleId];
      if (!mounted || only == null) return;
      setState(() {
        _sole[oracleId] = PrintingChoice(
          only,
          isFoil: !only.hasNonfoil && only.hasFoil,
        );
      });
    } on Object {
      // Le nom manquera, la carte reste au panier sous son identifiant. Une
      // panne de catalogue ne doit pas faire perdre un booster déjà scanné.
    }
  }

  /// Repart de zéro pour la passe suivante, **panier compris**.
  ///
  /// Garder le panier ferait compter les cartes d'une passe dans la suivante ;
  /// remettre le compteur sans le panier donnerait un relevé qui ne décrit pas
  /// ce qu'on a sous les yeux. Les deux vont ensemble, et le suivi aussi — sans
  /// quoi la première carte du lot suivant compterait comme la suite du
  /// précédent.
  void _resetTally() {
    diagnose('live_passe', {'releve': _tally.describe()});
    setState(() {
      _tally.reset();
      _basket.clear();
      _scanner?.reset();
      _watching = null;
      _lastOutcome = null;
    });
  }

  Future<void> _save() async {
    final kept = _basket.kept;
    if (kept.isEmpty) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final repository = ref.read(collectionRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    var added = 0;
    try {
      for (final line in kept) {
        final printing = _sole[line.oracleId];
        await repository.add(
          line.oracleId,
          quantity: line.quantity,
          printId: printing?.printing.printId,
          isFoil: printing?.isFoil ?? false,
        );
        added += line.quantity;
      }
      ref.invalidate(collectionProvider);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '$added carte${added > 1 ? 's' : ''} ajoutée${added > 1 ? 's' : ''}',
          ),
        ),
      );
      navigator.pop();
    } catch (e) {
      // **La liste reste.** Une coupure au moment d'« Ajouter » ne doit pas
      // effacer un booster entier : décocher ce qui est déjà passé est le seul
      // geste que l'utilisateur puisse faire à notre place, encore faut-il
      // qu'il voie ses lignes.
      if (mounted) {
        setState(() => _saveError = 'Enregistrement impossible : $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Les lignes du panier, telles que la grille les montre.
  ///
  /// **L'image vient de l'impression quand on la connaît**, de la carte sinon :
  /// `_sole` ne porte une édition que lorsqu'une seule était possible (§IV.8),
  /// et dans ce cas c'est bien ce carton-là qu'il faut montrer.
  List<ScannedCard> _scannedCards() => [
    for (final line in _basket.lines)
      ScannedCard(
        oracleId: line.oracleId,
        label: _known[line.oracleId]?.matchedName ?? 'Carte reconnue',
        imageUrl: fullCardImage(
          _sole[line.oracleId]?.printing.artCropUrl ??
              _known[line.oracleId]?.artUrl,
        ),
        quantity: line.quantity,
        keep: line.keep,
      ),
  ];

  void _toggleKeep(String oracleId) {
    for (final line in _basket.lines) {
      if (line.oracleId == oracleId) {
        setState(() => line.keep = !line.keep);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cartes au fil de la caméra'),
        actions: [
          if (!_basket.isEmpty)
            TextButton(
              onPressed: _saving ? null : _save,
              child: Text('Ajouter (${_basket.keptCount})'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_status != null)
            Expanded(child: Center(child: _Note(_status!)))
          else if (controller != null)
            SizedBox(
              height: 220,
              width: double.infinity,
              // **L'aperçu est clippé, et il ne l'était pas.** Mis à l'échelle
              // pour couvrir, il débordait de sa boîte et passait derrière tout
              // ce qui suit : le relevé s'affichait en travers de la carte
              // filmée, et la liste par-dessus l'image.
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: controller.value.previewSize?.height ?? 720,
                        height: controller.value.previewSize?.width ?? 1280,
                        child: CameraPreview(controller),
                      ),
                    ),
                    // Le relevé en haut, et seulement quand la passe bloque :
                    // il masquait la carte qu'on filmait pour dire des chiffres
                    // dont on n'a besoin que lorsque rien ne marche.
                    Align(
                      alignment: Alignment.topCenter,
                      child: ScanTroubleBar(
                        tally: _tally,
                        onReset: _resetTally,
                      ),
                    ),
                    // **Dire ce que l'appareil regarde**, pas seulement ce
                    // qu'il a retenu : sans cela, l'utilisateur ne sait pas si
                    // la carte est mal posée ou si la reconnaissance réfléchit
                    // encore.
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: _Watching(
                        label: _watching == null
                            ? 'Posez une carte sous l\'objectif'
                            : (_known[_watching]?.matchedName ??
                                  'Carte reconnue…'),
                        active: _watching != null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_saveError != null) _Note(_saveError!),
          // **L'espace libre revient aux cartes, en entier.** C'est ce qu'on
          // parcourt après la passe, une fois les deux mains libres : une
          // illustration se reconnaît d'un coup d'œil là où un nom demande de
          // lire et de croire l'application sur parole.
          Expanded(
            child: _basket.isEmpty
                ? Center(
                    child: _Note(
                      'Rien pour l\'instant.\nLes cartes reconnues '
                      's\'ajouteront ici, et vous confirmerez à la fin.',
                    ),
                  )
                : ScanBasketGrid(
                    cards: _scannedCards(),
                    enabled: !_saving,
                    onToggle: _toggleKeep,
                    onRemove: (id) => setState(() => _basket.remove(id)),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Watching extends StatelessWidget {
  const _Watching({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(10),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: active ? const Color(0xCC1F6F43) : const Color(0xAA101014),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: const TextStyle(color: Colors.white, fontSize: 13),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
