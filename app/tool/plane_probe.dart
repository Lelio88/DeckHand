/// Ce que la détection par droites voit de la figure du banc du flux (#8).
library;

// ignore_for_file: avoid_print
import 'dart:typed_data';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';

const int width = 1280, height = 720, rowStride = 1280;

Uint8List plane({int? shade, int left = 400, int top = 100}) {
  final luma = Uint8List(rowStride * height)
    ..fillRange(0, rowStride * height, 170);
  if (shade == null) return luma;
  const w = 322, h = 450;
  for (var y = top; y < top + h; y++) {
    for (var x = left; x < left + w; x++) {
      final step = 6 + shade;
      luma[y * rowStride + x] =
          ((x ~/ step + y ~/ step) % 2 == 0) ? 18 + shade : 60 + shade;
    }
  }
  return luma;
}

void main() {
  for (final shade in [0, 40]) {
    final luma = plane(shade: shade);
    final e = findCardByEdgesInLuma(
      luma,
      width: width,
      height: height,
      rowStride: rowStride,
    );
    final c = findCardInLuma(luma, width: width, height: height, rowStride: rowStride);
    String dire(CardQuad? q) => q == null
        ? 'rien'
        : 'x ${q.topLeft.x.toStringAsFixed(0)}→${q.topRight.x.toStringAsFixed(0)}'
            ' y ${q.topLeft.y.toStringAsFixed(0)}→${q.bottomLeft.y.toStringAsFixed(0)}'
            ' rapport ${q.aspect.toStringAsFixed(3)}';
    print('shade $shade  (carte attendue x 400→722, y 100→550)');
    print('  droites : ${dire(e)}');
    print('  clarté  : ${dire(c)}');
  }
}
