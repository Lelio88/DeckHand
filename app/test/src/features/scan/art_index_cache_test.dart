/// Tests de la sérialisation du cache d'index.
///
/// Le cache doit survivre à un redémarrage **et** résister à la corruption : des
/// octets tronqués doivent être traités comme un cache absent, jamais faire
/// échouer le démarrage du scan.
///
/// Le stockage lui-même (`shared_preferences`) n'est pas testé ici — c'est du
/// code de plateforme. Ce qui est vérifié est l'aller-retour de la donnée, y
/// compris son encodage base64, seul endroit où une erreur nous appartiendrait.
library;

import 'dart:convert';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:flutter_test/flutter_test.dart';

ArtHashIndex sampleIndex() => ArtHashIndex.fromEntries([
  (oracleId: 'bolt', printId: 'bolt', hash: ArtHash.fromHex('0000000000000000')),
  (oracleId: 'ring', printId: 'ring', hash: ArtHash.fromHex('FFFFFFFFFFFFFFFF')),
  (oracleId: 'island', printId: 'island', hash: ArtHash.fromHex('AAAAAAAAAAAAAAAA')),
]);

void main() {
  test('un index encodé puis décodé est identique', () {
    final encoded = base64Encode(sampleIndex().toBytes());
    final restored = ArtHashIndex.fromBytes(base64Decode(encoded));

    expect(restored.length, 3);
    expect(
      restored.search(ArtHash.fromHex('AAAAAAAAAAAAAAAA')).best?.oracleId,
      'island',
    );
  });

  test('des octets tronqués sont rejetés proprement', () {
    final bytes = sampleIndex().toBytes();
    expect(
      () => ArtHashIndex.fromBytes(bytes.sublist(0, bytes.length ~/ 2)),
      throwsArgumentError,
    );
  });

  test('un contenu vide est rejeté proprement', () {
    expect(() => ArtHashIndex.fromBytes(base64Decode('')), throwsArgumentError);
  });

  test("l'encodage base64 gonfle d'environ un tiers", () {
    final raw = sampleIndex().toBytes().length;
    final encoded = base64Encode(sampleIndex().toBytes()).length;
    expect(encoded, lessThan(raw * 1.4));
  });
}
