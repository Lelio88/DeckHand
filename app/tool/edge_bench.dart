/// Détecter la carte par ses bords plutôt que par sa clarté (#8).
///
/// **Pourquoi chercher ailleurs.** Le masque de production retient ce qui est
/// *plus sombre que son voisinage* : il suppose une carte foncée sur une table
/// claire. Mesuré sur seize photos réelles (`tool/fill_bench.dart`), cette
/// hypothèse ne tient qu'une fois sur seize — une carte à bordure noire posée
/// sur un parquet brun n'offre aucun contraste, et la forme retenue cesse
/// d'être la carte. Aucun réglage ne fabriquera un contraste absent.
///
/// **Ce qu'une carte a toujours**, en revanche, ce sont des **bords nets et
/// rectilignes**. Le gradient les voit quel que soit le sens du contraste :
/// une carte claire sur fond sombre les montre aussi bien qu'une carte sombre
/// sur fond clair. C'est la propriété qu'exploite tout scanner de documents.
///
/// **La chaîne essayée ici** : gradient → seuil relatif → dilatation pour
/// refermer le contour → remplissage → plus grande composante → coins. Les
/// deux dernières étapes sont celles de la production, inchangées ; seul le
/// masque diffère, et c'est bien lui qu'on juge.
///
/// **Ce banc ne décide pas, il départage.** Il joue les deux masques sur les
/// mêmes photos et affiche les deux verdicts côte à côte. Si le gradient ne
/// gagne pas franchement, il n'entre pas en production — c'est la règle qui a
/// déjà fait retirer le parcours multi-composantes.
///
/// Usage :
/// ```
/// dart run tool/edge_bench.dart <dossier de photos>
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:image/image.dart' as img;

/// Part des pixels retenus comme bords.
///
/// Un seuil **relatif** et non absolu : le gradient d'une photo sombre est plus
/// faible que celui d'une photo éclairée, et un seuil fixe trierait les photos
/// au lieu de trier les bords.
double edgeQuantile = 0.78;

/// Rayon de la dilatation qui referme le contour.
///
/// Un bord détecté est troué — un pixel manquant suffit à laisser fuir le
/// remplissage, et la carte se vide alors dans le fond. Deux pixels à la taille
/// d'analyse suffisent à souder ces trous sans coller la carte au décor.
int closeRadius = 4;

/// Le masque des bords : gradient, seuil relatif, puis fermeture.
Uint8List edgeMask(img.Image small) {
  final w = small.width, h = small.height;
  final grey = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      grey[y * w + x] =
          (p.r.toDouble() + p.g.toDouble() + p.b.toDouble()) / 3;
    }
  }

  // Sobel, écrit à la main : le paquet `image` rend une image, on veut les
  // amplitudes pour en tirer un quantile.
  final grad = Float32List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final gx =
          -grey[i - w - 1] - 2 * grey[i - 1] - grey[i + w - 1] +
          grey[i - w + 1] + 2 * grey[i + 1] + grey[i + w + 1];
      final gy =
          -grey[i - w - 1] - 2 * grey[i - w] - grey[i - w + 1] +
          grey[i + w - 1] + 2 * grey[i + w] + grey[i + w + 1];
      grad[i] = gx.abs() + gy.abs();
    }
  }

  final tri = Float32List.fromList(grad)..sort();
  final seuil = tri[(edgeQuantile * (tri.length - 1)).round()];

  final bords = Uint8List(w * h);
  for (var i = 0; i < grad.length; i++) {
    if (grad[i] >= seuil) bords[i] = 1;
  }

  // Dilatation : referme les trous du contour.
  final ferme = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (bords[y * w + x] == 0) continue;
      for (var dy = -closeRadius; dy <= closeRadius; dy++) {
        for (var dx = -closeRadius; dx <= closeRadius; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          ferme[ny * w + nx] = 1;
        }
      }
    }
  }
  return ferme;
}

/// Remplit ce qui est enclos par les bords — l'intérieur de la carte.
///
/// On inonde depuis les bords de l'image : tout ce que l'inondation n'atteint
/// pas est enfermé, donc intérieur à un contour.
void fillEnclosed(Uint8List mask, int w, int h) {
  final dehors = Uint8List(w * h);
  final pile = <int>[];
  void pousser(int i) {
    if (mask[i] != 0 || dehors[i] != 0) return;
    dehors[i] = 1;
    pile.add(i);
  }

  for (var x = 0; x < w; x++) {
    pousser(x);
    pousser((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    pousser(y * w);
    pousser(y * w + w - 1);
  }
  while (pile.isNotEmpty) {
    final i = pile.removeLast();
    final x = i % w, y = i ~/ w;
    if (x > 0) pousser(i - 1);
    if (x < w - 1) pousser(i + 1);
    if (y > 0) pousser(i - w);
    if (y < h - 1) pousser(i + w);
  }
  for (var i = 0; i < mask.length; i++) {
    if (dehors[i] == 0) mask[i] = 1;
  }
}

/// La plus grande composante d'un masque, et sa mesure.
({int area, int minX, int maxX, int minY, int maxY, Uint8List shape})?
biggest(Uint8List mask, int w, int h) {
  final seen = Uint8List(w * h);
  Uint8List? best;
  var bestSize = 0;
  for (var start = 0; start < mask.length; start++) {
    if (mask[start] == 0 || seen[start] != 0) continue;
    final membres = <int>[];
    final pile = <int>[start];
    seen[start] = 1;
    while (pile.isNotEmpty) {
      final i = pile.removeLast();
      membres.add(i);
      final x = i % w, y = i ~/ w;
      void visiter(int n) {
        if (mask[n] != 0 && seen[n] == 0) {
          seen[n] = 1;
          pile.add(n);
        }
      }

      if (x > 0) visiter(i - 1);
      if (x < w - 1) visiter(i + 1);
      if (y > 0) visiter(i - w);
      if (y < h - 1) visiter(i + w);
    }
    if (membres.length > bestSize) {
      bestSize = membres.length;
      final shape = Uint8List(mask.length);
      for (final i in membres) {
        shape[i] = 1;
      }
      best = shape;
    }
  }
  if (best == null) return null;

  var area = 0, minX = w, maxX = -1, minY = h, maxY = -1;
  for (var i = 0; i < best.length; i++) {
    if (best[i] == 0) continue;
    area++;
    final x = i % w, y = i ~/ w;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return (
    area: area,
    minX: minX,
    maxX: maxX,
    minY: minY,
    maxY: maxY,
    shape: best,
  );
}

({String verdict, double fill, double aspect}) parLesBords(
  img.Image photo,
  String game,
) {
  final small = img.copyResize(
    photo,
    width: analysisWidth,
    interpolation: img.Interpolation.average,
  );
  final mask = edgeMask(small);
  fillEnclosed(mask, small.width, small.height);
  final forme = biggest(mask, small.width, small.height);
  if (forme == null) return (verdict: 'aucune forme', fill: 0, aspect: 0);

  final w = forme.maxX - forme.minX + 1;
  final h = forme.maxY - forme.minY + 1;
  final fill = forme.area / (w * h);
  final aspect = w / h;
  final part = forme.area / (small.width * small.height);

  // **La forme ne doit pas être l'image.** Quand la détection échoue, elle
  // retient tout le cadre — et le rapport d'une photo de téléphone (3:4, soit
  // 0,753) tombe à 0,037 de celui d'une carte (0,716), donc dans la tolérance.
  // Mesuré : sans ce contrôle, quinze coins d'image sans aucune carte sur seize
  // étaient annoncés comme des cartes, tous au rapport exact du cadre. Une
  // carte photographiée laisse toujours voir ses quatre bords, faute de quoi il
  // n'y a rien à détourer.
  final pleinCadre = w >= small.width - 2 && h >= small.height - 2;

  final attendu = cardAspectFor(game);
  final bonAspect = (aspect - attendu).abs() <= aspectTolerance;
  final verdict = pleinCadre
      ? 'plein cadre'
      : (part < minCardArea
            ? 'aire ${(part * 100).toStringAsFixed(0)} %'
            : (fill < minShapeFill
                  ? 'remplissage'
                  : (bonAspect ? 'OUI' : 'rapport')));
  return (verdict: verdict, fill: fill, aspect: aspect);
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage : dart run tool/edge_bench.dart <dossier>');
    exitCode = 64;
    return;
  }
  final dir = Directory(args.first);
  final fichiers =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  // **Balayage.** Le seuil et le rayon de fermeture s'arbitrent l'un l'autre :
  // un seuil bas donne plus de bords donc un contour mieux fermé, mais aussi
  // plus de décor. On les mesure ensemble plutôt que l'un après l'autre.
  if (args.contains('--balayage')) {
    final photos = [
      for (final f in fichiers) img.decodeImage(f.readAsBytesSync()),
    ].whereType<img.Image>().toList();
    print('balayage sur ${photos.length} photos');
    print('');
    print('  quantile  rayon  trouvées  rapports justes (±0,05)');
    for (final q in [0.78, 0.82, 0.86, 0.90]) {
      for (final r in [2, 3, 4, 6]) {
        edgeQuantile = q;
        closeRadius = r;
        var ouis = 0, justes = 0;
        for (final photo in photos) {
          final b = parLesBords(photo, 'magic');
          if (b.verdict == 'OUI') ouis++;
          if ((b.aspect - cardAspectFor('magic')).abs() <= 0.05) justes++;
        }
        print('     ${q.toStringAsFixed(2)}      $r'
            '  ${ouis.toString().padLeft(8)}'
            '  ${justes.toString().padLeft(8)}');
      }
    }
    return;
  }

  // **Le garde-fou.** Trouver la carte ne vaut rien si l'on en trouve aussi là
  // où il n'y en a pas : c'est le faux positif qui a coûté le plus cher jusque
  // ici. Faute de photos de fond seul, on recadre chaque photo sur son coin —
  // même table, même lumière, même appareil, mais pas de carte.
  if (args.contains('--sans-carte')) {
    print('coins recadrés (fond seul) — toute carte annoncée est un faux');
    print('');
    var faux = 0;
    for (final f in fichiers) {
      final photo = img.decodeImage(f.readAsBytesSync());
      if (photo == null) continue;
      final coin = img.copyCrop(
        photo,
        x: 0,
        y: 0,
        width: (photo.width * 0.33).round(),
        height: (photo.height * 0.33).round(),
      );
      final b = parLesBords(coin, 'magic');
      final inverse = (b.aspect - 1 / cardAspectFor('magic')).abs() <= aspectTolerance;
      final annonce = b.verdict == 'OUI' || (b.verdict == 'rapport' && inverse);
      if (annonce) faux++;
      print(
        '  ${(annonce ? 'CARTE' : '—').padRight(6)}'
        ' ${b.verdict.padRight(12)}'
        ' rempl ${(b.fill * 100).toStringAsFixed(0).padLeft(3)} %'
        ' rapp ${b.aspect.toStringAsFixed(3)}'
        '   ${f.uri.pathSegments.last}',
      );
    }
    print('');
    print('cartes inventées : $faux/${fichiers.length}');
    return;
  }

  print('${fichiers.length} photos — clarté contre gradient');
  print('');
  print('   clarté         gradient                    fichier');

  var gagneClarte = 0, gagneBords = 0;
  for (final f in fichiers) {
    final photo = img.decodeImage(f.readAsBytesSync());
    if (photo == null) continue;

    final quad = findCard(photo, game: 'magic');
    final clarte = quad == null
        ? 'non'
        : 'oui ${quad.aspect.toStringAsFixed(3)}';
    final bords = parLesBords(photo, 'magic');
    final droit = bords.verdict == 'OUI';
    if (quad != null) gagneClarte++;
    if (droit) gagneBords++;

    print(
      '  ${clarte.padRight(12)}   '
      '${bords.verdict.padRight(12)} '
      'rempl ${(bords.fill * 100).toStringAsFixed(0).padLeft(3)} % '
      'rapp ${bords.aspect.toStringAsFixed(3)}   '
      '${f.uri.pathSegments.last}',
    );
  }
  print('');
  print('clarté : $gagneClarte/${fichiers.length}'
      '   ·   gradient : $gagneBords/${fichiers.length}');
}
