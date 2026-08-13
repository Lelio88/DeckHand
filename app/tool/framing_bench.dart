/// Banc de cadrage, côté Dart : que coûte une photo prise à main levée ?
///
/// **Jumeau de `api/app/measure/framing_bench.py`, et pourquoi il en faut un.**
/// Le banc Python mesure la détection de bords du jumeau Python. Or le code qui
/// tourne sur le téléphone est celui-ci, et c'est lui qu'il faut départager
/// quand plusieurs approches de détection sont en concurrence. Porter quatre
/// approches vers Python multiplierait les occasions de se tromper ; porter le
/// banc une fois ne les multiplie pas.
///
/// **Les photos sont synthétiques, et c'est un choix.** Une photo réelle porte
/// sa vérité terrain dans la tête de celui qui l'a prise ; une photo composée la
/// porte dans ses paramètres. On sait exactement de combien la carte a été
/// décalée, tournée, agrandie — donc à quel écart correspond quel échec. C'est
/// le seul moyen de mesurer une détection sans posséder mille cartes.
///
/// **Ce que ce banc ne prouve pas.** Une photo composée n'a ni flou de bougé, ni
/// mise au point ratée, ni reflet sur un protège-carte ; sa table est un grain
/// synthétique traversé d'un dégradé, pas un plateau à lames de bois. Un gain
/// mesuré ici est une condition nécessaire, jamais suffisante : la seule preuve
/// reste une carte de papier devant l'objectif. Le banc sert à **éliminer** ce
/// qui échoue et à comparer ce qui passe, pas à décréter qu'une approche marche.
///
/// **Le tirage vient de la base**, exporté par
/// `python -m app.measure.export_framing_set`. Même filtre et même ordre que le
/// banc Python : deux bancs qui mesureraient des cartes différentes ne seraient
/// pas comparables.
///
/// Les images sont mises en cache sur le disque. Scryfall demande un débit bas
/// et un `User-Agent` descriptif (`CLAUDE.md` §IV.4) : le cache fait qu'un banc
/// rejoué n'émet aucune requête, ce qui compte quand on le rejoue une fois par
/// approche.
///
/// Usage :
/// ```
/// dart run tool/framing_bench.dart              # détection des bords
/// dart run tool/framing_bench.dart --centered   # cadrage centré, pour comparer
/// dart run tool/framing_bench.dart --cards 12   # échantillon plus petit
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_framing.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:image/image.dart' as img;

import 'synthetic_photo.dart';

/// Seuil de confiance du scan, en bits. Au-delà, la carte est « perdue » : ce
/// n'est pas une erreur silencieuse — l'application dit son doute —, mais elle
/// ne reconnaît rien.
const int confidence = 12;

Future<void> main(List<String> args) async {
  final centered = args.contains('--centered');
  final limit = int.tryParse(_option(args, '--cards') ?? '') ?? 40;

  final root = File.fromUri(Platform.script).parent;
  final setFile = File('${root.path}/${_option(args, '--set') ?? 'framing_set.json'}');
  if (!setFile.existsSync()) {
    stderr.writeln(
      'tirage absent : ${setFile.path}\n'
      'lancer d\'abord : cd api && python -m app.measure.export_framing_set',
    );
    exitCode = 66;
    return;
  }

  final entries = (jsonDecode(setFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>()
      .take(limit)
      .toList();

  final cache = Directory('${root.path}/.framing_cache')
    ..createSync(recursive: true);

  stdout.writeln(
    'Banc de cadrage — ${entries.length} cartes × ${regimes.length} régimes — '
    '${centered ? 'cadrage centré' : 'détection des bords'}',
  );

  final distances = {for (final shot in regimes) shot.name: <int>[]};
  var gaveUp = 0;
  var skipped = 0;

  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final card = await _cardImage(entry, cache);
    if (card == null) {
      skipped++;
      continue;
    }
    final expected = ArtHash.fromHex(entry['hash'] as String);
    // **Le tirage dit ce qu'il contient.** Le gabarit et l'orientation se
    // déduisent du jeu et de la disposition, au lieu d'être supposés : c'est ce
    // qui permet de mesurer les cartes couchées, que le banc ignorait.
    final frame = _frameOf(entry);
    final couchee = frame == CardFrame.riftboundWide;
    final game = entry['game'] as String? ?? 'magic';
    // La carte synthétique est découpée aux proportions du jeu tiré, et non à
    // celles de Magic : composer une carte au mauvais format mesurerait la
    // détection sur un objet qui n'existe pas.
    final aspect = cardAspectFor(game);

    for (final shot in regimes) {
      // Une graine par (carte, régime) : le grain de la table et le tirage sont
      // ainsi identiques d'une exécution à l'autre, donc d'une approche à
      // l'autre. Sans cela, deux mesures différeraient par leur bruit.
      final photo = compose(
        card,
        shot,
        math.Random(20260810 + i * 17),
        couchee: couchee,
        aspect: aspect,
      );
      final quad = centered ? null : findCard(photo, game: game);
      final img.Image art;
      if (quad == null) {
        if (!centered) gaveUp++;
        art = cropArt(cropToCardFrame(photo, game: game), frame);
      } else {
        art = sampleArt(photo, quad, frame.box);
      }
      distances[shot.name]!.add(_hamming(computeArtHash(art), expected));
    }
    stdout.write('  ${i + 1}/${entries.length}\r');
  }
  stdout.write('${' ' * 24}\r');

  _report(distances, gaveUp, skipped);
}

/// Distance de Hamming entre deux empreintes.
int _hamming(ArtHash a, ArtHash b) {
  var total = 0;
  for (var i = 0; i < a.bytes.length; i++) {
    var x = a.bytes[i] ^ b.bytes[i];
    while (x != 0) {
      total += x & 1;
      x >>= 1;
    }
  }
  return total;
}

/// Carte entière, depuis le cache disque ou depuis Scryfall.
Future<img.Image?> _cardImage(
  Map<String, dynamic> entry,
  Directory cache,
) async {
  final file = File('${cache.path}/${entry['id']}.jpg');
  if (!file.existsSync()) {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(entry['url'] as String));
      // Descriptif, comme le garde-fou l'exige : une source doit pouvoir
      // identifier qui l'interroge et pourquoi.
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'DeckHand/0.1 (https://github.com/Lelio88/DeckHand)',
      );
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = await response.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      file.writeAsBytesSync(bytes);
      // Débit bas : le banc n'a aucune raison d'être pressé, et la source en a
      // de nous limiter.
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }
  try {
    return img.decodeImage(file.readAsBytesSync());
  } on Object {
    return null;
  }
}

/// Fond de table texturé.
///
/// Un aplat uni rendrait la détection triviale et le banc menteur. Le grain
/// met en difficulté les approches par région ; le dégradé diagonal imite
/// l'éclairage inégal, qui est l'écueil mesuré sur une vraie photo — un coin de
/// table plus sombre passe sous le seuil de carton et fusionne avec la carte.
void _report(Map<String, List<int>> distances, int gaveUp, int skipped) {
  stdout.writeln('\nSeuil de confiance : $confidence bits');
  if (gaveUp > 0) {
    stdout.writeln(
      'détections abandonnées (repli sur le cadrage centré) : $gaveUp',
    );
  }
  if (skipped > 0) {
    stdout.writeln('cartes non téléchargées : $skipped');
  }
  stdout.writeln('');
  stdout.writeln(
    '${'régime'.padRight(24)}${'médiane'.padLeft(8)}'
    '${'reconnues'.padLeft(12)}${'perdues'.padLeft(10)}',
  );
  for (final shot in regimes) {
    final values = [...distances[shot.name]!]..sort();
    if (values.isEmpty) continue;
    final median = values[values.length ~/ 2];
    final found = values.where((v) => v <= confidence).length;
    stdout.writeln(
      '${shot.name.padRight(24)}${median.toString().padLeft(8)}'
      '${'$found/${values.length}'.padLeft(12)}'
      '${(values.length - found).toString().padLeft(10)}',
    );
  }
}

/// Gabarit à appliquer, d'après ce que le tirage déclare.
///
/// Le banc mesurait Magic seul et prenait `modern` pour acquis. Un tirage porte
/// désormais son jeu et sa disposition, ce qui est la seule façon de mesurer un
/// gabarit qui n'est pas celui par défaut — à commencer par les cartes
/// couchées, dont le cadre est mesuré depuis longtemps sans avoir jamais servi.
/// Le cadre qu'annonce une entrée du tirage.
///
/// **Se tromper ici ne se voit pas dans les nombres.** Un cadre d'un autre jeu
/// découpe de travers et rend des distances énormes, qu'on imputerait au
/// gabarit mesuré plutôt qu'au banc. C'est pourquoi le tirage porte son jeu et
/// sa disposition plutôt que de les laisser deviner.
CardFrame _frameOf(Map<String, dynamic> entry) {
  final game = entry['game'] as String? ?? 'magic';
  final layout = entry['layout'] as String? ?? 'normal';
  return switch (game) {
    'riftbound' =>
      layout == 'landscape' ? CardFrame.riftboundWide : CardFrame.riftbound,
    // `layout` porte ici le `frameType` de la source, et « pendulum » y figure
    // pour les 390 cartes dont l'illustration déborde — et pour elles seules.
    'yugioh' =>
      layout.contains('pendulum') ? CardFrame.yugiohPendulum : CardFrame.yugioh,
    _ => CardFrame.modern,
  };
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
