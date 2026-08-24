/// Ce que la production découpe, et où — pour que la vérité puisse l'y comparer.
///
/// **Le constat qui motive ce banc.** Passée sur les trente-neuf photos du banc
/// réel, la chaîne détoure une carte dans 100 % des images et n'en identifie
/// que 5 %. « Détourée » ne dit pourtant pas « juste » : un quadrilatère a été
/// trouvé, rien de plus. Deux causes restent alors possibles, et le CLAUDE.md
/// les porte toutes les deux sans les avoir départagées — le cadre est faux
/// (l'empreinte décroche au-delà de 3 % d'écart), ou la carte elle-même ne rend
/// plus son empreinte (reflets, angle, plancher mesuré à 14 bits).
///
/// **Ce banc ne tranche pas ; il fournit une moitié de la mesure.** Il exécute
/// `largestPlausible([findCardByEdges, findCard])` et `artHashCandidatesInQuad`
/// — **le code de production, sans une ligne de portage** — puis écrit, pour
/// chaque photo : le quadrilatère retenu, l'empreinte de chaque hypothèse, et
/// surtout **les quatre coins de la fenêtre réellement lue** dans le repère de
/// la photo. C'est ce dernier point qui rend la comparaison possible : la
/// vérité, elle, est une fenêtre située par corrélation (`app.measure`
/// `.plafond_empreinte`), et deux fenêtres exprimées dans le même repère se
/// soustraient.
///
/// **Pourquoi la géométrie sort d'ici et non de Python.** La fenêtre lue n'est
/// pas le gabarit : c'est le gabarit **interpolé entre les quatre coins** du
/// quadrilatère, exactement comme `sampleArt` le parcourt. La recalculer côté
/// Python serait un troisième jumeau sur le code le moins tolérant à la dérive
/// du projet. Elle est donc dérivée ici, par la même arithmétique.
///
/// **Aucun repli sur le cadre centré**, comme `vod.dart` : un repli rendrait une
/// fenêtre pour une photo sans carte, et l'écart mesuré n'aurait plus de sens.
///
/// Usage :
///
///     cd app && dart run tool/plafond.dart <dossier> --game magic --out <fichier.json>
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:image/image.dart' as img;

import 'index_download.dart';

/// Où tombe le couple `(u, v)` de la carte dans la photo.
///
/// **La même arithmétique que `sampleArt`**, à la lettre : interpolation
/// bilinéaire des quatre coins. Elle est reprise ici plutôt qu'appelée parce que
/// `sampleArt` rend des pixels, pas des coordonnées — et c'est de coordonnées
/// qu'on a besoin pour comparer deux cadrages.
List<double> _mapUV(CardQuad quad, double u, double v) => [
  (1 - u) * (1 - v) * quad.topLeft.x +
      u * (1 - v) * quad.topRight.x +
      u * v * quad.bottomRight.x +
      (1 - u) * v * quad.bottomLeft.x,
  (1 - u) * (1 - v) * quad.topLeft.y +
      u * (1 - v) * quad.topRight.y +
      u * v * quad.bottomRight.y +
      (1 - u) * v * quad.bottomLeft.y,
];

/// Les quatre coins de la fenêtre d'illustration, dans le repère de la photo.
///
/// Ordre : haut-gauche, haut-droit, bas-droit, bas-gauche **de la fenêtre**,
/// c'est-à-dire tels que l'illustration s'y lit à l'endroit.
List<List<double>> _fenetre(CardQuad quad, ArtBox box) => [
  _mapUV(quad, box.left, box.top),
  _mapUV(quad, box.right, box.top),
  _mapUV(quad, box.right, box.bottom),
  _mapUV(quad, box.left, box.bottom),
];

List<List<double>> _coins(CardQuad q) => [
  [q.topLeft.x, q.topLeft.y],
  [q.topRight.x, q.topRight.y],
  [q.bottomRight.x, q.bottomRight.y],
  [q.bottomLeft.x, q.bottomLeft.y],
];

String? _option(List<String> args, String nom) {
  final i = args.indexOf(nom);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<void> main(List<String> args) async {
  final cible = args.isEmpty || args.first.startsWith('--') ? null : args.first;
  if (cible == null) {
    stderr.writeln(
      'usage : dart run tool/plafond.dart <dossier> [--game magic] '
      '[--out releve.json]',
    );
    exit(64);
  }

  final game = _option(args, '--game') ?? 'magic';
  final sortie = _option(args, '--out') ?? 'tool/.cache/plafond.json';

  final index = await chargerIndex(game, forcer: args.contains('--forcer'));

  final fichiers =
      Directory(cible)
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

  print('${fichiers.length} photos à passer dans la chaîne de production.\n');

  final releve = <Map<String, Object?>>[];
  final chrono = Stopwatch()..start();

  for (final fichier in fichiers) {
    final nom = fichier.uri.pathSegments.last;
    final scene = img.decodeImage(await fichier.readAsBytes());
    if (scene == null) {
      print('$nom : illisible');
      continue;
    }

    final quad = largestPlausible([
      findCardByEdges(scene, game: game),
      findCard(scene, game: game),
    ], width: scene.width, height: scene.height);

    if (quad == null) {
      releve.add({
        'file': nom,
        'width': scene.width,
        'height': scene.height,
        'located': false,
      });
      print('$nom : aucun quadrilatère');
      continue;
    }

    final candidates = artHashCandidatesInQuad(scene, quad, game: game);
    final hypotheses = <Map<String, Object?>>[];
    for (final entree in candidates.entries) {
      final tourne = quad.quarterTurned(entree.key.quarterTurns);
      hypotheses.add({
        'frame': entree.key.frame.name,
        'turns': entree.key.quarterTurns,
        'hash': entree.value.toHex(),
        'window': _fenetre(tourne, entree.key.frame.box),
      });
    }

    final outcome = index.searchAny(candidates, limit: 2);
    final best = outcome.result.best;

    // **Le contrefactuel de l'orientation, mesuré et non supposé.**
    //
    // `artHashCandidatesInQuad` n'essaie qu'un seul sens pour un gabarit droit,
    // et le commentaire qui l'entoure dit pourquoi : une carte debout ne se
    // présente pas couchée, et chaque hypothèse de plus est un tirage de plus
    // dans l'index — environ une chance sur cent de passer les deux garde-fous
    // sur du bruit. Le banc réel contredit la prémisse (un tiers des photos
    // montrent un carton couché) sans annuler le coût. On mesure donc les deux
    // faces : ce que les quatre quarts de tour feraient gagner, et ce qu'ils
    // feraient inventer.
    //
    // **Rien de tout ceci ne change la production** : ces empreintes sont
    // publiées à part, sous `orientations`, et le verdict de production
    // ci-dessus reste celui du code tel qu'il tourne.
    final toutes = <ArtHypothesis, ArtHash>{};
    for (final frame in CardFrame.values) {
      if (frame.game != game) continue;
      for (var t = 0; t < 4; t++) {
        toutes[(frame: frame, quarterTurns: t)] = computeArtHash(
          sampleArt(scene, quad.quarterTurned(t), frame.box),
        );
      }
    }
    final aveugle = index.searchAny(toutes, limit: 2);
    final meilleurAveugle = aveugle.result.best;

    releve.add({
      'file': nom,
      'width': scene.width,
      'height': scene.height,
      'located': true,
      'quad': _coins(quad),
      'aspect': quad.aspect,
      'coverage': quad.area / (scene.width * scene.height),
      'hypotheses': hypotheses,
      'verdict': best == null
          ? null
          : {
              'oracleId': best.oracleId,
              'printId': best.printId,
              'distance': best.distance,
              'margin': outcome.result.margin,
              'confident': outcome.result.isConfident,
              'frame': outcome.source?.frame.name,
              'turns': outcome.source?.quarterTurns,
            },
      'orientations': {
        'hypotheses': [
          for (final e in toutes.entries)
            {
              'frame': e.key.frame.name,
              'turns': e.key.quarterTurns,
              'hash': e.value.toHex(),
              'window': _fenetre(
                quad.quarterTurned(e.key.quarterTurns),
                e.key.frame.box,
              ),
            },
        ],
        'verdict': meilleurAveugle == null
            ? null
            : {
                'oracleId': meilleurAveugle.oracleId,
                'printId': meilleurAveugle.printId,
                'distance': meilleurAveugle.distance,
                'margin': aveugle.result.margin,
                'confident': aveugle.result.isConfident,
                'frame': aveugle.source?.frame.name,
                'turns': aveugle.source?.quarterTurns,
              },
      },
    });

    final verdict = best == null
        ? 'index muet'
        : '${best.distance} bits, marge ${outcome.result.margin}'
              '${outcome.result.isConfident ? ', SANS RÉSERVE' : ''}';
    print(
      '$nom : rapport ${quad.aspect.toStringAsFixed(3)}, '
      'couverture ${(100 * quad.area / (scene.width * scene.height)).round()} % '
      '— $verdict',
    );
  }

  File(sortie)
    ..createSync(recursive: true)
    ..writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'game': game,
        'source': cible,
        'index': index.length,
        'photos': releve,
      }),
    );

  final detourees = releve.where((r) => r['located'] == true).length;
  final sures = releve
      .where((r) => (r['verdict'] as Map?)?['confident'] == true)
      .length;
  print(
    '\n${releve.length} photos en '
    '${(chrono.elapsedMilliseconds / 1000).toStringAsFixed(1)} s — '
    '$detourees détourée(s), $sures identifiée(s) sans réserve.',
  );
  print('relevé écrit dans $sortie');
}
