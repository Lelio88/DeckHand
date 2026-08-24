/// Ce que coûte l'index d'empreintes AVANT de reconnaître quoi que ce soit.
///
/// **Pourquoi ce banc.** Le temps qui sépare l'appui sur « Scanner » de la
/// première image vidéo n'est pas passé à reconnaître : il est passé à lire un
/// cache, à le décoder, et à ouvrir une caméra. Ces trois coûts se mesurent
/// séparément, et deux d'entre eux sont du calcul pur — donc mesurables ici,
/// sans téléphone.
///
/// Ce que ce banc NE mesure pas, et qu'il faut donc mesurer sur l'appareil :
/// le temps de `SharedPreferences.getInstance()` (qui charge tout le fichier de
/// préférences, index compris) et celui de `CameraController.initialize()`.
///
/// Usage :
///
///     cd app && dart run tool/index_bench.dart
///     cd app && dart run tool/index_bench.dart --entries 49067
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';

/// Empreintes réellement en base, relevées le 2026-08-24.
const Map<String, int> parJeu = {
  'magic': 49067,
  'pokemon': 19326,
  'yugioh': 13866,
  'swu': 5282,
  'onepiece': 3933,
  'lorcana': 3192,
  'riftbound': 1193,
  'wankul': 958,
};

/// Un index de la taille demandée, aux identifiants de la longueur réelle
/// (UUID de 36 caractères, deux par entrée).
ArtHashIndex fabrique(int n) {
  final entries = <IndexEntry>[];
  for (var i = 0; i < n; i++) {
    final id = 'aaaaaaaa-bbbb-cccc-dddd-${i.toString().padLeft(12, '0')}';
    entries.add((
      oracleId: id,
      printId: id,
      hash: ArtHash(
        Uint8List.fromList([
          for (var b = 0; b < 8; b++) (i >> (b * 8)) & 0xff,
        ]),
      ),
    ));
  }
  return ArtHashIndex.fromEntries(entries);
}

Duration chrono(void Function() f) {
  final t = Stopwatch()..start();
  f();
  return t.elapsed;
}

void main(List<String> args) {
  final seul = args.contains('--entries')
      ? int.parse(args[args.indexOf('--entries') + 1])
      : null;

  print('Coût du cache d\'index, par jeu — décodage pur, hors réseau.\n');
  print('${'jeu'.padRight(11)}${'entrées'.padLeft(8)}'
      '${'binaire'.padLeft(10)}${'base64'.padLeft(10)}'
      '${'b64→oct'.padLeft(10)}${'oct→index'.padLeft(11)}'
      '${'total'.padLeft(9)}');

  final cibles = seul != null ? {'sur mesure': seul} : parJeu;
  var totalOctets = 0;
  var totalMs = 0;

  for (final entry in cibles.entries) {
    final index = fabrique(entry.value);
    final bytes = index.toBytes();
    final b64 = base64Encode(bytes);

    // Trois passes, on garde la plus rapide : la première paie le JIT.
    var decode = const Duration(days: 1);
    var relit = const Duration(days: 1);
    late Uint8List octets;
    for (var i = 0; i < 3; i++) {
      final d = chrono(() => octets = base64Decode(b64));
      if (d < decode) decode = d;
      final r = chrono(() => ArtHashIndex.fromBytes(octets));
      if (r < relit) relit = r;
    }

    final total = decode + relit;
    totalOctets += b64.length;
    totalMs += total.inMilliseconds;
    print('${entry.key.padRight(11)}'
        '${entry.value.toString().padLeft(8)}'
        '${'${(bytes.length / 1024).round()} Kio'.padLeft(10)}'
        '${'${(b64.length / 1024).round()} Kio'.padLeft(10)}'
        '${'${decode.inMilliseconds} ms'.padLeft(10)}'
        '${'${relit.inMilliseconds} ms'.padLeft(11)}'
        '${'${total.inMilliseconds} ms'.padLeft(9)}');
  }

  if (seul == null) {
    print('\nLes huit jeux mis en cache pèsent '
        '${(totalOctets / 1024 / 1024).toStringAsFixed(1)} Mio de base64 dans '
        'les préférences.');
    print('Décoder le seul jeu courant coûte de 2 à '
        '$totalMs ms selon lequel — sur un poste. '
        'Sur téléphone, compter trois à cinq fois plus.');
    print('\nCe chiffre est un plancher : il ne compte pas la lecture du '
          'fichier de préférences, qui les porte TOUS.');
  }
}
