/// Le vrai dos des cartes : ce qui est publié, et ce qui ne l'est pas.
///
/// **Ce que ces tests protègent.** Pas la beauté du dos — cela se regarde. Ils
/// tiennent deux choses qu'un remaniement casse sans bruit : qu'aucune URL n'ait
/// été *devinée* (elles sont toutes en https chez une source que le projet
/// utilise déjà), et que le peintre **lise** réellement l'image qu'on lui donne.
/// Un paramètre branché mais jamais lu se voit à l'œil sur un écran et jamais
/// dans une revue de code.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/binders/presentation/card_back.dart';
import 'package:deckhand/src/features/binders/presentation/sheet_face.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('les dos publiés', () {
    test('deux jeux en ont un, et ce sont ceux-là', () {
      // **Une constatation, pas un abandon.** Les six autres sources ne
      // publient pas de dos ; en inventer une URL serait au mieux un 404, au
      // pire une ressource qu'on n'a pas le droit de servir.
      expect(cardBackUrls.keys.toSet(), {Game.magic, Game.yugioh});
      expect(cardBackUrl(Game.pokemon), isNull);
      expect(cardBackUrl(Game.wankul), isNull);
    });

    test('chaque URL est servie par une source que le projet utilise déjà', () {
      const hotes = {'backs.scryfall.io', 'images.ygoprodeck.com'};
      for (final url in cardBackUrls.values) {
        final uri = Uri.parse(url);
        expect(uri.scheme, 'https');
        expect(hotes, contains(uri.host), reason: url);
      }
    });

    test('un jeu sans dos ne fait pas d_appel', () async {
      // Le repli est le motif dessiné, et il ne coûte pas un aller-retour.
      expect(await loadCardBack(Game.pokemon), isNull);
    });
  });

  group('le peintre lit ce qu_on lui donne', () {
    SheetFacePainter peintre({ui.Image? back}) => SheetFacePainter(
      colors: const ColorScheme.dark(),
      padding: 14,
      gap: 8,
      pockets: false,
      back: back,
    );

    testWidgets('changer de dos repeint la face', (tester) async {
      // **Le contrôle qui trouve un paramètre mort.** `shouldRepaint` est la
      // seule chose qui dise si le peintre tient compte du dos : sans lui, la
      // feuille garderait le motif dessiné après l_arrivée de l_image, et rien
      // n_échouerait.
      final image = await _uneImage(tester);
      expect(peintre().shouldRepaint(peintre(back: image)), isTrue);
      expect(peintre(back: image).shouldRepaint(peintre()), isTrue);
      expect(peintre(back: image).shouldRepaint(peintre(back: image)), isFalse);
      image.dispose();
    });
  });
}

/// Une image minuscule, décodée pour de vrai : `ui.Image` n'a pas de
/// constructeur, et un faux ne prouverait rien du peintre.
Future<ui.Image> _uneImage(WidgetTester tester) async {
  late final ui.Image image;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 4, 4),
      Paint()..color = const Color(0xFF112233),
    );
    image = await recorder.endRecording().toImage(4, 4);
  });
  return image;
}
