/// Ce que la détection de bords coûte à la cadence d'une vidéo.
///
/// **Pourquoi ce banc existe.** Le budget du temps réel est mesuré à 1,73 ms
/// par image sur l'appareil (`tool/frame_bench.dart`) — mais ce chiffre couvre
/// la lecture, l'empreinte et la recherche, **pas la détection de bords**. Il
/// décrit donc le mode à caméra fixe, où la carte est toujours au même endroit
/// et où il n'y a rien à détecter.
///
/// Un flux libre, lui, doit retrouver la carte dans chaque image. La question
/// n'est plus « l'empreinte tient-elle dans le budget » — elle y tient
/// largement — mais « la **détection** y tient-elle ». À 30 images par seconde,
/// le budget est de 33 ms.
///
/// Ce banc mesure `findCard` seul, aux résolutions que sert le paquet `camera`,
/// pour que la forme du mode temps réel se décide sur un nombre plutôt que sur
/// une intuition.
///
/// **Ce qu'il ne dit pas** : le coût sur l'appareil. Un cœur de téléphone est
/// plus lent qu'un cœur de bureau, et l'AOT ne se compare pas au JIT. Les
/// rapports entre résolutions transfèrent, les durées absolues non — la même
/// réserve que pour `frame_bench.dart`, qui avait mesuré 8,3 ms au poste pour
/// 1,73 sur l'appareil.
///
/// Usage : `dart run tool/detect_cost.dart`
library;

import 'dart:io';

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:image/image.dart' as img;

/// Résolutions servies par le paquet `camera`, de l'aperçu au cliché.
const List<({String nom, int largeur, int hauteur})> resolutions = [
  (nom: 'low     320 × 240', largeur: 320, hauteur: 240),
  (nom: 'medium  720 × 480', largeur: 720, hauteur: 480),
  (nom: 'high   1280 × 720', largeur: 1280, hauteur: 720),
  (nom: 'veryHigh 1920×1080', largeur: 1920, hauteur: 1080),
  (nom: 'photo  3072 × 4080', largeur: 3072, hauteur: 4080),
];

void main() {
  stdout.writeln('Coût de findCard — budget vidéo : 33 ms à 30 images/s\n');
  stdout.writeln(
    '${'résolution'.padRight(22)}${'p50'.padLeft(9)}${'min'.padLeft(9)}'
    '${'part du budget'.padLeft(16)}',
  );

  for (final r in resolutions) {
    final photo = _scene(r.largeur, r.hauteur);
    for (var i = 0; i < 3; i++) {
      findCard(photo); // rodage
    }
    final durees = <int>[];
    for (var i = 0; i < 12; i++) {
      final sw = Stopwatch()..start();
      findCard(photo);
      sw.stop();
      durees.add(sw.elapsedMicroseconds);
    }
    durees.sort();
    final p50 = durees[durees.length ~/ 2] / 1000;
    final part = p50 / 33 * 100;
    stdout.writeln(
      '${r.nom.padRight(22)}'
      '${'${p50.toStringAsFixed(1)} ms'.padLeft(9)}'
      '${'${(durees.first / 1000).toStringAsFixed(1)} ms'.padLeft(9)}'
      '${'${part.toStringAsFixed(0)} %'.padLeft(16)}',
    );
  }
}

/// Une carte sombre posée de travers sur une table claire.
///
/// La détection travaille toujours à `analysisWidth`, mais le redimensionnement
/// qui l'y amène, lui, dépend de la taille d'entrée : c'est cette part-là que le
/// banc cherche à voir grandir.
img.Image _scene(int width, int height) {
  final canvas = img.Image(width: width, height: height);
  img.fill(canvas, color: img.ColorRgb8(170, 152, 126));
  // Du grain, sans quoi la table serait un aplat que la détection traverse trop
  // facilement pour être représentative.
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final g = (x * 7 + y * 13) % 17 - 8;
      canvas.setPixelRgb(x, y, 170 + g, 152 + g, 126 + g);
    }
  }
  final cardHeight = (height * 0.6).round();
  final cardWidth = (cardHeight * cardAspectFor('magic')).round();
  final card = img.Image(width: cardWidth, height: cardHeight);
  img.fill(card, color: img.ColorRgb8(20, 18, 24));
  final art = img.Image(
    width: (cardWidth * 0.84).round(),
    height: (cardHeight * 0.43).round(),
  );
  img.fill(art, color: img.ColorRgb8(190, 70, 50));
  img.compositeImage(card, art, dstX: (cardWidth * 0.08).round(), dstY: (cardHeight * 0.12).round());
  img.compositeImage(
    canvas,
    img.copyRotate(card.convert(numChannels: 4), angle: 4),
    dstX: (width - cardWidth) ~/ 2,
    dstY: (height - cardHeight) ~/ 2,
  );
  return canvas;
}
