/// Rejoue le filtrage d'un journal de scan, avec le code de l'application.
///
/// **Pourquoi rejouer plutôt que reconstruire l'app.** Chaque règle ajoutée au
/// filtrage — lignes de type, mots-clés, attributions, capitalisation — doit
/// être mesurée sur des lignes réellement lues, pas sur des exemples choisis.
/// Reconstruire et réinstaller pour chaque essai prendrait cinq minutes ; ce
/// rejeu prend une seconde et porte sur exactement les mêmes lignes.
///
/// Imprime les candidats retenus, au format JSON, pour qu'un script puisse
/// ensuite les confronter au catalogue.
///
/// Usage : dart run tool/replay_spread.dart mesure.log [index-du-scan]
library;

import 'dart:convert';
import 'dart:io';

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/scan/domain/spread_names.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage : dart run tool/replay_spread.dart <journal> [index]',
    );
    exit(64);
  }

  final scans = <List<ReadLine>>[];
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
    if (event['event'] == 'spread_read') {
      scans.add(<ReadLine>[]);
    } else if (event['event'] == 'spread_line' && scans.isNotEmpty) {
      scans.last.add(
        ReadLine(
          event['text'] as String,
          (event['top'] as num).toDouble(),
          (event['height'] as num).toDouble(),
          ((event['left'] as num?) ?? 0).toDouble(),
          ((event['width'] as num?) ?? 0).toDouble(),
        ),
      );
    }
  }

  if (scans.isEmpty) {
    stderr.writeln('Aucun scan dans ${args[0]}.');
    exit(65);
  }

  final index = args.length > 1 ? int.parse(args[1]) : scans.length - 1;
  final lines = scans[index < 0 ? scans.length + index : index];
  final candidates = spreadNameCandidates(lines);

  stdout.writeln(
    jsonEncode({
      'scans': scans.length,
      'lines': lines.length,
      'candidates': candidates.map((c) => c.text).toList(),
      // La position accompagne chaque candidat : c'est elle qui décide du
      // nombre d'exemplaires, et un balayage hors ligne doit pouvoir refaire ce
      // décompte sans l'appareil.
      'placed': [
        for (final c in candidates)
          {'text': c.text, 'top': c.top, 'left': c.left, 'height': c.height},
      ],
    }),
  );
}
