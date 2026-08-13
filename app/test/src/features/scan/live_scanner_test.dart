/// Tests de la reconnaissance au fil de la caméra (#8).
///
/// **Ce qui est vérifié est la couture, pas les pièces.** Chaque élément —
/// détection, empreinte, index, suivi du quadrilatère — a son propre banc et
/// ses propres tests. Ce qu'aucun d'eux ne couvre est leur assemblage : qu'une
/// carte posée devant l'objectif soit retenue **une fois**, que le silence de
/// l'index n'alimente pas de série, et que le blanc entre deux cartes soit vu
/// par le suivi temporel.
///
/// Les plans de luminance sont synthétiques — un rectangle sombre sur fond
/// clair, avec le pas de ligne d'un vrai capteur, qui dépasse la largeur. C'est
/// assez pour que la détection trouve quatre coins ; ce qui se passe sur du
/// carton relève du banc, pas d'un test unitaire.
library;

import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_tracker.dart';
import 'package:deckhand/src/features/scan/domain/camera_frame.dart';
import 'package:deckhand/src/features/scan/domain/live_scanner.dart';
import 'package:deckhand/src/features/scan/domain/quad_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

const width = 1280, height = 720, rowStride = 1408;

/// Un plan de luminance portant une carte, ou rien.
///
/// [shade] fait varier l'illustration : deux valeurs différentes donnent deux
/// empreintes différentes, ce qui suffit à jouer un échange de carte.
Uint8List plane({int? shade, int left = 400, int top = 100}) {
  final luma = Uint8List(rowStride * height)
    ..fillRange(0, rowStride * height, 170);
  if (shade == null) return luma;

  const w = 322, h = 450;
  for (var y = top; y < top + h; y++) {
    for (var x = left; x < left + w; x++) {
      // Un damier dont le pas dépend de la teinte : l'empreinte compare des
      // voisins, un aplat uniforme ne lui donnerait rien à comparer.
      final step = 6 + shade;
      luma[y * rowStride + x] = ((x ~/ step + y ~/ step) % 2 == 0)
          ? 18 + shade
          : 60 + shade;
    }
  }
  return luma;
}

/// L'empreinte qu'une carte de [shade] produit, telle que l'index doit la
/// porter pour que la reconnaissance aboutisse.
ArtHash hashOfPlane(int shade) {
  final luma = plane(shade: shade);
  final quad = findCardInLuma(
    luma,
    width: width,
    height: height,
    rowStride: rowStride,
  )!;
  return artHashFromLuma(
    sampleArtFromLuma(
      luma,
      width: width,
      height: height,
      rowStride: rowStride,
      quad: quad,
      box: CardFrame.modern.box,
    ),
    width: 256,
    height: 190,
    rowStride: 256,
  );
}

/// Un index qui contient les cartes nommées, et rien d'autre de proche.
///
/// Le remplissage garantit que `margin` a de quoi se calculer : un index d'une
/// seule entrée rendrait toute reconnaissance « sûre » par absence de rival, ce
/// qui ne ressemble pas à l'index réel.
ArtHashIndex indexOf(Map<String, int> cards) {
  final entries = <({String oracleId, ArtHash hash})>[
    for (final e in cards.entries) (oracleId: e.key, hash: hashOfPlane(e.value)),
    for (var i = 0; i < 200; i++)
      (
        oracleId: 'bourrage-$i',
        hash: ArtHash(
          Uint8List.fromList([
            for (var b = 0; b < hashBytes; b++) (i * 37 + b * 11) % 256,
          ]),
        ),
      ),
  ];
  return ArtHashIndex.fromEntries(entries);
}

LiveObservation feed(LiveScanner scanner, Uint8List luma) => scanner.observe(
  luma,
  width: width,
  height: height,
  rowStride: rowStride,
);

void main() {
  group('une carte posée', () {
    test('est retenue une fois, pas trente', () {
      // Le mode photo voit une carte une fois ; le flux la voit trente fois par
      // seconde. Sans règle temporelle, poser une carte remplirait le panier de
      // trente exemplaires.
      final scanner = LiveScanner(index: indexOf({'alpha': 0}));
      final carte = plane(shade: 0);

      final retenues = [
        for (var i = 0; i < 30; i++) feed(scanner, carte).accepted,
      ].whereType<String>().toList();

      expect(retenues, ['alpha']);
    });

    test('est vue avant d\'être retenue', () {
      // L'écran doit pouvoir dire ce que l'appareil regarde, sinon
      // l'utilisateur ne sait pas si la carte est mal posée ou si
      // l'application réfléchit encore.
      final scanner = LiveScanner(
        index: indexOf({'alpha': 0}),
        cards: CardTracker(minFrames: 4),
      );
      final carte = plane(shade: 0);

      final first = feed(scanner, carte);
      expect(first.watching, 'alpha');
      expect(first.accepted, isNull);
      expect(first.streak, 1);
      expect(first.located, isTrue);
    });

    test('le suivi épargne des détections', () {
      // C'est tout l'objet de `QuadTracker` : la mesure disait 12,3 ms contre
      // 27,4. Ici on vérifie seulement que la détection ne tourne pas à chaque
      // image — le chiffre, lui, se mesure au banc.
      final scanner = LiveScanner(index: indexOf({'alpha': 0}));
      final carte = plane(shade: 0);

      final detections = [
        for (var i = 0; i < 20; i++) feed(scanner, carte).detected,
      ].where((d) => d).length;

      expect(detections, lessThan(20));
      expect(detections, greaterThan(0));
    });
  });

  group('deux cartes', () {
    test('un échange après un blanc compte pour deux', () {
      final scanner = LiveScanner(index: indexOf({'alpha': 0, 'beta': 40}));
      final retenues = <String>[];

      void jouer(Uint8List luma, int images) {
        for (var i = 0; i < images; i++) {
          final seen = feed(scanner, luma);
          if (seen.accepted != null) retenues.add(seen.accepted!);
        }
      }

      jouer(plane(shade: 0), 12);
      jouer(plane(), 8); // la main retire la carte
      jouer(plane(shade: 40), 12);

      expect(retenues, ['alpha', 'beta']);
    });

    test('le même exemplaire reposé après un blanc compte pour deux', () {
      // **C'est le cas qui décide de la justesse d'une collection.** Deux
      // exemplaires identiques passés l'un après l'autre sont deux cartes ; les
      // confondre en perdrait une, et les compter sans blanc en inventerait.
      final scanner = LiveScanner(index: indexOf({'alpha': 0}));
      final retenues = <String>[];

      for (final luma in [
        ...List.filled(12, plane(shade: 0)),
        ...List.filled(8, plane()),
        ...List.filled(12, plane(shade: 0)),
      ]) {
        final seen = feed(scanner, luma);
        if (seen.accepted != null) retenues.add(seen.accepted!);
      }

      expect(retenues, ['alpha', 'alpha']);
    });
  });

  group('le champ vide', () {
    test('ne retient rien et ne plante pas', () {
      final scanner = LiveScanner(index: indexOf({'alpha': 0}));
      final vide = plane();

      for (var i = 0; i < 10; i++) {
        final seen = feed(scanner, vide);
        expect(seen.accepted, isNull);
        expect(seen.located, isFalse);
      }
    });

    test('est vu par le suivi temporel', () {
      // Le blanc entre deux cartes est ce qui autorise la suivante à être
      // retenue : le cacher au suivi ferait passer deux exemplaires pour un.
      final scanner = LiveScanner(index: indexOf({'alpha': 0}));
      for (var i = 0; i < 12; i++) {
        feed(scanner, plane(shade: 0));
      }
      for (var i = 0; i < 8; i++) {
        feed(scanner, plane());
      }
      final retour = [
        for (var i = 0; i < 12; i++) feed(scanner, plane(shade: 0)).accepted,
      ].whereType<String>();

      expect(retour, ['alpha']);
    });
  });

  group('le silence de l\'index', () {
    test('n\'alimente aucune série', () {
      // Une carte absente de l'index a toujours un plus proche voisin ; c'est
      // la marge de confiance qui la refuse. Une reconnaissance refusée ne doit
      // pas compter comme une image vue sur cette carte.
      final scanner = LiveScanner(index: indexOf({'alpha': 0}));
      final inconnue = plane(shade: 40);

      final retenues = [
        for (var i = 0; i < 30; i++) feed(scanner, inconnue).accepted,
      ].whereType<String>();

      expect(retenues, isEmpty);
    });
  });

  group('remise à zéro', () {
    test('la première carte du lot suivant ne suit pas la précédente', () {
      final scanner = LiveScanner(index: indexOf({'alpha': 0}));
      for (var i = 0; i < 12; i++) {
        feed(scanner, plane(shade: 0));
      }
      scanner.reset();
      expect(scanner.watching, isNull);

      final retenues = [
        for (var i = 0; i < 12; i++) feed(scanner, plane(shade: 0)).accepted,
      ].whereType<String>();
      expect(retenues, ['alpha']);
    });
  });

  group('les seuils sont ceux qu\'on lui donne', () {
    test('un minimum plus haut retarde la retenue', () {
      final scanner = LiveScanner(
        index: indexOf({'alpha': 0}),
        quads: QuadTracker(),
        cards: CardTracker(minFrames: 9, gapFrames: 3),
      );
      final carte = plane(shade: 0);

      var first = -1;
      for (var i = 0; i < 20; i++) {
        if (feed(scanner, carte).accepted != null && first < 0) first = i;
      }
      expect(first, 8, reason: 'neuf images consécutives, la neuvième retient');
    });
  });
}
