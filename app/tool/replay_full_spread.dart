/// Rejoue un scan d'étalement complet — filtrage des citations compris.
///
/// **Ce que les outils précédents ne pouvaient pas montrer.** `replay_spread`
/// rejoue le filtrage des lignes, `find_cards` la délimitation des cartes ; ni
/// l'un ni l'autre ne dit ce que l'utilisateur verra, puisque le résultat final
/// naît de leur croisement. Cet outil rejoue la chaîne entière sur un journal et
/// sa photo, sans appareil.
///
/// Usage :
///   dart run tool/replay_full_spread.dart mesure.log photo.jpg [index-du-scan]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/scan/domain/card_segmentation.dart';
import 'package:deckhand/src/features/scan/domain/spread_names.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'usage : dart run tool/replay_full_spread.dart <journal> <photo> [index]',
    );
    exit(64);
  }

  final scans = <List<ReadLine>>[];
  final matches = <Map<String, dynamic>>[];
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
        scans.add(<ReadLine>[]);
        matches.clear();
      case 'spread_line' when scans.isNotEmpty:
        scans.last.add(
          ReadLine(
            event['text'] as String,
            (event['top'] as num).toDouble(),
            (event['height'] as num).toDouble(),
            ((event['left'] as num?) ?? 0).toDouble(),
            ((event['width'] as num?) ?? 0).toDouble(),
          ),
        );
      case 'spread_match' when (event['kept'] as bool? ?? false):
        matches.add(event);
    }
  }

  final index = args.length > 2 ? int.parse(args[2]) : scans.length - 1;
  final lines = scans[index < 0 ? scans.length + index : index];
  final candidates = spreadNameCandidates(lines);

  // Le nom trouvé tient lieu d'identité : le journal ne porte pas l'oracle_id.
  final byName = <String, List<NameCandidate>>{};
  for (final match in matches) {
    final read = match['read'] as String;
    final name = match['matched'] as String;
    for (final c in candidates) {
      if (c.text == read) byName.putIfAbsent(name, () => []).add(c);
    }
  }

  final photo = img.decodeImage(File(args[1]).readAsBytesSync());
  final cards = photo == null
      ? const <CardBounds>[]
      : singleCards(findCards(photo));

  final elected = <String>{};
  final suspect = <String>{};
  for (final card in cards) {
    final mx = card.width * boundsMargin;
    final my = card.height * boundsMargin;
    final horizontal = card.width > card.height;
    final lo = horizontal ? card.left : card.top;
    final hi = horizontal ? card.right : card.bottom;
    if (hi - lo <= 0) continue;

    String? nearest;
    var shallowest = double.infinity;
    final present = <String>{};
    for (final entry in byName.entries) {
      for (final line in entry.value) {
        if (line.left < card.left - mx || line.left > card.right + mx) continue;
        if (line.top < card.top - my || line.top > card.bottom + my) continue;
        final axis = horizontal ? line.left : line.top;
        final depth = min((axis - lo).abs(), (axis - hi).abs()) / (hi - lo);
        if (depth >= citationDepth) present.add(entry.key);
        if (depth < shallowest) {
          shallowest = depth;
          nearest = entry.key;
        }
      }
    }
    if (nearest == null) continue;
    elected.add(nearest);
    suspect.addAll(present.where((id) => id != nearest));
  }
  final rejected = suspect.difference(elected);

  stdout.writeln('${lines.length} lignes, ${candidates.length} candidates, '
      '${byName.length} cartes avant filtrage');
  stdout.writeln('${cards.length} rectangles de carte isolée');
  stdout.writeln('\ncartes retenues :');
  for (final name in byName.keys.where((n) => !rejected.contains(n))) {
    stdout.writeln('   $name');
  }
  stdout.writeln('\nrejetées comme citations (${rejected.length}) :');
  for (final name in rejected) {
    stdout.writeln('   $name');
  }
}
