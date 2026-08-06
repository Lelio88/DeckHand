/// Tests de la recherche d'empreinte dans l'index.
///
/// Le point sensible n'est pas de trouver le plus proche — c'est de savoir
/// **quand se taire**. Une carte absente de l'index aura toujours un plus proche
/// voisin ; le proposer serait un faux positif, et l'utilisateur enregistrerait
/// une carte qu'il ne possède pas.
library;

import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:flutter_test/flutter_test.dart';

/// Construit une empreinte depuis un motif de bits décrit en hexadécimal.
ArtHash h(String hex) => ArtHash.fromHex(hex);

ArtHashIndex buildIndex() => ArtHashIndex.fromEntries([
  (oracleId: 'bolt', hash: h('0000000000000000')),
  (oracleId: 'ring', hash: h('FFFFFFFFFFFFFFFF')),
  (oracleId: 'island', hash: h('AAAAAAAAAAAAAAAA')),
  (oracleId: 'forest', hash: h('0F0F0F0F0F0F0F0F')),
]);

void main() {
  group('recherche', () {
    test('une empreinte exacte retrouve sa carte à distance nulle', () {
      final result = buildIndex().search(h('AAAAAAAAAAAAAAAA'));
      expect(result.best?.oracleId, 'island');
      expect(result.best?.distance, 0);
    });

    test('une empreinte légèrement altérée retrouve la bonne carte', () {
      // Un bit modifié par rapport à « bolt ».
      final result = buildIndex().search(h('0000000000000001'));
      expect(result.best?.oracleId, 'bolt');
      expect(result.best?.distance, 1);
    });

    test('les candidats sont classés par distance croissante', () {
      final result = buildIndex().search(h('0000000000000003'), limit: 3);
      expect(result.candidates.map((c) => c.oracleId).first, 'bolt');
      final distances = result.candidates.map((c) => c.distance).toList();
      expect(distances, orderedEquals([...distances]..sort()));
    });

    test('le nombre de candidats est limité', () {
      expect(
        buildIndex().search(h('0000000000000000'), limit: 2).candidates.length,
        2,
      );
    });

    test('un index vide ne renvoie aucun candidat', () {
      final result = ArtHashIndex.fromEntries([]).search(h('0000000000000000'));
      expect(result.candidates, isEmpty);
      expect(result.best, isNull);
      expect(result.isConfident, isFalse);
    });
  });

  group('confiance', () {
    test('une correspondance proche et bien détachée est fiable', () {
      // Distance 1 de « bolt », très loin des autres.
      final result = buildIndex().search(h('0000000000000001'));
      expect(result.isConfident, isTrue);
    });

    test('une correspondance trop lointaine n\'est pas fiable', () {
      // À mi-chemin de tout : la carte photographiée n'est pas dans l'index.
      final result = buildIndex().search(h('5555555533333333'));
      expect(result.best!.distance, greaterThan(maxTrustedDistance));
      expect(result.isConfident, isFalse);
    });

    test(
      'deux candidats trop proches l\'un de l\'autre rendent le choix douteux',
      () {
        // « bolt » et son quasi-jumeau : le second est à 1 bit du premier.
        final index = ArtHashIndex.fromEntries([
          (oracleId: 'bolt', hash: h('0000000000000000')),
          (oracleId: 'sosie', hash: h('0000000000000001')),
        ]);
        final result = index.search(h('0000000000000000'));
        expect(result.best?.oracleId, 'bolt');
        expect(
          result.isConfident,
          isFalse,
          reason: 'une marge d\'un seul bit ne permet pas de trancher',
        );
      },
    );

    test('un candidat unique proche est fiable, faute de concurrent', () {
      final index = ArtHashIndex.fromEntries([
        (oracleId: 'bolt', hash: h('0000000000000000')),
      ]);
      expect(index.search(h('0000000000000001')).isConfident, isTrue);
    });
  });

  group('construction', () {
    test('la taille de l\'index est exposée', () {
      expect(buildIndex().length, 4);
    });

    test('un index se sérialise et se relit à l\'identique', () {
      final original = buildIndex();
      final restored = ArtHashIndex.fromBytes(original.toBytes());

      expect(restored.length, original.length);
      final result = restored.search(h('AAAAAAAAAAAAAAAA'));
      expect(result.best?.oracleId, 'island');
      expect(result.best?.distance, 0);
    });

    test('des octets tronqués sont refusés', () {
      expect(
        () => ArtHashIndex.fromBytes(Uint8List.fromList([1, 2, 3])),
        throwsArgumentError,
      );
    });
  });
}
