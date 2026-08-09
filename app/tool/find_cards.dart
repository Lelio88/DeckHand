/// Applique la délimitation des cartes à une photo, et rend le compte.
///
/// **Parité avec la mesure Python.** `api/app/vision/card_segmentation.py` a
/// servi à trouver la méthode ; c'est le portage Dart qui tourne dans
/// l'application. Les deux doivent voir les mêmes cartes sur les mêmes photos,
/// sans quoi la mesure ne dit plus rien de ce que l'utilisateur obtient.
///
/// Usage : dart run tool/find_cards.dart photo.jpg [attendu]
library;

import 'dart:convert';
import 'dart:io';

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

  final started = DateTime.now();
  final cards = findCards(photo);
  final elapsed = DateTime.now().difference(started);

  stdout.writeln(
    jsonEncode({
      'image': '${photo.width}x${photo.height}',
      'ms': elapsed.inMilliseconds,
      'cards': cards.length,
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
