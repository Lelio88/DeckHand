/// Combien de cartes une photo d'étalement rend-elle vraiment ? (#8, #31)
///
/// **Ce qui se mesure ici, et ce qui ne peut pas l'être.** L'étalement en
/// production ne segmente pas : il **lit les noms** (`spreadNameCandidates` +
/// ML Kit), les tentatives de segmentation ayant plafonné à 57 % de rappel. Or
/// ML Kit est un greffon natif : aucun banc de poste ne peut le jouer. Ce que ce
/// banc mesure est donc la **segmentation** (`findCards`) — la voie qui découpe
/// les cartes, utile au recadrage et candidate à un retour si elle progresse.
///
/// La chaîne complète, elle, ne se mesure que **sur l'appareil**.
///
/// **La vérité vient d'un humain qui regarde.** `attendu.csv`, à côté des
/// photos, dit combien de cartes chacune porte. Rien ne la déduit — un banc qui
/// se donne à lui-même sa référence ne mesure que sa propre cohérence. Elle a
/// été comptée sur planche contact (`tool/planche.dart`).
///
/// **Trois erreurs, pas une.** Trouver trop peu (des cartes manquées) et trouver
/// trop (du décor pris pour une carte) ne se soignent pas pareil, et un écart
/// net peut cacher les deux qui se compensent. Le banc les sépare.
///
/// Usage :
/// ```
/// cd app && dart run tool/etalement_bench.dart
/// cd app && dart run tool/etalement_bench.dart --dump <dossier>
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:deckhand/src/features/scan/domain/card_segmentation.dart';
import 'package:image/image.dart' as img;

/// Où vivent les photos, depuis `app/`.
const String dossierParDefaut = '../../.deckhand-bench/photos/etalement';

Map<String, int> _attendu(Directory dir) {
  final f = File('${dir.path}/attendu.csv');
  if (!f.existsSync()) return const {};
  final table = <String, int>{};
  for (final ligne in f.readAsLinesSync()) {
    final net = ligne.trim();
    if (net.isEmpty || net.startsWith('#')) continue;
    final bouts = net.split(',');
    if (bouts.length != 2) continue;
    final n = int.tryParse(bouts[1].trim());
    if (n != null) table[bouts[0].trim()] = n;
  }
  return table;
}

void _dessine(img.Image photo, List<CardBounds> cartes, String vers) {
  final vue = img.copyResize(photo, width: 500);
  for (final c in cartes) {
    img.drawRect(
      vue,
      x1: (c.left * vue.width).round(),
      y1: (c.top * vue.height).round(),
      x2: (c.right * vue.width).round(),
      y2: (c.bottom * vue.height).round(),
      color: img.ColorRgb8(255, 0, 0),
      thickness: 2,
    );
  }
  File(vers).writeAsBytesSync(img.encodePng(vue));
}

void main(List<String> args) {
  final iDump = args.indexOf('--dump');
  final dump = iDump >= 0 && iDump + 1 < args.length ? args[iDump + 1] : null;
  if (dump != null) Directory(dump).createSync(recursive: true);

  final dir = Directory(
    args.isNotEmpty && !args.first.startsWith('--')
        ? args.first
        : dossierParDefaut,
  );
  if (!dir.existsSync()) {
    stderr.writeln('banc introuvable : ${dir.path}');
    exitCode = 66;
    return;
  }

  final attendu = _attendu(dir);
  final fichiers =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  print('${fichiers.length} étalements — ${dir.path}');
  print('');
  print('  attendu  trouvé  manquées  en trop   fichier');

  var totalAttendu = 0, totalManquees = 0, totalEnTrop = 0, parfaites = 0;
  for (final f in fichiers) {
    final nom = f.uri.pathSegments.last;
    final photo = img.decodeImage(f.readAsBytesSync());
    if (photo == null) continue;

    final cartes = singleCards(findCards(photo));
    if (dump != null) {
      _dessine(photo, cartes, '$dump/${nom.replaceAll('.jpg', '.png')}');
    }

    final vise = attendu[nom];
    if (vise == null) {
      print('  ${'?'.padLeft(7)}  ${cartes.length.toString().padLeft(6)}'
          '                       $nom  (absent d\'attendu.csv)');
      continue;
    }

    // **Manquées et en trop, séparément.** Le seul écart net masque le cas où
    // l'on rate deux cartes tout en inventant deux morceaux de table.
    final manquees = vise > cartes.length ? vise - cartes.length : 0;
    final enTrop = cartes.length > vise ? cartes.length - vise : 0;
    totalAttendu += vise;
    totalManquees += manquees;
    totalEnTrop += enTrop;
    if (manquees == 0 && enTrop == 0) parfaites++;

    print(
      '  ${vise.toString().padLeft(7)}'
      '  ${cartes.length.toString().padLeft(6)}'
      '  ${manquees == 0 ? '  ·' : manquees.toString().padLeft(3)}'
      '       ${enTrop == 0 ? '  ·' : enTrop.toString().padLeft(3)}'
      '     $nom',
    );
  }

  print('');
  print(
    '$parfaites/${fichiers.length} étalements exacts'
    ' · $totalManquees cartes manquées sur $totalAttendu'
    ' · $totalEnTrop formes en trop',
  );
  print(
    'le compte exact ne prouve rien à lui seul : deux cartes ratées et deux '
    'morceaux de table se compensent. Regarder les tracés (--dump).',
  );
}
