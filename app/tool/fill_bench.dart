/// Une carte remplit-elle sa boîte, et un amas non ? (#8, #31)
///
/// **Ce que ce banc cherche à trancher.** La détection retient la plus grande
/// forme du masque, en vérifie l'aire et le rapport, et conclut. Sur une photo
/// réelle prise sur un clavier, elle a retenu une forme allant d'un coin à
/// l'autre de l'image — clavier, doigts et carton fondus — dont le rapport
/// (0,674) ressemblait assez à celui d'une carte (0,716) pour passer. Une carte
/// a pourtant une propriété qu'un amas n'a pas : **c'est un rectangle plein**,
/// et il remplit sa boîte englobante.
///
/// `debugDetection` calcule déjà ce taux et `probe_photo` l'affiche à chaque
/// exécution ; la détection, elle, ne le regarde pas. Reste à savoir où poser
/// le seuil — et cela se mesure sur de vraies photos plutôt que de se choisir.
///
/// **Deux populations, et il faut les deux.** Les cartes du banc de cadrage
/// disent jusqu'où une vraie carte peut descendre ; les scènes sans carte
/// disent à partir d'où un amas remonte. Un seuil posé sur la seule première
/// laisserait passer ce qu'on veut exclure.
///
/// Usage :
/// ```
/// dart run tool/fill_bench.dart <dossier|image> [<dossier|image>…]
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';

import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:image/image.dart' as img;

import 'synthetic_photo.dart';

({double fill, double aspect, bool accepted})? _mesure(File f, String game) {
  final image = img.decodeImage(f.readAsBytesSync());
  if (image == null) return null;
  return _mesureImage(image, game);
}

({double fill, double aspect, bool accepted}) _mesureImage(
  img.Image image,
  String game,
) {
  final vu = debugDetection(image);
  final quad = findCard(image, game: game);
  return (
    fill: vu.fill,
    aspect: quad?.aspect ?? double.nan,
    accepted: quad != null,
  );
}

/// Les rendus officiels ne suffisent pas : ils remplissent l'image entière, et
/// mesurer leur boîte englobante revient à mesurer l'image. Le banc de cadrage
/// sait poser une carte sur une table, de travers et sous une lampe — ce sont
/// ces scènes-là qui disent jusqu'où une **vraie** carte descend.
void _scenes(List<File> sources, int parCarte) {
  final remplissages = <double>[];
  print('');
  print('  remplissage  rapport  retenue  régime');
  var graine = 20260822;
  for (final f in sources.take(parCarte)) {
    final carte = img.decodeImage(f.readAsBytesSync());
    if (carte == null) continue;
    for (final regime in regimes) {
      final scene = compose(carte, regime, math.Random(graine++));
      final m = _mesureImage(scene, 'magic');
      remplissages.add(m.fill);
      print(
        '  ${(m.fill * 100).toStringAsFixed(1).padLeft(10)} %'
        '  ${m.aspect.isNaN ? '    —' : m.aspect.toStringAsFixed(3).padLeft(7)}'
        '  ${(m.accepted ? 'oui' : 'non').padLeft(7)}'
        '  ${regime.name}',
      );
    }
  }
  if (remplissages.isEmpty) return;
  remplissages.sort();
  print('');
  print(
    'scènes composées — min ${(remplissages.first * 100).toStringAsFixed(1)} %'
    ' · médiane ${(remplissages[remplissages.length ~/ 2] * 100).toStringAsFixed(1)} %',
  );
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage : dart run tool/fill_bench.dart <dossier|image>…');
    exitCode = 64;
    return;
  }

  final fichiers = <File>[];
  for (final chemin in args) {
    final dir = Directory(chemin);
    if (dir.existsSync()) {
      fichiers.addAll(
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.toLowerCase().endsWith('.jpg') ||
                  f.path.toLowerCase().endsWith('.png'),
            ),
      );
    } else {
      final f = File(chemin);
      if (f.existsSync()) fichiers.add(f);
    }
  }

  print('${fichiers.length} images');
  print('');
  print('  remplissage  rapport  retenue  fichier');

  final remplissages = <double>[];
  for (final f in fichiers..sort((a, b) => a.path.compareTo(b.path))) {
    final m = _mesure(f, 'magic');
    if (m == null) continue;
    remplissages.add(m.fill);
    final nom = f.uri.pathSegments.last;
    print(
      '  ${(m.fill * 100).toStringAsFixed(1).padLeft(10)} %'
      '  ${m.aspect.isNaN ? '    —' : m.aspect.toStringAsFixed(3).padLeft(7)}'
      '  ${(m.accepted ? 'oui' : 'non').padLeft(7)}'
      '  $nom',
    );
  }

  if (fichiers.length > 20) _scenes(fichiers, 5);

  if (remplissages.isEmpty) return;
  remplissages.sort();
  double q(double p) => remplissages[(p * (remplissages.length - 1)).round()];
  print('');
  print(
    'remplissage — min ${(remplissages.first * 100).toStringAsFixed(1)} %'
    ' · q10 ${(q(0.10) * 100).toStringAsFixed(1)} %'
    ' · médiane ${(q(0.50) * 100).toStringAsFixed(1)} %'
    ' · max ${(remplissages.last * 100).toStringAsFixed(1)} %',
  );
}
