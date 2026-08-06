/// Tests du cadrage d'une photo sur la carte.
library;

import 'package:deckhand/src/features/scan/domain/card_framing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('une photo large est recadrée aux proportions d\'une carte', () {
    final crop = cropToCardFrame(img.Image(width: 800, height: 400));
    expect(crop.height, 400);
    expect(crop.width / crop.height, closeTo(cardAspectRatio, 0.01));
  });

  test('une photo haute est recadrée aux proportions d\'une carte', () {
    final crop = cropToCardFrame(img.Image(width: 400, height: 900));
    expect(crop.width, 400);
    expect(crop.width / crop.height, closeTo(cardAspectRatio, 0.01));
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
    expect(crop.width / crop.height, closeTo(cardAspectRatio, 0.01));
  });

  test('une image dégénérée ne fait pas planter', () {
    expect(cropToCardFrame(img.Image(width: 1, height: 1)).width, 1);
  });
}
