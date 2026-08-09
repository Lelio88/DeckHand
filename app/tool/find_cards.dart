/// Applique la délimitation des cartes à une photo, et rend le compte.
///
/// **Parité avec la mesure Python.** `api/app/vision/card_segmentation.py` a
/// servi à trouver la méthode ; c'est le portage Dart qui tourne dans
/// l'application. Les deux doivent voir les mêmes cartes sur les mêmes photos,
/// sans quoi la mesure ne dit plus rien de ce que l'utilisateur obtient.
///
/// Rend aussi, par resolution, le jour le plus etroit encore resolu entre deux
/// cartes voisines : c'est lui qui dit ce que la resolution achete reellement.
///
/// Usage : dart run tool/find_cards.dart photo.jpg [attendu] [largeurs]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:deckhand/src/features/scan/domain/card_segmentation.dart';
import 'package:image/image.dart' as img;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage : dart run tool/find_cards.dart <photo> [attendu]');
    exit(64);
  }

  final file = File(args[0]);
  if (!file.existsSync()) {
    stderr.writeln('Photo introuvable : ${file.path}');
    exit(66);
  }

  final photo = img.decodeImage(file.readAsBytesSync());
  if (photo == null) {
    stderr.writeln('Image illisible : ${file.path}');
    exit(65);
  }

  final widths = args.length > 2
      ? args[2].split(',').map(int.parse).toList()
      : const [800];

  final runs = <Map<String, Object>>[];
  for (final width in widths) {
    final started = DateTime.now();
    final cards = findCards(photo, workWidth: width);
    // Le jour le plus etroit encore resolu : c'est lui qui dit ce que la
    // resolution achete reellement.
    var tightest = double.infinity;
    for (var i = 0; i < cards.length; i++) {
      for (var j = i + 1; j < cards.length; j++) {
        final a = cards[i];
        final b = cards[j];
        final dx = [a.left - b.right, b.left - a.right, 0.0].reduce(max);
        final dy = [a.top - b.bottom, b.top - a.bottom, 0.0].reduce(max);
        if (dx > 0 && dy > 0) continue; // en diagonale : pas des voisins
        final gap = dx > 0 ? dx : dy;
        if (gap > 0 && gap < tightest) tightest = gap;
      }
    }
    runs.add({
      'width': width,
      'ms': DateTime.now().difference(started).inMilliseconds,
      'cards': cards.length,
      'tightestGap': tightest.isFinite ? tightest : -1,
    });
  }
  final cards = findCards(photo, workWidth: widths.first);
  final elapsed = Duration(milliseconds: runs.first['ms']! as int);

  stdout.writeln(
    jsonEncode({
      'image': '${photo.width}x${photo.height}',
      'ms': elapsed.inMilliseconds,
      'cards': cards.length,
      'runs': runs,
      if (args.length > 1) 'expected': int.parse(args[1]),
      'bounds': [
        for (final c in cards)
          {
            'left': double.parse(c.left.toStringAsFixed(4)),
            'top': double.parse(c.top.toStringAsFixed(4)),
            'right': double.parse(c.right.toStringAsFixed(4)),
            'bottom': double.parse(c.bottom.toStringAsFixed(4)),
          },
      ],
    }),
  );
}
