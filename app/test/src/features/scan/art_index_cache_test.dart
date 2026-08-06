/// Tests du cache local de l'index.
///
/// Le cache doit survivre à un redémarrage **et** résister à la corruption : un
/// fichier tronqué doit être traité comme un cache absent, jamais faire échouer
/// le démarrage du scan.
library;

import 'dart:io';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:flutter_test/flutter_test.dart';

ArtHashIndex sampleIndex() => ArtHashIndex.fromEntries([
  (oracleId: 'bolt', hash: ArtHash.fromHex('0000000000000000')),
  (oracleId: 'ring', hash: ArtHash.fromHex('FFFFFFFFFFFFFFFF')),
  (oracleId: 'island', hash: ArtHash.fromHex('AAAAAAAAAAAAAAAA')),
]);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('deckhand_cache'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('un index écrit puis relu est identique', () {
    final file = File('${temp.path}/index.bin')
      ..writeAsBytesSync(sampleIndex().toBytes());

    final restored = ArtHashIndex.fromBytes(file.readAsBytesSync());

    expect(restored.length, 3);
    expect(
      restored.search(ArtHash.fromHex('AAAAAAAAAAAAAAAA')).best?.oracleId,
      'island',
    );
  });

  test('un fichier tronqué est rejeté proprement', () {
    final bytes = sampleIndex().toBytes();
    final truncated = bytes.sublist(0, bytes.length ~/ 2);

    expect(() => ArtHashIndex.fromBytes(truncated), throwsArgumentError);
  });

  test('un fichier vide est rejeté proprement', () {
    final file = File('${temp.path}/vide.bin')..writeAsBytesSync([]);
    expect(
      () => ArtHashIndex.fromBytes(file.readAsBytesSync()),
      throwsArgumentError,
    );
  });

  test('la taille du cache reste raisonnable', () {
    // 8 octets d'empreinte + 1 de longueur + l'identifiant, plus l'en-tête.
    final bytes = sampleIndex().toBytes();
    expect(bytes.length, lessThan(3 * 40));
  });
}
