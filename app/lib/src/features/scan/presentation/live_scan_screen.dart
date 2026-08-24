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
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/selected_game.dart';
import '../../../diagnostics/diagnostics.dart';
import '../../card_search/data/card_repository.dart';
import '../../card_search/domain/card_hit.dart';
import '../../collection/data/collection_repository.dart';
import '../../printings/data/printing_repository.dart';
import '../../printings/domain/scryfall_image.dart';
import '../../printings/presentation/card_art_view.dart';
import '../../printings/presentation/printing_picker.dart';
import 'dart:typed_data';
import '../data/card_text_reader.dart';
import '../domain/art_hash.dart';
import '../domain/art_hash_index.dart';
import '../domain/card_geometry.dart';
import '../domain/card_name_text.dart';
import '../data/art_index_repository.dart';
import '../domain/live_scanner.dart';
import '../domain/scan_basket.dart';
import '../domain/scan_tally.dart';
import 'scan_basket_grid.dart';
import 'quad_overlay.dart';
import 'scan_region_editor.dart';
import 'scan_trouble_bar.dart';

class LiveScanScreen extends ConsumerStatefulWidget {
  const LiveScanScreen({super.key});

  @override
  ConsumerState<LiveScanScreen> createState() => _LiveScanScreenState();
}

/// Entre deux lectures de texte. Une carte ne change pas de nom en un clin
/// d'œil, et la reconnaissance de texte coûte bien plus qu'une image de flux.
const Duration _delaiEntreLectures = Duration(milliseconds: 900);

/// Où se retient le choix d'afficher le cadre.
///
/// Par appareil et non par compte : c'est un réglage d'affichage, comme le jeu
/// courant, et il n'a aucune raison de suivre l'utilisateur d'un téléphone à
/// l'autre.
const String _clefApercuCadre = 'scan_apercu_cadre';

/// Où se retient la zone regardée. Par appareil, comme le cadrage lui-même :
/// elle décrit une potence ou un coin de table, pas un utilisateur.
const String _clefZone = 'scan_zone';

class _LiveScanScreenState extends ConsumerState<LiveScanScreen> {
  final _reader = CardTextReader();

  /// L'index d'empreintes, gardé sous la main.
  ///
  /// Il sert deux fois : au scanner, qui identifie la carte, et ici, pour
  /// choisir l'édition une fois le nom lu. L'interroger par le provider
  /// obligerait à traiter un état de chargement qui, à ce stade, est passé.
  ArtHashIndex? _index;

  /// Montrer ou non le cadre que la détection retient.
  ///
  /// **Éteint par défaut, et c'est délibéré.** Le tracé sert à comprendre
  /// pourquoi une carte n'est pas reconnue ; l'afficher toujours ajouterait du
  /// mouvement à un écran dont l'objet est la carte, pas la mécanique.
  bool _showQuad = false;

  /// Où l'on accepte de chercher une carte, et si l'on est en train de le régler.
  ScanRegion _region = ScanRegion.whole;
  bool _reglageZone = false;
  List<({double x, double y})>? _corners;

  /// L'impression que la lecture du nom a retenue pour chaque carte.
  ///
  /// Elle est choisie au moment de la lecture, mais la carte n'entre au panier
  /// qu'une fois sa série faite : sans cette mémoire, l'édition serait perdue
  /// entre les deux.
  final Map<String, String> _editions = {};
  CameraController? _controller;
  LiveScanner? _scanner;

  /// Le jeu et l'orientation du capteur, retenus hors du scanner.
  ///
  /// Ils lui servaient de mémoire ; ils ne le peuvent plus, l'index et la
  /// caméra n'arrivant plus dans un ordre garanti.
  String? _game;
  int _uprightTurns = 0;
  bool _cameraPrete = false;
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

  /// Lecture de texte en cours, et date de la dernière.
  ///
  /// **Une à la fois, et pas trop souvent.** La reconnaissance de texte coûte
  /// bien plus qu'une image de flux ; en lancer une par image saturerait le fil
  /// sans rien lire de plus, la carte ne changeant pas de nom en trente
  /// millisecondes.
  bool _reading = false;
  DateTime _lastRead = DateTime.fromMillisecondsSinceEpoch(0);

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
    // Le lecteur de texte tient une ressource native : la laisser derrière soi
    // fuit à chaque ouverture de l'écran.
    unawaited(_reader.dispose());
    super.dispose();
  }

  /// Ouvre la caméra, et charge l'index **à côté** plutôt qu'avant.
  ///
  /// **L'ordre était le problème.** La séquence attendait les préférences, puis
  /// l'index — sa relecture, et un appel de comptage au serveur — et n'ouvrait
  /// la caméra qu'ensuite. Or l'aperçu est ce que l'utilisateur vient voir, et
  /// il ne dépend d'aucun des deux : [_onFrame] écarte déjà les images tant que
  /// `_scanner` est nul. Les deux chaînes courent donc en parallèle, et la
  /// reconnaissance s'arme quand ses conditions sont réunies.
  Future<void> _start() async {
    await _lireLesReglages();
    unawaited(_chargerIndex());

    try {
      final game = ref.read(selectedGameProvider);
      _game = game.id;
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
        // **NV21 plutôt que YUV420, pour que le texte soit lisible.** ML Kit
        // n'accepte un tampon brut que dans un format qu'il connaît, et c'est
        // celui-là sur Android. Le reste du pipeline n'y perd rien : le premier
        // plan reste la luminance, seule consommée par la détection et par
        // l'empreinte.
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      setState(() {
        _controller = controller;
        // **Le capteur ne livre pas ce que l'écran montre.** Son buffer arrive
        // en paysage, et l'écran de scan est verrouillé en portrait
        // (`AndroidManifest.xml`) : une carte posée droite y est couchée. Sans
        // cette valeur, le contrôle d'aspect la rejetait, et le flux ne
        // détectait rien du tout sur les jeux qui n'impriment aucune carte en
        // travers. Flutter définit `sensorOrientation` comme l'angle horaire
        // qui redresse l'image, ce que [LiveScanner.uprightTurns] attend tel
        // quel.
        _uprightTurns = back.sensorOrientation ~/ 90;
        _cameraPrete = true;
        _status = null;
      });
      _armerLeScanner();
      await controller.startImageStream(_onFrame);
    } catch (e) {
      if (mounted) setState(() => _status = 'Caméra indisponible : $e');
    }
  }

  /// Les réglages de confort : l'aperçu du cadre et la zone de lecture.
  ///
  /// Leur absence n'empêche pas de scanner — d'où l'échec avalé. Ils sont lus
  /// avant tout le reste parce que la zone entre dans la construction du
  /// scanner, et parce que la lecture est déjà chaude : le jeu courant a
  /// ouvert les préférences au démarrage de l'application.
  Future<void> _lireLesReglages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _showQuad = prefs.getBool(_clefApercuCadre) ?? false;
      final zone = prefs.getStringList(_clefZone);
      if (zone != null && zone.length == 4) {
        final v = zone.map(double.tryParse).whereType<double>().toList();
        if (v.length == 4) {
          _region = ScanRegion(
            left: v[0],
            top: v[1],
            right: v[2],
            bottom: v[3],
          ).sane;
        }
      }
    } on Object catch (error) {
      debugPrint('réglages de scan illisibles : $error');
    }
  }

  /// Charge l'index, sans bloquer l'aperçu.
  ///
  /// **Son échec ne remplace pas l'écran.** `_status` n'est posé que si rien
  /// d'autre ne s'y trouve : une caméra indisponible est une panne plus grave
  /// qu'un index manquant, et son message ne doit pas être écrasé par celui-ci.
  Future<void> _chargerIndex() async {
    try {
      final index = await ref.read(artHashIndexProvider.future);
      if (!mounted) return;
      _index = index;
      _armerLeScanner();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _status ??= 'Index indisponible : $error');
    }
  }

  /// Arme la reconnaissance dès que ses conditions sont réunies.
  ///
  /// Appelé des deux côtés de la course — par la caméra et par l'index — sans
  /// savoir lequel arrive en premier : la garde est ici, une fois, plutôt que
  /// dupliquée chez les deux appelants.
  void _armerLeScanner() {
    final index = _index;
    final game = _game;
    if (index == null || game == null || !_cameraPrete || !mounted) return;
    setState(() {
      _corners = null;
      _scanner = LiveScanner(
        index: index,
        game: game,
        region: _region.sane,
        uprightTurns: _uprightTurns,
      );
    });
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
      if (_showQuad) _corners = seen.corners;

      // **Le nom prend le relais quand l'illustration renonce.** Mesuré, une
      // carte tenue à la main avec des reflets reste à 14 ou 19 bits de sa
      // propre référence — au-delà du seuil de confiance — même avec un cadrage
      // parfait : l'empreinte seule ne la retrouvera jamais. Le nom, lui, se lit
      // malgré les reflets. On ne le demande que lorsqu'une carte est là et que
      // l'index ne conclut pas, ce qui évite de payer une lecture pour rien.
      if (seen.accepted == null &&
          seen.located &&
          seen.outcome != FrameOutcome.confident) {
        _peutEtreLire(image, seen);
      }

      final accepted = seen.accepted;
      if (accepted != null) {
        _basket.add(accepted);
        unawaited(_resolve(accepted, seen.acceptedPrint ?? _editions[accepted]));
        diagnose('live_accepted', {
          'oracle_id': accepted,
          'print_id': seen.acceptedPrint,
          // L'empreinte relevée permet de rejouer la recherche au poste, contre
          // l'index complet : c'est elle qui sépare un quadrilatère faux d'un
          // seuil trop permissif.
          'art_hash': seen.probe,
          'gabarit': seen.hypothesis,
          'cadre': seen.window,
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
          'art_hash': seen.probe,
          'gabarit': seen.hypothesis,
          'cadre': seen.window,
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
  /// Lance une lecture de texte si le moment s'y prête.
  ///
  /// **Les octets sont copiés.** Le tampon d'une image de flux est réutilisé dès
  /// que la fonction rend la main ; le lire plus tard reviendrait à lire une
  /// autre image, ou une image à moitié réécrite.
  void _peutEtreLire(CameraImage image, LiveObservation seen) {
    if (_reading) return;
    final maintenant = DateTime.now();
    if (maintenant.difference(_lastRead) < _delaiEntreLectures) return;
    _reading = true;
    _lastRead = maintenant;
    final plan = image.planes.first;
    unawaited(
      _lireLeNom(
        Uint8List.fromList(plan.bytes),
        width: image.width,
        height: image.height,
        bytesPerRow: plan.bytesPerRow,
        probe: seen.probe,
      ).whenComplete(() => _reading = false),
    );
  }

  /// Lit le nom sur l'image, retrouve la carte, choisit son édition.
  ///
  /// **L'empreinte ne sert plus à identifier la carte mais à choisir entre ses
  /// éditions** — et c'est là qu'elle est bonne. Une empreinte trop abîmée pour
  /// être reconnue parmi 32 808 illustrations départage sans peine les deux ou
  /// trois d'une carte connue : les rivales y sont à trente bits.
  Future<void> _lireLeNom(
    Uint8List octets, {
    required int width,
    required int height,
    required int bytesPerRow,
    String? probe,
  }) async {
    final scanner = _scanner;
    if (scanner == null) return;
    try {
      final lignes = await _reader.readFrame(
        octets,
        width: width,
        height: height,
        rotationDegrees: scanner.uprightTurns * 90,
        bytesPerRow: bytesPerRow,
      );
      // **Journaliser avant de renoncer.** Une première version sortait
      // silencieusement quand rien n'était lu : à l'écran, ni succès ni échec,
      // et rien pour distinguer « la lecture n'a pas été lancée » de « elle n'a
      // rien trouvé ». C'est le genre de silence qui coûte un aller-retour avec
      // l'appareil.
      final noms = lignes.isEmpty
          ? const <String>[]
          : cardNameCandidates(lignes);
      diagnose('live_ocr', {
        'lignes': lignes.length,
        'noms': noms.take(2).toList(),
        'texte': lignes.take(2).map((l) => l.text).toList(),
      });
      if (lignes.isEmpty || noms.isEmpty || !mounted) return;

      final game = ref.read(selectedGameProvider);
      final trouvees = await ref
          .read(cardRepositoryProvider)
          .searchMany(noms, game: game);
      if (!mounted) return;
      if (trouvees.isEmpty) {
        diagnose('live_ocr_sans_carte', {'noms': noms.take(2).toList()});
        return;
      }

      // Le premier candidat lu qui existe au catalogue : `cardNameCandidates`
      // les rend déjà par ordre de plausibilité.
      final hit = noms
          .map((n) => trouvees[n])
          .whereType<CardHit>()
          .firstOrNull;
      if (hit == null) return;

      final index = _index;
      final edition = (probe == null || index == null)
          ? null
          : index.searchWithin({hit.oracleId}, ArtHash.fromHex(probe));

      diagnose('live_nom', {
        'lu': noms.first,
        'oracle_id': hit.oracleId,
        'print_id': edition?.printId,
        'distance': edition?.distance,
      });

      if (!mounted) return;
      // **Le nom entre dans le même décompte que l'illustration.** L'ajouter
      // directement au panier faisait dix-neuf exemplaires pour une carte : la
      // lecture aboutit toutes les neuf dixièmes de seconde, et rien ne disait
      // qu'il s'agissait de la même. Le suivi temporel, lui, sait déjà qu'une
      // carte reste devant l'objectif.
      setState(() => _known[hit.oracleId] = hit);
      scanner.noteName(hit.oracleId);
      if (edition != null) _editions[hit.oracleId] = edition.printId;
    } on Object catch (erreur) {
      // Une lecture qui échoue laisse l'illustration continuer son travail :
      // c'est un renfort, jamais un passage obligé.
      diagnose('live_nom_echec', {'erreur': '$erreur'});
    }
  }

  /// Entre ou sort du réglage de la zone.
  ///
  /// **En sortir enregistre.** Un réglage qu'il faudrait valider ailleurs se
  /// perdrait au premier retour en arrière, et l'utilisateur recommencerait.
  Future<void> _basculerReglage() async {
    final voulu = !_reglageZone;
    setState(() => _reglageZone = voulu);
    if (voulu) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_clefZone, [
      '${_region.left}',
      '${_region.top}',
      '${_region.right}',
      '${_region.bottom}',
    ]);
  }

  /// Prend en compte la zone que le doigt vient de dessiner.
  ///
  /// **Le scanner est refait, pas modifié.** Sa zone est fixée à la
  /// construction : elle décide de ce que la détection lit, et la changer en
  /// cours de route laisserait un suivi de quadrilatère qui décrit un champ
  /// qui n'existe plus.
  void _zoneChangee(ScanRegion zone) {
    // Le jeu et l'orientation sont des champs de l'écran, et non des propriétés
    // relues sur le scanner : celui-ci peut ne pas exister encore, l'index
    // arrivant après la caméra. La zone se règle alors quand même.
    _region = zone;
    if (_scanner == null) {
      setState(() {});
      return;
    }
    _armerLeScanner();
  }

  /// Montre ou masque le cadre, et retient le choix.
  Future<void> _basculerCadre() async {
    final voulu = !_showQuad;
    setState(() {
      _showQuad = voulu;
      // Sans cela, le dernier cadre resterait figé à l'écran après extinction.
      if (!voulu) _corners = null;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_clefApercuCadre, voulu);
  }

  /// Ce que le relevé montre à l'écran, sur un build de mesure.
  ///
  /// **Les acceptations d'abord, et séparément.** Elles sont rares — quelques-
  /// unes par passe — et noyées dans les dizaines de lignes émises par image ;
  /// or ce sont elles qui portent la carte retenue et la distance qui l'a fait
  /// retenir. Les laisser dans l'ordre chronologique revenait à ne jamais les
  /// voir : la première capture d'écran n'en contenait aucune.
  String _releve() {
    String court(String ligne) =>
        ligne.replaceAll('DHDIAG ', '').replaceAll('"event":', '');
    final retenues = recentDiagnostics
        .where((l) => l.contains('live_accepted'))
        .take(4)
        .map(court);
    final images = recentDiagnostics
        .where((l) => !l.contains('live_accepted'))
        .take(5)
        .map(court);
    return ['RETENUES :', ...retenues, 'IMAGES :', ...images].join('\n');
  }

  /// **Une seule édition se remplit d'office** : la désigner n'apporte rien que
  /// la carte ne porte déjà, et demander le geste reviendrait à faire ouvrir
  /// une liste d'un seul élément quinze fois par booster. Garde-fou §IV.8
  /// intact — c'est l'édition qui se déduit, jamais la carte.
  Future<void> _resolve(String oracleId, [String? printId]) async {
    if (_known.containsKey(oracleId)) return;
    try {
      // **L'impression reconnue, et non n'importe laquelle.** Une carte Magic
      // sur quatre porte plusieurs illustrations ; sans ce second argument, le
      // catalogue rend celle de la plus ancienne impression anglaise et la
      // vignette montre une autre version que celle qu'on tient.
      final hits = await ref
          .read(cardRepositoryProvider)
          .byOracleIds([oracleId], prints: printId == null ? const [] : [printId]);
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
            // **Le viseur prend les deux tiers, et non 220 pixels.** Une
            // hauteur fixe donnait un quart de l'écran sur ce téléphone, la
            // moitié restait juste — jugé sur l'appareil, deux fois. Une part
            // de l'espace disponible tient la promesse quelle que soit la
            // dalle, là où un nombre de pixels ne vaut que pour un modèle.
            //
            // Le tiers restant suffit aux cartes parce qu'elles y tiennent en
            // entier : c'est ce qui a fixé leur densité, quatre par ligne et
            // non trois. Voir [scanGridColumns].
            Expanded(
              flex: 2,
              child: SizedBox(
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
                      // **Régler la zone se fait sur l'aperçu, pas ailleurs.**
                      // On désigne un endroit du champ ; le faire dans un écran
                      // séparé obligerait à se souvenir de ce qu'on vise.
                      if (_reglageZone)
                        Positioned.fill(
                          child: ScanRegionEditor(
                            region: _region,
                            quarterTurns: _scanner?.uprightTurns ?? 0,
                            onChanged: _zoneChangee,
                          ),
                        ),
                      // Le cadre retenu, quand l'utilisateur le demande : il
                      // rend visible ce que l'application regarde, et c'est ce
                      // qui explique une carte non reconnue.
                      if (_showQuad)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: QuadOverlay(
                              corners: _corners,
                              quarterTurns: _scanner?.uprightTurns ?? 0,
                            ),
                          ),
                        ),
                      // **Le journal, à même l'écran, sur un build de mesure.**
                      // C'est le seul chemin qui ramène un relevé d'un appareil :
                      // `logcat` ne reçoit rien hors du mode debug, et depuis
                      // Android 10 un fichier ne peut plus être écrit là où
                      // `adb` sait le lire. Une capture d'écran, elle, marche
                      // toujours. Absent d'un build ordinaire, où
                      // `diagnosticsEnabled` est une constante fausse.
                      if (diagnosticsEnabled)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: 0.72),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Text(
                                _releve(),
                                style: const TextStyle(
                                  color: Colors.greenAccent,
                                  fontSize: 7,
                                  height: 1.25,
                                ),
                              ),
                            ),
                          ),
                        ),
                      // **Un bouton discret plutôt qu'un réglage enfoui.** Le
                      // tracé sert quand quelque chose cloche ; il faut pouvoir
                      // l'allumer là où l'on regarde, sans quitter l'écran ni
                      // reprendre la passe.
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                iconSize: 20,
                                tooltip: _reglageZone
                                    ? 'Terminer le réglage de la zone'
                                    : 'Choisir où sont posées les cartes',
                                icon: Icon(
                                  _reglageZone
                                      ? Icons.check_circle_outline
                                      : Icons.filter_center_focus,
                                  color: _reglageZone
                                      ? Colors.greenAccent
                                      : (_region.isWhole
                                            ? Colors.white54
                                            : Colors.white),
                                ),
                                onPressed: _basculerReglage,
                              ),
                              IconButton(
                            iconSize: 20,
                            tooltip: _showQuad
                                ? 'Masquer le cadre détecté'
                                : 'Montrer le cadre détecté',
                            icon: Icon(
                              _showQuad
                                  ? Icons.crop_free
                                  : Icons.crop_free_outlined,
                              color: _showQuad
                                  ? Colors.greenAccent
                                  : Colors.white54,
                            ),
                            onPressed: _basculerCadre,
                              ),
                            ],
                          ),
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
                    // L'appui long agrandit, comme partout ailleurs.
                    onEnlarge: (id) => showCardImage(
                      context,
                      imageUrl: _sole[id]?.printing.artCropUrl ??
                          _known[id]?.artUrl,
                      title: _known[id]?.matchedName ?? 'Carte reconnue',
                    ),
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
