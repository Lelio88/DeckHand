/// Ce que chaque chaîne détoure sur la photo de contrôle des tests (#8).
library;

// ignore_for_file: avoid_print
import 'dart:typed_data';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:image/image.dart' as img;

img.Image fakeCard(int w, int h, int seed) {
  final card = img.Image(width: w, height: h);
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h; y++) {
      card.setPixelRgb(x, y, (x * 7 + seed * 31) % 256, (y * 5 + seed * 17) % 256,
          (x + y + seed * 53) % 256);
    }
  }
  return card;
}

void main() {
  final card = fakeCard(300, 419, 1);
  final photo = img.Image(width: (300 * 1.6).round(), height: 419);
  img.fill(photo, color: img.ColorRgb8(90, 70, 50));
  img.compositeImage(photo, card, dstX: (photo.width - 300) ~/ 2, dstY: 0);
  final bytes = Uint8List.fromList(img.encodePng(photo));
  final decoded = img.decodeImage(bytes)!;

  print('photo ${decoded.width} x ${decoded.height}');
  for (final e in {
    'droites': findCardByEdges(decoded, game: 'magic'),
    'clarté': findCard(decoded, game: 'magic'),
  }.entries) {
    final q = e.value;
    print(q == null
        ? '  ${e.key.padRight(9)} : rien'
        : '  ${e.key.padRight(9)} : aire ${q.area.toStringAsFixed(0).padLeft(7)}'
            '  rapport ${q.aspect.toStringAsFixed(3)}'
            '  x ${q.topLeft.x.toStringAsFixed(0)}→${q.topRight.x.toStringAsFixed(0)}'
            '  y ${q.topLeft.y.toStringAsFixed(0)}→${q.bottomLeft.y.toStringAsFixed(0)}');
  }
}
