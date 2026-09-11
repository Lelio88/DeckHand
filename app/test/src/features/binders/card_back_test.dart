/// Le vrai dos des cartes : ce qui est dans le bucket, et ce qui n'y est pas.
///
/// **Ce que ces tests protègent.** Pas la beauté du dos — cela se regarde. Ils
/// tiennent trois choses qu'un remaniement casse sans bruit : que l'adresse
/// reste celle du bucket du projet, dérivée de la configuration et jamais d'un
/// hôte tiers ; qu'elle soit **la même** que celle que le versement Python
/// calcule de son côté, les deux ne se consultant pas ; et que le peintre
/// **lise** réellement l'image qu'on lui donne. Un paramètre branché mais
/// jamais lu se voit à l'œil sur un écran et jamais dans une revue de code.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/config/supabase_config.dart';
import 'package:deckhand/src/features/binders/presentation/card_back.dart';
import 'package:deckhand/src/features/binders/presentation/sheet_face.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('les dos versés', () {
    test('deux jeux en ont un, et ce sont ceux-là', () {
      // **Une constatation, pas un abandon.** Les six autres sources ne
      // publient pas de dos ; en inventer une URL serait au mieux un 404, au
      // pire une ressource qu'on n'a pas le droit de servir.
      expect(hostedCardBacks, {Game.magic, Game.yugioh});
      expect(cardBackUrl(Game.pokemon), isNull);
      expect(cardBackUrl(Game.wankul), isNull);
    });

    test('l_adresse est celle du bucket, calculée comme le versement', () {
      // **Le jumeau Python est `back_url`.** Les deux dérivent la même
      // adresse de l'URL du projet : `<projet>/storage/v1/object/public/
      // card-art/<jeu>/back.jpg`. Ce test verrouille le côté Dart de
      // l'accord ; `test_card_art.py` verrouille l'autre.
      for (final game in hostedCardBacks) {
        final url = cardBackUrl(game);
        expect(url, isNotNull);
        expect(url, startsWith(SupabaseConfig.url));
        expect(
          url,
          endsWith('/storage/v1/object/public/card-art/${game.id}/back.jpg'),
        );
        // Sans `/normal/` : `previewCardImage` ne tenterait une vignette
        // que sur ce segment, et elle n'existe pas.
        expect(url, isNot(contains('/normal/')));
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
