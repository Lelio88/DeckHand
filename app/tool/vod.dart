/// Tirer les cartes ouvertes d'une VOD de *pack opening* (#32).
///
/// **Où ce banc tourne, et pourquoi ce n'est pas là où l'issue le prévoyait.**
/// L'issue plaçait ce travail côté `api/`, au motif que « le jumeau Python du
/// pipeline existe déjà ». Il n'existe plus pour la partie qui compte : la
/// détection qui fonctionne est celle par droites (`card_edges.dart`, 1 063
/// lignes de géométrie de Hough), et `api/app/vision/card_bounds.py` est resté
/// sur le seuillage par clarté — l'approche qui trouvait quatre cartes sur
/// trente-neuf. La porter créerait un troisième jumeau à tenir en phase, sur le
/// code le moins tolérant à la dérive du projet.
///
/// Le seul argument restant pour Python était FFmpeg, qui est un binaire :
/// `Process.run` l'appelle aussi bien. Ce banc est donc en Dart, et il exécute
/// **exactement le code de production** — `findCardByEdges`, `findCard`,
/// `largestPlausible`, `artHashCandidatesInQuad` — sans une ligne de portage.
///
/// **Une différence assumée avec le mode photo.** Celui-ci retombe sur un cadre
/// centré quand aucun quadrilatère n'est trouvé : l'utilisateur a visé une
/// carte, on suppose qu'elle remplit l'image. Une VOD n'a pas cette excuse — un
/// commentaire face caméra donnerait dix mille cadres centrés, donc dix mille
/// empreintes prélevées sur un visage. **Pas de quadrilatère, pas de carte.**
///
/// **Ce que la vidéo offre et que le direct n'a pas : la répétition.** Une carte
/// reste montrée une à deux secondes, donc sur plusieurs images échantillonnées.
/// Exiger un accord entre images consécutives est un garde-fou gratuit : une
/// empreinte fausse tirée d'un décor mouvant ne se répète pas à l'identique.
///
/// Usage :
///
///     cd app && dart run tool/vod.dart <video> --game magic
///     cd app && dart run tool/vod.dart <video> --fps 2 --accord 3
///     cd app && dart run tool/vod.dart <dossier-d-images> --images
///
/// Le second mode lit un dossier d'images déjà extraites, ce qui permet
/// d'éprouver la chaîne sans vidéo — notamment le critère « zéro carte ».
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:image/image.dart' as img;

import 'index_download.dart';

/// Images extraites par seconde de vidéo.
///
/// **Une hypothèse, pas une mesure**, et l'issue le dit : elle vient de la durée
/// pendant laquelle une carte reste montrée — une à deux secondes. Elle ne sera
/// vérifiée que sur une vraie VOD, en comparant ce que rendent 1, 2 et 4 images
/// par seconde sur le même extrait.
const double defaultFps = 1;

/// Échantillons consécutifs devant désigner la même carte pour l'annoncer.
///
/// **Deux est un plancher, pas un réglage établi.** Un seul échantillon
/// annoncerait chaque empreinte fortuite ; le bon nombre se mesure sur une VOD
/// réelle, comme `CardTracker.minFrames` l'a été sur l'appareil.
const int defaultAccord = 2;

/// Largeur d'extraction. La reconnaissance tolère jusqu'à 200 px de carte
/// (mesuré par `flux_bench`) ; 1280 laisse la marge d'une carte tenue au tiers
/// du cadre, sans payer un capteur entier par image.
const int extractWidth = 1280;

/// Longueur d'un morceau de vidéo traité d'un coup, en secondes.
///
/// **Pour borner le disque, pas le calcul.** Trois heures à une image par
/// seconde font 10 800 fichiers ; les sortir tous d'abord occuperait près d'un
/// gigaoctet. Un morceau de dix minutes en occupe une soixantaine de mégaoctets,
/// effacés au fur et à mesure.
const int chunkSeconds = 600;

/// Une carte retenue, et quand elle a été vue.
class Vue {
  Vue({
    required this.oracleId,
    required this.printId,
    required this.debut,
    required this.distance,
  });

  final String oracleId;

  /// L'impression retenue — celle de l'image la plus nette de la série.
  /// Mutable : une image ultérieure peut mieux voir la carte que la première.
  String printId;

  /// Seconde de la vidéo où la série a commencé.
  final double debut;
  double fin = 0;

  /// Échantillons de la série.
  int echantillons = 1;

  /// La meilleure distance vue sur la série — celle de l'image la plus nette.
  int distance;
}

/// Ce qu'une image a donné.
///
/// [located] dit si un quadrilatère a été trouvé, indépendamment de ce que
/// l'index en a fait. **Les deux ne se confondent pas** : une carte peut être
/// parfaitement détourée et rester à quatorze bits de sa référence — mesuré, le
/// plancher d'une carte tenue à la main. Compter les identifications seules
/// ferait imputer à la détection un échec de l'empreinte, et inversement.
typedef Verdict = ({
  bool located,
  String? oracleId,
  String? printId,
  int distance,
});

const Verdict _rien = (
  located: false,
  oracleId: null,
  printId: null,
  distance: -1,
);
const Verdict _vueSansSuite = (
  located: true,
  oracleId: null,
  printId: null,
  distance: -1,
);

/// La reconnaissance de production, moins le repli sur le cadre centré.
Verdict _reconnaitre(img.Image scene, ArtHashIndex index, String game) {
  final quad = largestPlausible([
    findCardByEdges(scene, game: game),
    findCard(scene, game: game),
  ], width: scene.width, height: scene.height);

  // **Pas de quadrilatère, pas de carte.** Voir le commentaire de tête : c'est
  // la seule divergence avec le mode photo, et elle est la raison d'être du
  // critère « zéro carte sur un extrait sans carte ».
  if (quad == null) return _rien;

  final candidates = artHashCandidatesInQuad(scene, quad, game: game);
  if (candidates.values.isEmpty) return _vueSansSuite;

  final outcome = index.searchAny(candidates, limit: 2);
  if (!outcome.result.isConfident) return _vueSansSuite;

  final best = outcome.result.best!;
  return (
    located: true,
    oracleId: best.oracleId,
    printId: best.printId,
    distance: best.distance,
  );
}

/// Accumule les verdicts et n'en retient que les séries assez longues.
class Serie {
  Serie({required this.accord});

  final int accord;
  final List<Vue> retenues = [];

  Vue? _encours;

  void ajouter(Verdict verdict, double seconde) {
    final oracle = verdict.oracleId;
    if (oracle == null) {
      // Une image muette **ne rompt pas** la série : une main qui passe devant
      // la carte, un reflet, une image floue entre deux nettes. Ce qui la rompt
      // est une AUTRE carte, ou la fin de l'analyse.
      return;
    }

    final encours = _encours;
    if (encours != null && encours.oracleId == oracle) {
      encours
        ..echantillons += 1
        ..fin = seconde;
      if (verdict.distance < encours.distance) {
        encours
          ..distance = verdict.distance
          ..printId = verdict.printId ?? encours.printId;
      }
      return;
    }

    _clore();
    _encours = Vue(
      oracleId: oracle,
      printId: verdict.printId ?? '',
      debut: seconde,
      distance: verdict.distance,
    )..fin = seconde;
  }

  void _clore() {
    final encours = _encours;
    _encours = null;
    if (encours == null) return;
    if (encours.echantillons < accord) return;
    retenues.add(encours);
  }

  void terminer() => _clore();
}

String _temps(double secondes) {
  final t = secondes.round();
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final s = t % 60;
  return h > 0
      ? '${h}h${m.toString().padLeft(2, '0')}m${s.toString().padLeft(2, '0')}'
      : '${m}m${s.toString().padLeft(2, '0')}';
}

String? _option(List<String> args, String nom) {
  final i = args.indexOf(nom);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<double> _duree(String video) async {
  final r = await Process.run('ffprobe', [
    '-v',
    'error',
    '-show_entries',
    'format=duration',
    '-of',
    'default=noprint_wrappers=1:nokey=1',
    video,
  ]);
  if (r.exitCode != 0) {
    throw StateError('ffprobe a échoué : ${r.stderr}');
  }
  return double.parse((r.stdout as String).trim());
}

/// Extrait un morceau de vidéo en images, et rend leurs chemins triés.
Future<List<File>> _extraire(
  String video,
  Directory sortie,
  double debut,
  int duree,
  double fps,
) async {
  if (sortie.existsSync()) sortie.deleteSync(recursive: true);
  sortie.createSync(recursive: true);

  final r = await Process.run('ffmpeg', [
    '-v',
    'error',
    // `-ss` AVANT `-i` : ffmpeg saute alors par les images-clés au lieu de
    // décoder tout ce qui précède. Sur trois heures, la différence se compte en
    // dizaines de minutes.
    '-ss',
    debut.toStringAsFixed(3),
    '-i',
    video,
    '-t',
    '$duree',
    '-vf',
    'fps=$fps,scale=$extractWidth:-2',
    '-q:v',
    '3',
    '${sortie.path}${Platform.pathSeparator}%06d.jpg',
  ]);
  if (r.exitCode != 0) {
    throw StateError('ffmpeg a échoué : ${r.stderr}');
  }

  return sortie.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

Future<void> main(List<String> args) async {
  final cible = args.isEmpty || args.first.startsWith('--') ? null : args.first;
  if (cible == null) {
    stderr.writeln(
      'usage : dart run tool/vod.dart <video|dossier> [--game magic] '
      '[--fps 1] [--accord 2] [--images]',
    );
    exit(64);
  }

  final game = _option(args, '--game') ?? 'magic';
  final fps = double.parse(_option(args, '--fps') ?? '$defaultFps');
  final accord = int.parse(_option(args, '--accord') ?? '$defaultAccord');
  final surImages = args.contains('--images');

  final index = await chargerIndex(game, forcer: args.contains('--forcer'));
  final serie = Serie(accord: accord);
  final chrono = Stopwatch()..start();
  var images = 0;
  var detourees = 0;
  var identifiees = 0;

  if (surImages) {
    // **Le mode sans vidéo.** Il sert le critère qui compte le plus : passer un
    // dossier de photos de décor doit rendre zéro carte. Chaque image y vaut un
    // échantillon d'une seconde.
    final dossier = Directory(cible);
    final fichiers =
        dossier
            .listSync()
            .whereType<File>()
            .where(
              (f) => const [
                '.jpg',
                '.jpeg',
                '.png',
              ].any((e) => f.path.toLowerCase().endsWith(e)),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    print('${fichiers.length} images à passer.\n');
    for (var i = 0; i < fichiers.length; i++) {
      final scene = img.decodeImage(await fichiers[i].readAsBytes());
      if (scene == null) continue;
      final verdict = _reconnaitre(scene, index, game);
      if (verdict.located) detourees++;
      if (verdict.oracleId != null) identifiees++;
      serie.ajouter(verdict, i.toDouble());
      images++;
    }
  } else {
    final duree = await _duree(cible);
    print(
      'vidéo de ${_temps(duree)}, échantillonnée à $fps image(s) par seconde '
      '— ${(duree * fps).round()} images attendues.\n',
    );
    final scratch = Directory('tool/.cache/vod');
    for (var debut = 0.0; debut < duree; debut += chunkSeconds) {
      final fichiers = await _extraire(
        cible,
        scratch,
        debut,
        chunkSeconds,
        fps,
      );
      for (var i = 0; i < fichiers.length; i++) {
        final scene = img.decodeImage(await fichiers[i].readAsBytes());
        if (scene == null) continue;
        final verdict = _reconnaitre(scene, index, game);
        if (verdict.located) detourees++;
        if (verdict.oracleId != null) identifiees++;
        serie.ajouter(verdict, debut + i / fps);
        images++;
      }
      stdout.write(
        '\r  ${_temps(debut + chunkSeconds)} analysées, '
        '${serie.retenues.length} carte(s)…',
      );
    }
    stdout.writeln();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }

  serie.terminer();

  print('\n$images images en ${(chrono.elapsedMilliseconds / 1000)
      .toStringAsFixed(1)} s '
      '(${(chrono.elapsedMilliseconds / (images == 0 ? 1 : images))
          .toStringAsFixed(0)} ms l\'image)');
  // **Deux chiffres, jamais un.** Le premier juge la détection, le second
  // l'empreinte ; un seul ferait imputer à l'une l'échec de l'autre.
  print('$detourees image(s) ont détouré une carte '
      '(${images == 0 ? 0 : (100 * detourees / images).round()} %), '
      'dont $identifiees identifiée(s) sans réserve '
      '(${detourees == 0 ? 0 : (100 * identifiees / detourees).round()} %).');
  print('${serie.retenues.length} carte(s) retenue(s) '
      '(accord exigé : $accord échantillons).\n');

  for (final vue in serie.retenues) {
    print('${_temps(vue.debut).padLeft(8)}  '
        '${vue.oracleId}  '
        '${vue.echantillons} img  ${vue.distance} bits');
  }

  if (serie.retenues.isEmpty) {
    print('Aucune carte retenue.');
  }
}
