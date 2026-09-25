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
  (oracleId: 'bolt', printId: 'bolt', hash: h('0000000000000000')),
  (oracleId: 'ring', printId: 'ring', hash: h('FFFFFFFFFFFFFFFF')),
  (oracleId: 'island', printId: 'island', hash: h('AAAAAAAAAAAAAAAA')),
  (oracleId: 'forest', printId: 'forest', hash: h('0F0F0F0F0F0F0F0F')),
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
          (oracleId: 'bolt', printId: 'bolt', hash: h('0000000000000000')),
          (oracleId: 'sosie', printId: 'sosie', hash: h('0000000000000001')),
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
        (oracleId: 'bolt', printId: 'bolt', hash: h('0000000000000000')),
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

  group('plusieurs hypothèses de découpage', () {
    // **Le cas réel qui a motivé ces tests.** Une carte japonaise premium de
    // 2002 : le bon gabarit plaçait la bonne carte en tête à 14 bits, un
    // découpage absurde — cadre moderne lu à l'envers — tombait par hasard à
    // 11 bits d'une carte sans rapport. Le hasard gagnait, et la liste du bon
    // gabarit était jetée en entier : la bonne réponse disparaissait de
    // l'écran au lieu d'y figurer parmi les candidats.
    final index = ArtHashIndex.fromEntries([
      (oracleId: 'cible', printId: 'cible', hash: h('0000000000000000')),
      (oracleId: 'sosie', printId: 'sosie', hash: h('FFFFFFFFFFFFFFFF')),
    ]);

    /// À 14 bits de « cible », 50 de « sosie » — le bon gabarit, dégradé.
    final bonGabarit = h('0000000000003FFF');

    /// À 11 bits de « sosie », 53 de « cible » — le découpage absurde, chanceux.
    final gabaritAbsurde = h('FFFFFFFFFFFFF800');

    test('la carte du gabarit perdant reste dans les candidats', () {
      final outcome = index.searchAny({
        'legacy': bonGabarit,
        'modern+2': gabaritAbsurde,
      }, limit: 3);

      expect(
        outcome.result.candidates.map((c) => c.oracleId),
        containsAll(<String>['sosie', 'cible']),
        reason:
            'une carte ne doit pas disparaître parce qu\'un autre découpage a '
            'mieux marché ailleurs',
      );
    });

    test('les candidats fusionnés restent classés par distance', () {
      final outcome = index.searchAny({
        'legacy': bonGabarit,
        'modern+2': gabaritAbsurde,
      }, limit: 3);

      expect(outcome.result.candidates.first.oracleId, 'sosie');
      expect(outcome.result.candidates.first.distance, 11);
      expect(outcome.result.candidates[1].oracleId, 'cible');
      expect(outcome.result.candidates[1].distance, 14);
    });

    test('un autre découpage presque aussi bon retire la confiance', () {
      // Pris seul, le vainqueur a 42 bits de marge. Fusionnés, les deux
      // premiers sont à 11 et 14 : 3 bits d'écart, sous `minConfidenceMargin`.
      // Et c'est bien le hasard qui gagne ici — la carte tenue est « cible » :
      // l'affirmer « sosie » serait l'annonce fausse que la seconde marge
      // existe pour empêcher.
      final outcome = index.searchAny({
        'legacy': bonGabarit,
        'modern+2': gabaritAbsurde,
      }, limit: 3);

      expect(outcome.source, 'modern+2');
      expect(outcome.isConfident, isFalse);
    });

    test('une reconnaissance franche garde sa confiance malgré le bruit', () {
      // La japonaise sans pochette : la bonne carte à 6 bits, un découpage
      // absurde à 11 bits d'une autre — 5 bits de marge fusionnée, au-dessus
      // du seuil. Le bruit d'un autre gabarit ne suffit pas à la rendre
      // douteuse.
      final outcome = index.searchAny({
        'legacy': h('000000000000003F'),
        'modern+2': gabaritAbsurde,
      }, limit: 3);

      expect(outcome.source, 'legacy');
      expect(outcome.result.best?.oracleId, 'cible');
      expect(outcome.result.margin, 5);
      expect(outcome.isConfident, isTrue);
    });

    test('une hypothèse non éligible ne peut plus régner', () {
      final outcome = index.searchAny(
        {'legacy': bonGabarit, 'modern+2': gabaritAbsurde},
        limit: 3,
        eligibles: {'legacy'},
      );

      expect(outcome.source, 'legacy');
      expect(
        outcome.isConfident,
        isFalse,
        reason: '14 bits dépassent maxTrustedDistance',
      );
      expect(
        outcome.result.candidates.first.oracleId,
        'cible',
        reason: 'la bonne carte reprend la tête dès que le bruit se tait',
      );
      // « sosie » reste présent, mais à la distance que lui donne le *bon*
      // découpage — 50 bits — et non les 11 que lui valait le découpage
      // absurde. C'est là toute la différence : le bruit ne la devance plus.
      final sosie = outcome.result.candidates.firstWhere(
        (c) => c.oracleId == 'sosie',
      );
      expect(sosie.distance, 50);
    });

    test('sans hypothèse éligible trouvée, les candidats survivent', () {
      final outcome = index.searchAny(
        {'modern+2': gabaritAbsurde},
        limit: 3,
        eligibles: const {'legacy'},
      );

      expect(outcome.source, isNull);
      expect(outcome.isConfident, isFalse);
      expect(outcome.result.candidates, isNotEmpty);
    });
  });
}
