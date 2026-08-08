/// Tests du découpage de l'illustration et de la recherche multi-gabarits.
library;

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Fausse carte : un fond uni, et une zone d'illustration texturée à
/// l'emplacement du cadre demandé.
img.Image fakeCard(CardFrame frame, {int width = 400, int height = 560}) {
  final card = img.Image(width: width, height: height);
  img.fill(card, color: img.ColorRgb8(30, 30, 30));

  final box = frame.box;
  final x0 = (box.left * width).round();
  final y0 = (box.top * height).round();
  final x1 = (box.right * width).round();
  final y1 = (box.bottom * height).round();

  for (var x = x0; x < x1; x++) {
    for (var y = y0; y < y1; y++) {
      card.setPixelRgb(x, y, (x * 5) % 256, (y * 3) % 256, (x + y) % 256);
    }
  }
  return card;
}

void main() {
  group('découpage', () {
    test('les proportions découpées correspondent au gabarit', () {
      final card = img.Image(width: 400, height: 560);
      final crop = cropArt(card, CardFrame.modern);
      final box = CardFrame.modern.box;

      expect(crop.width, ((box.right - box.left) * 400).round());
      expect(crop.height, ((box.bottom - box.top) * 560).round());
    });

    test('les deux gabarits ne découpent pas la même zone', () {
      final card = img.Image(width: 400, height: 560);
      expect(
        cropArt(card, CardFrame.modern).width,
        isNot(cropArt(card, CardFrame.legacy).width),
      );
    });

    test('une image minuscule ne fait pas échouer le découpage', () {
      final crop = cropArt(img.Image(width: 4, height: 6), CardFrame.modern);
      expect(crop.width, greaterThan(0));
      expect(crop.height, greaterThan(0));
    });

    test('une carte produit une empreinte par cadre de son jeu', () {
      final candidates = artHashCandidates(fakeCard(CardFrame.modern));

      expect(
        candidates.keys,
        containsAll(CardFrame.values.where((f) => f.game == 'magic')),
      );
    });

    test("les cadres d'un autre jeu ne sont pas essayés", () {
      // Découper une carte Magic au gabarit Riftbound produit une empreinte qui
      // ne veut plus rien dire, mais qui peut rencontrer par hasard une entrée
      // de l'index. Le pipeline est mesuré à zéro faux positif annoncé avec
      // assurance : c'est ce résultat que le cloisonnement protège.
      final magic = artHashCandidates(fakeCard(CardFrame.modern));
      final riftbound = artHashCandidates(
        fakeCard(CardFrame.modern),
        game: 'riftbound',
      );

      expect(magic.keys.every((f) => f.game == 'magic'), isTrue);
      expect(riftbound.keys.every((f) => f.game == 'riftbound'), isTrue);
      expect(magic.keys.toSet().intersection(riftbound.keys.toSet()), isEmpty);
    });
  });

  group('recherche multi-gabarits', () {
    test('le bon cadre est retenu', () {
      // L'index ne contient que l'illustration telle qu'un cadre moderne la cadre.
      final card = fakeCard(CardFrame.modern);
      final reference = computeArtHash(cropArt(card, CardFrame.modern));
      final index = ArtHashIndex.fromEntries([
        (oracleId: 'cible', hash: reference),
      ]);

      final outcome = index.searchAny(artHashCandidates(card));

      expect(outcome.source, CardFrame.modern);
      expect(outcome.result.best?.oracleId, 'cible');
      expect(outcome.result.best?.distance, 0);
    });

    test('un index vide ne renvoie rien', () {
      final outcome = ArtHashIndex.fromEntries(
        [],
      ).searchAny(artHashCandidates(fakeCard(CardFrame.modern)));
      expect(outcome.result.best, isNull);
      expect(outcome.source, isNull);
    });
  });
}
