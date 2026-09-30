/// Rejoue un scan d'étalement complet — rattachement des lectures compris.
///
/// **Ce que les autres outils ne peuvent pas montrer.** `replay_spread` rejoue
/// le filtrage des lignes, `find_cards` la délimitation des cartes ; ni l'un ni
/// l'autre ne dit ce que l'utilisateur verra, puisque le résultat naît de leur
/// croisement. Cet outil rejoue la chaîne entière sur un journal et sa photo,
/// sans appareil ni reconstruction.
///
/// **Il appelle `attributeToCards`, la fonction même de l'application.** Une
/// version antérieure en recopiait la logique ; la copie aurait divergé en
/// silence au premier réglage, et la mesure aurait décrit un autre code que
/// celui qui tourne. Seul le décompte des exemplaires est refait ici, en trois
/// lignes, `ScanService` le gardant privé.
///
/// Le journal ne porte pas l'`oracle_id` : le nom trouvé tient lieu d'identité.
/// Deux langues d'une même carte comptent donc pour deux cartes ici, pour une
/// dans l'application.
///
/// Usage :
///   dart run tool/replay_full_spread.dart mesure.log photo.jpg [index-du-scan]
library;

import 'dart:convert';
import 'dart:io';

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/scan/domain/card_segmentation.dart';
import 'package:deckhand/src/features/scan/domain/spread_attribution.dart';
import 'package:deckhand/src/features/scan/domain/spread_names.dart';
import 'package:image/image.dart' as img;

/// Un scan tel que le journal le rapporte.
class _Scan {
  final lines = <ReadLine>[];

  /// Ligne lue → nom trouvé, pour les seules correspondances retenues.
  final matched = <String, String>{};

  /// L'étendue du texte lu, à laquelle ML Kit rapporte ses positions.
  double? width;
  double? height;
}

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'usage : dart run tool/replay_full_spread.dart <journal> <photo> [index]',
    );
    exit(64);
  }

  final scans = <_Scan>[];
  for (final raw in File(args[0]).readAsLinesSync()) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) continue;
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
    } on FormatException {
      continue;
    }
    switch (event['event']) {
      case 'spread_read':
        scans.add(
          _Scan()
            ..width = (event['w'] as num?)?.toDouble()
            ..height = (event['h'] as num?)?.toDouble(),
        );
      case 'spread_line' when scans.isNotEmpty:
        scans.last.lines.add(
          ReadLine(
            event['text'] as String,
            (event['top'] as num).toDouble(),
            (event['height'] as num).toDouble(),
            ((event['left'] as num?) ?? 0).toDouble(),
            ((event['width'] as num?) ?? 0).toDouble(),
          ),
        );
      case 'spread_match'
          when scans.isNotEmpty && (event['kept'] as bool? ?? false):
        scans.last.matched[event['read'] as String] =
            event['matched'] as String;
    }
  }
  if (scans.isEmpty) {
    stderr.writeln('Aucun scan dans ${args[0]}.');
    exit(65);
  }

  final index = args.length > 2 ? int.parse(args[2]) : scans.length - 1;
  final scan = scans[index < 0 ? scans.length + index : index];
  final candidates = spreadNameCandidates(scan.lines);
  final readings = [
    for (final c in candidates)
      if (scan.matched[c.text] case final name?) MatchedReading(name, c),
  ];

  final photo = img.decodeImage(File(args[1]).readAsBytesSync());
  if (photo == null) {
    stderr.writeln('Photo illisible : ${args[1]}');
    exit(66);
  }
  final cards = singleCards(findCards(photo));
  final r = attributeToCards(
    readings,
    cards,
    scaleX: (scan.width ?? photo.width) / photo.width,
    scaleY: (scan.height ?? photo.height) / photo.height,
    imageAspect: photo.width / photo.height,
  );

  stdout.writeln(
    '${scan.lines.length} lignes, ${candidates.length} candidates, '
    '${readings.length} lectures reconnues',
  );
  stdout.writeln(
    '${cards.length} rectangles de carte isolée ; noms du côté '
    '${switch (r.namesSitLow) {
      true => "bas",
      false => "haut",
      null => "indéterminé",
    }}',
  );

  final places = <String, List<NameCandidate>>{};
  for (final reading in r.kept) {
    places.putIfAbsent(reading.identity, () => []).add(reading.line);
  }
  stdout.writeln('\ncartes retenues :');
  for (final entry in places.entries) {
    final anchors = <NameCandidate>[];
    for (final line in entry.value) {
      if (!anchors.any((a) => areSameCard(line, a))) anchors.add(line);
    }
    stdout.writeln('   ${entry.key} ×${anchors.length}');
  }
  stdout.writeln('\nabsorbées (${r.absorbed.length}) :');
  for (final reading in r.absorbed) {
    stdout.writeln('   « ${reading.line.text} » → ${reading.identity}');
  }
}
