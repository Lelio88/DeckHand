/// Tests de la politique de suivi du quadrilatère (#8).
///
/// Chaque cas correspond à un comportement que le banc de flux
/// (`tool/stream_bench.dart`) a mesuré, ou à un défaut qu'il a mis au jour. Les
/// valeurs par défaut, elles, ne sont pas testées : ce sont des réglages, et
/// les figer dans un test ferait passer un choix pour une propriété.
library;

import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/quad_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Une empreinte dont [bits] premiers bits valent 1 : deux empreintes ainsi
/// construites sont à une distance égale à la différence de leurs comptes.
ArtHash hashOf(int bits) {
  final bytes = Uint8List(hashBytes);
  for (var i = 0; i < bits; i++) {
    bytes[i ~/ 8] |= 1 << (7 - (i % 8));
  }
  return ArtHash(bytes);
}

CardQuad quadAt(double x) => CardQuad(
  topLeft: (x: x, y: 0),
  topRight: (x: x + 10, y: 0),
  bottomRight: (x: x + 10, y: 14),
  bottomLeft: (x: x, y: 14),
);

void main() {
  group('QuadTracker', () {
    test('réclame une détection tant qu\'il ne tient rien', () {
      expect(QuadTracker().needsDetection, isTrue);
    });

    test('ne réclame plus rien une fois un quadrilatère adopté', () {
      final tracker = QuadTracker(maxAge: 5)..adopt(quadAt(0));
      expect(tracker.needsDetection, isFalse);
      expect(tracker.quad, isNotNull);
    });

    test('une détection infructueuse laisse le suivi en demande', () {
      final tracker = QuadTracker()
        ..adopt(quadAt(0))
        ..adopt(null);
      expect(tracker.quad, isNull);
      expect(tracker.needsDetection, isTrue);
    });

    test('réclame une détection quand le quadrilatère atteint son âge', () {
      final tracker = QuadTracker(maxAge: 3)..adopt(quadAt(0));
      for (var i = 0; i < 3; i++) {
        expect(tracker.needsDetection, isFalse, reason: 'image $i');
        tracker.keep(hashOf(0));
      }
      expect(tracker.needsDetection, isTrue);
      expect(tracker.age, 3);
    });

    test('adopter remet l\'âge à zéro', () {
      final tracker = QuadTracker(maxAge: 2)..adopt(quadAt(0));
      tracker
        ..keep(hashOf(0))
        ..keep(hashOf(0));
      expect(tracker.needsDetection, isTrue);
      tracker.adopt(quadAt(5));
      expect(tracker.age, 0);
      expect(tracker.needsDetection, isFalse);
    });

    test('la première empreinte après une détection ne saute jamais', () {
      // Il n'y a rien à comparer, et le quadrilatère vient d'être établi sur
      // cette image même : le déclarer sauté ferait redétecter deux fois de
      // suite, sans fin.
      final tracker = QuadTracker(jumpBits: 4)..adopt(quadAt(0));
      expect(tracker.jumped(hashOf(60)), isFalse);
    });

    test('une nouvelle détection efface l\'empreinte de référence', () {
      // **Le défaut que le compteur du banc a trahi.** Deux empreintes prises à
      // travers deux quadrilatères différents ne se comparent pas ; les garder
      // comparables déclenchait un faux saut juste après chaque détection
      // forcée par l'âge, et donc une seconde détection sur la même image.
      final tracker = QuadTracker(jumpBits: 4, maxAge: 2)..adopt(quadAt(0));
      tracker
        ..keep(hashOf(0))
        ..keep(hashOf(0));
      expect(tracker.needsDetection, isTrue, reason: 'âge atteint');

      tracker.adopt(quadAt(30)); // la détection rend un quadrilatère décalé
      expect(
        tracker.jumped(hashOf(40)),
        isFalse,
        reason: 'rien à comparer : le quadrilatère vient de changer',
      );
    });

    test('une empreinte stable ne saute pas', () {
      final tracker = QuadTracker(jumpBits: 4)
        ..adopt(quadAt(0))
        ..keep(hashOf(10));
      expect(tracker.jumped(hashOf(12)), isFalse);
    });

    test('un écart strictement supérieur au seuil saute', () {
      final tracker = QuadTracker(jumpBits: 4)
        ..adopt(quadAt(0))
        ..keep(hashOf(10));
      expect(tracker.jumped(hashOf(14)), isFalse, reason: '4 bits : au seuil');
      expect(tracker.jumped(hashOf(15)), isTrue, reason: '5 bits : au-delà');
    });

    test('un échange de carte saute largement', () {
      // Mesuré au banc : une carte immobile fait varier l'empreinte de 1 à
      // 2 bits, un échange de 35. Le seuil se pose dans ce fossé.
      final tracker = QuadTracker(jumpBits: 12)
        ..adopt(quadAt(0))
        ..keep(hashOf(0));
      expect(tracker.jumped(hashOf(35)), isTrue);
    });

    test('une détection infructueuse efface l\'empreinte de référence', () {
      // Sans cet effacement, la première empreinte suivant le retour de la
      // carte serait comparée à celle d'avant sa disparition — deux instants
      // sans rapport.
      final tracker = QuadTracker(jumpBits: 4)
        ..adopt(quadAt(0))
        ..keep(hashOf(0))
        ..adopt(null)
        ..adopt(quadAt(0));
      expect(tracker.jumped(hashOf(60)), isFalse);
    });

    test('une dérive lente ne saute jamais, et seul l\'âge la rattrape', () {
      // **Le défaut que le banc a mesuré.** Chaque pas reste sous le seuil et
      // pourtant ils s'accumulent : après douze images, l'empreinte s'est
      // éloignée de 24 bits sans qu'un seul saut se soit produit. Aucun seuil
      // ne peut voir cela — c'est structurel.
      final sansAge = QuadTracker(jumpBits: 4, maxAge: 1 << 30)
        ..adopt(quadAt(0));
      var bits = 0;
      var sauts = 0;
      for (var i = 0; i < 12; i++) {
        bits += 2;
        if (sansAge.jumped(hashOf(bits))) sauts++;
        sansAge.keep(hashOf(bits));
      }
      expect(sauts, 0, reason: 'chaque pas vaut 2 bits, le seuil en vaut 4');
      expect(bits, 24, reason: 'et pourtant l\'écart cumulé est grand');
      expect(sansAge.needsDetection, isFalse, reason: 'sans âge, rien ne le rattrape');

      final avecAge = QuadTracker(jumpBits: 4, maxAge: 5)..adopt(quadAt(0));
      for (var i = 0; i < 5; i++) {
        avecAge.keep(hashOf(i));
      }
      expect(avecAge.needsDetection, isTrue);
    });

    test('reset rend le suivi à son état initial', () {
      final tracker = QuadTracker()
        ..adopt(quadAt(0))
        ..keep(hashOf(3))
        ..reset();
      expect(tracker.quad, isNull);
      expect(tracker.age, 0);
      expect(tracker.needsDetection, isTrue);
    });
  });
}
