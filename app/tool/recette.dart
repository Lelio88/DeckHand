/// Le banc de recette de la détection, sur photos réelles (#8).
///
/// **Pourquoi il vit hors du dépôt.** Deux cent onze mégaoctets de photos prises
/// au téléphone n'ont rien à faire dans un dépôt public (§IV.11), et un cache de
/// sonde y est déjà entré une fois par un `git add -A`. Elles vivent donc dans
/// `Projets/.deckhand-bench/photos/`, à côté des coffres de secrets, et ce banc
/// va les y chercher.
///
/// **Ce qu'il mesure, et pourquoi deux chiffres.** Le premier — les cartes
/// trouvées — ne vaut rien seul : une chaîne qui trouve tout en inventant la
/// moitié est pire que celle qui ne trouve rien, puisque l'utilisateur devra
/// décocher à la main ce qu'il n'a jamais montré. Le second — les cartes
/// **inventées** sur des photos sans carte — est le juge.
///
/// **Un troisième chiffre, moins évident : l'aire.** Une détection peut réussir
/// et se tromper de rectangle — les cadres intérieurs d'une carte (illustration,
/// bloc de texte) ont des bords plus francs que son contour. Le compteur dit
/// alors « trouvée » quand l'empreinte sera calculée sur « Éphémère ». L'aire
/// médiane sépare les deux : une carte occupe 40 à 65 % d'une photo cadrée sur
/// elle, un cadre intérieur 15 à 25 %.
///
/// Rangement attendu, une situation par dossier :
/// ```
/// .deckhand-bench/photos/
///   carte-seule/   une carte à trouver, sur tous fonds et lumières
///   etalement/     plusieurs cartes — la détection n'en cherche qu'une
///   sans-carte/    aucune carte : toute détection y est un faux
/// ```
///
/// Usage :
/// ```
/// cd app && dart run tool/recette.dart            # tout
/// cd app && dart run tool/recette.dart --dump <dossier>
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:image/image.dart' as img;

/// Où vivent les photos, depuis `app/`.
const String bancParDefaut = '../../.deckhand-bench/photos';

/// Aire en deçà de laquelle une détection est vraisemblablement un cadre
/// intérieur et non la carte.
///
/// Mesuré : les cartes correctement détourées occupent 40 à 65 % de l'image,
/// les cadres intérieurs 15 à 25 %.
const double aireSuspecte = 0.30;

/// Seuil de rupture de matière, balayable depuis la ligne de commande.
/// Doit suivre `_ruptureMinimale` de la production, sans quoi le banc mesure
/// un autre réglage que celui qui tourne.
double gRupture = 0.30;

double _part(CardQuad q, int w, int h) {
  double d(({double x, double y}) a, ({double x, double y}) b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
  return d(q.topLeft, q.topRight) * d(q.topRight, q.bottomRight) / (w * h);
}

void _dessine(img.Image photo, CardQuad? quad, String vers) {
  final vue = img.copyResize(photo, width: 400);
  final f = 400 / photo.width;
  if (quad != null) {
    final coins = [
      quad.topLeft,
      quad.topRight,
      quad.bottomRight,
      quad.bottomLeft,
    ];
    for (var i = 0; i < 4; i++) {
      final a = coins[i], b = coins[(i + 1) % 4];
      img.drawLine(
        vue,
        x1: (a.x * f).round(),
        y1: (a.y * f).round(),
        x2: (b.x * f).round(),
        y2: (b.y * f).round(),
        color: img.ColorRgb8(255, 0, 0),
        thickness: 2,
      );
    }
  }
  File(vers).writeAsBytesSync(img.encodePng(vue));
}

bool gDetails = false;

/// Voir les photos comme le flux caméra les voit.
///
/// **La question qui décide du branchement.** Le mode vidéo ne reçoit pas une
/// image couleur mais un plan de luminance ; la matérialiser en RGB coûte
/// 10,4 ms sur l'appareil, mesuré, avant même que la détection commence. Or le
/// gradient sur les trois canaux est ce qui a débloqué la détection sur fond
/// sombre. Il faut donc savoir ce que la chaîne vaut sans lui.
bool gLuma = false;

/// Largeur d'analyse, pour mesurer ce que coûte la résolution.
int gLargeur = 400;

img.Image _enLuminance(img.Image photo) {
  final gris = photo.clone();
  for (var y = 0; y < gris.height; y++) {
    for (var x = 0; x < gris.width; x++) {
      final p = gris.getPixel(x, y);
      final l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      gris.setPixelRgb(x, y, l, l, l);
    }
  }
  return gris;
}

({int photos, int trouvees, int suspectes, double mediane}) _passe(
  Directory dir,
  String? dump,
  String nom,
) {
  final fichiers =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  var trouvees = 0, suspectes = 0;
  final aires = <double>[];
  for (final f in fichiers) {
    var photo = img.decodeImage(f.readAsBytesSync());
    if (photo == null) continue;
    if (gLuma) photo = _enLuminance(photo);

    // **La chaîne de production, par la fonction de production.** Ce banc en
    // avait une copie ; quand le service a cessé de retenir un cadre couvrant
    // presque toute l'image, la copie a continué de le faire — et le banc
    // mesurait alors un code que personne n'exécute.
    final quad = largestPlausible([
      findCardByEdges(photo, ruptureMin: gRupture, width: gLargeur),
      findCard(photo),
    ], width: photo.width, height: photo.height);

    if (gDetails) {
      // On ne liste que ce qui cloche : les cartes manquees d'un cote, les
      // cartes inventees de l'autre. Le reste n'apprend rien.
      final rate = nom == 'sans-carte' ? quad != null : quad == null;
      if (rate) {
        print('      ${nom == 'sans-carte' ? 'INVENTEE' : 'manquee '} '
            '${f.uri.pathSegments.last}');
      }
    }
    if (quad != null) {
      trouvees++;
      final part = _part(quad, photo.width, photo.height);
      aires.add(part);
      if (part < aireSuspecte) suspectes++;
    }
    if (dump != null) {
      _dessine(
        photo,
        quad,
        '$dump/${f.uri.pathSegments.last.replaceAll('.jpg', '.png')}',
      );
    }
  }
  aires.sort();
  return (
    photos: fichiers.length,
    trouvees: trouvees,
    suspectes: suspectes,
    mediane: aires.isEmpty ? 0 : aires[aires.length ~/ 2],
  );
}

void main(List<String> args) {
  final iR = args.indexOf('--rupture');
  if (iR >= 0) gRupture = double.parse(args[iR + 1]);
  gDetails = args.contains('--details');
  gLuma = args.contains('--luma');
  final iC = args.indexOf('--plafond');
  if (iC >= 0) cardCoverageCeiling = double.parse(args[iC + 1]);
  final iL = args.indexOf('--largeur');
  if (iL >= 0) gLargeur = int.parse(args[iL + 1]);
  final iDump = args.indexOf('--dump');
  final dump = iDump >= 0 && iDump + 1 < args.length ? args[iDump + 1] : null;
  if (dump != null) Directory(dump).createSync(recursive: true);

  final racine = Directory(
    args.isNotEmpty && !args.first.startsWith('--') ? args.first : bancParDefaut,
  );
  if (!racine.existsSync()) {
    stderr.writeln('banc introuvable : ${racine.path}');
    stderr.writeln('les photos vivent hors du dépôt, voir le README du banc');
    exitCode = 66;
    return;
  }

  print('banc de recette — ${racine.path}');
  print('');
  for (final sous in racine.listSync().whereType<Directory>()) {
    final nom = sous.uri.pathSegments[sous.uri.pathSegments.length - 2];
    String? sousDump;
    if (dump != null) {
      sousDump = '$dump/$nom';
      Directory(sousDump).createSync(recursive: true);
    }
    final r = _passe(sous, sousDump, nom);
    if (r.photos == 0) {
      print('  ${nom.padRight(14)} — vide');
      continue;
    }
    final verdict = nom == 'sans-carte'
        ? '${r.trouvees} INVENTÉES sur ${r.photos}'
        : '${r.trouvees}/${r.photos} trouvées'
              ' · aire médiane ${(r.mediane * 100).toStringAsFixed(0)} %'
              ' · ${r.suspectes} douteuses';
    print('  ${nom.padRight(14)} — $verdict');
  }
  print('');
  print(
    'une détection « douteuse » occupe moins de '
    '${(aireSuspecte * 100).round()} % de l\'image : c\'est probablement un '
    'cadre intérieur, donc une empreinte calculée au mauvais endroit.',
  );
}
