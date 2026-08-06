/// Vérifie la parité Dart/Python des empreintes sur de **vraies** illustrations.
///
/// Les tests unitaires utilisent des images synthétiques construites en mémoire :
/// ils prouvent que **l'algorithme** est identique des deux côtés, au bit près.
///
/// Cet outil mesure autre chose — l'effet du **décodage JPEG**. Pillow et le
/// paquet Dart ne reconstituent pas exactement les mêmes pixels à partir d'un
/// même fichier, ce que la norme JPEG autorise (tolérances d'arrondi sur l'IDCT
/// et le suréchantillonnage de chrominance). Une parité stricte est donc
/// inatteignable, et ce n'est pas un défaut à corriger.
///
/// Ce qui compte est que l'écart reste **petit devant la séparation entre
/// cartes** (une quinzaine de bits). Au-delà de [maxAcceptableDistance], ce
/// n'est plus un arrondi de décodeur : c'est que l'algorithme a divergé.
///
/// Usage :
///   1. côté Python, produire un dossier d'images et un `hashes.json`
///      (`{ "fichier.jpg": "2688329832E973C9", ... }`)
///   2. `dart run tool/verify_parity.dart <dossier>`
///
/// Les images ne sont jamais versionnées : elles proviennent de Scryfall et le
/// dépôt est public.
library;

import 'dart:convert';
import 'dart:io';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:image/image.dart' as img;

/// Écart maximal imputable au décodeur. Au-delà, l'algorithme lui-même diverge.
const int maxAcceptableDistance = 8;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage : dart run tool/verify_parity.dart <dossier>');
    exit(64);
  }

  final directory = Directory(args.first);
  final manifest = File('${directory.path}/hashes.json');
  if (!manifest.existsSync()) {
    stderr.writeln('hashes.json introuvable dans ${directory.path}');
    exit(66);
  }

  final expected = (jsonDecode(manifest.readAsStringSync()) as Map)
      .cast<String, dynamic>();

  var identical = 0;
  final distances = <int>[];
  final divergences =
      <String, ({String expected, String actual, int distance})>{};

  for (final entry in expected.entries) {
    final file = File('${directory.path}/${entry.key}');
    if (!file.existsSync()) continue;

    final decoded = img.decodeImage(file.readAsBytesSync());
    if (decoded == null) {
      stderr.writeln('illisible : ${entry.key}');
      continue;
    }

    final actual = computeArtHash(decoded);
    final reference = ArtHash.fromHex(entry.value as String);

    final distance = actual.distanceTo(reference);
    distances.add(distance);
    if (distance == 0) identical++;
    if (distance > maxAcceptableDistance) {
      divergences[entry.key] = (
        expected: reference.toHex(),
        actual: actual.toHex(),
        distance: distance,
      );
    }
  }

  if (distances.isEmpty) {
    stderr.writeln('aucune illustration comparée');
    exit(66);
  }

  final sorted = [...distances]..sort();
  final mean = distances.reduce((a, b) => a + b) / distances.length;

  stdout.writeln('illustrations comparées : ${distances.length}');
  stdout.writeln('empreintes identiques   : $identical');
  stdout.writeln(
    'écart de décodage — médiane ${sorted[sorted.length ~/ 2]}, '
    'moyenne ${mean.toStringAsFixed(1)}, max ${sorted.last} bits',
  );

  if (divergences.isNotEmpty) {
    stdout.writeln(
      'ÉCARTS ANORMAUX (> $maxAcceptableDistance bits) : ${divergences.length}',
    );
    for (final e in divergences.entries.take(5)) {
      stdout.writeln(
        '  ${e.key} : attendu ${e.value.expected}, obtenu ${e.value.actual} '
        '(${e.value.distance} bits)',
      );
    }
    exit(1);
  }

  stdout.writeln(
    'écart conforme : imputable au décodeur JPEG, pas à l\'algorithme',
  );
}
