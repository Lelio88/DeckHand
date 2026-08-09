/// Rejoue un scan d'étalement complet — filtrage des citations compris.
///
/// **Ce que les autres outils ne peuvent pas montrer.** `replay_spread` rejoue
/// le filtrage des lignes, `find_cards` la délimitation des cartes ; ni l'un ni
/// l'autre ne dit ce que l'utilisateur verra, puisque le résultat naît de leur
/// croisement. Cet outil rejoue la chaîne entière sur un journal et sa photo,
/// sans appareil ni reconstruction.
///
/// Il reproduit ce que fait `ScanService._citationsAmong` : c'est la seule façon
/// de régler le filtrage sur ce que l'application exécute réellement. Les deux
/// doivent rester alignés — un écart ici rendrait la mesure trompeuse.
///
/// Usage :
///   dart run tool/replay_full_spread.dart mesure.log photo.jpg [index-du-scan]
library;

import 'dart:convert';
import 'dart:io';

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
  final places = <String, List<NameCandidate>>{};
  for (final match in matches) {
    final read = match['read'] as String;
    final name = match['matched'] as String;
    for (final c in candidates) {
      if (c.text == read) places.putIfAbsent(name, () => []).add(c);
    }
  }

  final photo = img.decodeImage(File(args[1]).readAsBytesSync());
  final cards = photo == null
      ? const <CardBounds>[]
      : singleCards(findCards(photo));

  final byCard = <int, Map<String, double>>{};
  for (var i = 0; i < cards.length; i++) {
    final card = cards[i];
    final mx = card.width * boundsMargin;
    final my = card.height * boundsMargin;
    final horizontal = card.width > card.height;
    final lo = horizontal ? card.left : card.top;
    final hi = horizontal ? card.right : card.bottom;
    if (hi - lo <= 0) continue;

    final along = <String, double>{};
    for (final entry in places.entries) {
      for (final line in entry.value) {
        if (line.left < card.left - mx || line.left > card.right + mx) continue;
        if (line.top < card.top - my || line.top > card.bottom + my) continue;
        final axis = horizontal ? line.left : line.top;
        final at = (axis - lo) / (hi - lo);
        final seen = along[entry.key];
        if (seen == null || (at - 0.5).abs() < (seen - 0.5).abs()) {
          along[entry.key] = at;
        }
      }
    }
    if (along.isNotEmpty) byCard[i] = along;
  }

  final lonely = [
    for (final along in byCard.values)
      if (along.length == 1) along.values.first,
  ];
  final low = nameSitsLow(lonely);

  final suspect = <String>{};
  final elected = <String>{};
  for (final along in byCard.values) {
    for (final entry in along.entries) {
      if (entry.value < 0 || entry.value > 1) continue;
      final fromNameEnd = low ? entry.value : 1 - entry.value;
      (fromNameEnd > citationEnd ? suspect : elected).add(entry.key);
    }
  }
  final rejected = lonely.isEmpty ? <String>{} : suspect.difference(elected);

  stdout.writeln(
    '${lines.length} lignes, ${candidates.length} candidates, '
    '${places.length} cartes avant filtrage',
  );
  stdout.writeln(
    '${cards.length} rectangles de carte isolée ; noms du côté '
    '${low ? "bas" : "haut"} (${lonely.length} rectangles sans ambiguïté)',
  );

  stdout.writeln('\npositions le long de chaque carte :');
  for (final along in byCard.values) {
    final parts = along.entries.map((e) {
      final name = e.key.length > 24 ? e.key.substring(0, 24) : e.key;
      return '$name à ${(e.value * 100).round()} %';
    });
    stdout.writeln('   ${parts.join('  |  ')}');
  }

  stdout.writeln('\ncartes retenues :');
  for (final name in places.keys.where((n) => !rejected.contains(n))) {
    stdout.writeln('   $name');
  }
  stdout.writeln('\nrejetées comme citations (${rejected.length}) :');
  for (final name in rejected) {
    stdout.writeln('   $name');
  }
}
