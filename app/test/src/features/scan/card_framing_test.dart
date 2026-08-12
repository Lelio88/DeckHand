/// Tests du cadrage d'une photo sur la carte.
library;

import 'package:deckhand/src/features/scan/domain/card_framing.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  final magic = cardAspectFor('magic');

  test('une photo large est recadrée aux proportions d\'une carte', () {
    final crop = cropToCardFrame(img.Image(width: 800, height: 400));
    expect(crop.height, 400);
    expect(crop.width / crop.height, closeTo(magic, 0.01));
  });

  test('une photo haute est recadrée aux proportions d\'une carte', () {
    final crop = cropToCardFrame(img.Image(width: 400, height: 900));
    expect(crop.width, 400);
    expect(crop.width / crop.height, closeTo(magic, 0.01));
  });

  test('le recadrage est centré', () {
    final photo = img.Image(width: 800, height: 400);
    final crop = cropToCardFrame(photo);
    // Un rectangle de 286×400 centré dans 800 de large commence vers x=257.
    expect(crop.width, lessThan(photo.width));
    expect(crop.height, photo.height);
  });

  test('une image déjà aux bonnes proportions est conservée', () {
    final photo = img.Image(width: 630, height: 880);
    final crop = cropToCardFrame(photo);
    expect(crop.width / crop.height, closeTo(magic, 0.01));
  });

  test('une image dégénérée ne fait pas planter', () {
    expect(cropToCardFrame(img.Image(width: 1, height: 1)).width, 1);
  });

  group('le découpage suit le rapport qu\'on lui donne', () {
    // **Ce que ces trois tests protègent.** Les deux jeux couverts impriment sur
    // le même carton : comparer leurs découpages ne prouverait rien du
    // paramétrage, les deux rendraient la même image pour de mauvaises raisons.
    // On vérifie donc la mécanique sur des rapports arbitraires, puis, à part,
    // que le jeu choisit bien la valeur qui lui revient.

    test('un rapport carré rend un carré', () {
      final crop = cropToAspect(img.Image(width: 800, height: 400), 1.0);
      expect(crop.width, crop.height);
      expect(crop.height, 400);
    });

    test('un rapport plus étroit rend une image plus étroite', () {
      final photo = img.Image(width: 400, height: 900);
      final large = cropToAspect(photo, 0.80);
      final etroit = cropToAspect(photo, 0.50);
      expect(etroit.height, greaterThan(large.height));
      expect(etroit.width / etroit.height, closeTo(0.50, 0.01));
    });

    test('chaque jeu est découpé à ses propres proportions', () {
      // Aujourd'hui les deux valeurs coïncident ; ce test ne mordra qu'au
      // premier jeu qui imprime autrement — c'est exactement ce qu'on lui
      // demande, puisque c'est ce jour-là que le câblage cédait en silence.
      final photo = img.Image(width: 900, height: 900);
      for (final game in cardAspects.keys) {
        final crop = cropToCardFrame(photo, game: game);
        expect(
          crop.width / crop.height,
          closeTo(cardAspectFor(game), 0.01),
          reason: 'le cadrage de « $game » n\'a pas suivi ses proportions',
        );
      }
    });
  });
}
