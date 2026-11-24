// La ligne basse des cartes d'un étalement (issue n°50) : un rectangle, une
// carte, et rien quand le rectangle en porte deux.
import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/scan/application/print_line_reader.dart';
import 'package:deckhand/src/features/scan/domain/card_segmentation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../helpers/fakes.dart';

/// Deux cartes sombres de 400 × 559 px posées sur une table claire, séparées
/// d'un large jour.
img.Image _deuxCartes() {
  final photo = img.Image(width: 1200, height: 800)
    ..clear(img.ColorRgb8(235, 232, 225));
  for (final x in [100, 700]) {
    img.fillRect(
      photo,
      x1: x,
      y1: 120,
      x2: x + 400,
      y2: 120 + 559,
      color: img.ColorRgb8(28, 28, 34),
    );
  }
  return photo;
}

/// Un rectangle en fractions de [photo], depuis des pixels.
CardBounds _box(img.Image photo, int x0, int y0, int x1, int y1) => CardBounds(
  x0 / photo.width,
  y0 / photo.height,
  x1 / photo.width,
  y1 / photo.height,
);

void main() {
  final reader = PrintLineReader(FakeCardTextReader());

  test('une carte isolée se détoure dans son rectangle', () {
    final photo = _deuxCartes();

    final quad = reader.cardInBox(photo, _box(photo, 100, 120, 500, 679));

    expect(quad, isNotNull);
    // Dans le repère de la photo, pas du recadrage.
    expect(quad!.topLeft.x, closeTo(100, 12));
    expect(quad.topLeft.y, closeTo(120, 12));
    expect(quad.bottomRight.x, closeTo(500, 12));
  });

  test('un rectangle qui porte deux cartes ne lit rien', () {
    // La bande lue serait celle de l'une ou de l'autre : son numéro pourrait
    // désigner à tort une édition de la carte nommée.
    final photo = _deuxCartes();

    expect(reader.cardInBox(photo, _box(photo, 100, 120, 1100, 679)), isNull);
  });

  test('hors de Magic, aucune bande n\'est lue', () async {
    final texte = FakeCardTextReader();
    final photo = _deuxCartes();

    final lignes = await PrintLineReader(
      texte,
      game: Game.riftbound,
    ).readBoxes(photo, [_box(photo, 100, 120, 500, 679)], [0], 'etalement.jpg');

    expect(lignes, isEmpty);
    expect(texte.reads, 0);
  });
}
