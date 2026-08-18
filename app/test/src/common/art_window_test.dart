/// Le découpage d'une illustration dans le rendu entier d'une carte.
///
/// **Ce que ces tests protègent.** Une fenêtre d'illustration est large et
/// basse ; une tuile du sélecteur est presque carrée. La première version
/// agrandissait l'image d'un facteur en largeur et d'un autre en hauteur pour
/// que la fenêtre épouse la tuile — les visages y étaient **étirés**, et rien
/// dans le code ne le disait. `flutter analyze` ne mesure pas une proportion.
///
/// Le test central est donc géométrique : il mesure le rectangle réellement
/// peint et vérifie qu'il a gardé les proportions de la carte. Le second garde-
/// fou est le cadrage — un facteur unique supprime l'étirement mais recadre au
/// passage, et on perdrait la moitié de la fenêtre sans que rien ne l'annonce.
library;

import 'package:deckhand/src/common/art_window.dart';
import 'package:deckhand/src/common/card_image.dart';
import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Une URL qui ne ressemble à aucune source connue : la géométrie se mesure sur
/// la place que prend l'image, pas sur ses pixels, et aucune requête n'aboutit
/// en test.
const _url = 'https://exemple.test/carte.png';

/// Le côté de la place donnée à la fenêtre. Carré à dessein : c'est le cas où
/// l'étirement se voyait le plus, une fenêtre d'illustration ne l'étant jamais.
const double _cote = 100;

Future<Rect> _monter(WidgetTester tester, CardFrame frame) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: _cote,
          height: _cote,
          child: ArtWindow(url: _url, frame: frame),
        ),
      ),
    ),
  );
  await tester.pump();

  // `getRect` passe par `localToGlobal` : il rend donc le rectangle **après**
  // les mises à l'échelle des ancêtres, c'est-à-dire la carte telle qu'elle est
  // peinte. C'est exactement ce qu'il faut pour attraper une déformation.
  //
  // Mesurer la boîte revient bien à mesurer l'image parce que `ArtWindow` la
  // pose en `BoxFit.fill` : les deux coïncident. Si ce choix changeait, ce test
  // mesurerait autre chose que ce qu'il annonce.
  final image = tester.getRect(find.byType(CardImage));
  // La place est centrée dans l'écran de test ; on ramène tout à un repère dont
  // l'origine est le coin haut-gauche de la place.
  final place = tester.getRect(find.byType(ArtWindow));
  return image.translate(-place.left, -place.top);
}

/// La fenêtre d'illustration, dans le repère de la place reçue.
Rect _fenetre(Rect carte, CardFrame frame) {
  final f = artWindowRect(frame.box, 0.04);
  return Rect.fromLTWH(
    carte.left + f.left * carte.width,
    carte.top + f.top * carte.height,
    f.width * carte.width,
    f.height * carte.height,
  );
}

void main() {
  group('artWindowRect', () {
    test('resserre la fenêtre des quatre côtés', () {
      final f = artWindowRect(CardFrame.riftbound.box, 0.04);

      expect(f.left, closeTo(0.105, 1e-9));
      expect(f.top, closeTo(0.087, 1e-9));
      expect(f.width, closeTo(0.789, 1e-9));
      expect(f.height, closeTo(0.390, 1e-9));
    });

    test('ne retourne jamais une fenêtre étroite', () {
      // Un cadre de 0,1 de large ne peut pas se voir retirer 0,04 de chaque
      // côté : il ne resterait rien, et la largeur passerait négative.
      const etroit = (left: 0.45, top: 0.10, right: 0.55, bottom: 0.90);
      final f = artWindowRect(etroit, 0.04);

      expect(f.width, greaterThan(0));
      expect(f.width, closeTo(0.05, 1e-9)); // moitié de ce qui restait
    });
  });

  group('artWindowCardAspect', () {
    test('rend le rapport du jeu pour une carte debout', () {
      expect(
        artWindowCardAspect(CardFrame.onePiece),
        cardAspectFor('onepiece'),
      );
      expect(artWindowCardAspect(CardFrame.yugioh), cardAspectFor('yugioh'));
    });

    test('inverse le rapport pour une carte couchée', () {
      // La même carte tournée d'un quart de tour, pas un autre format.
      expect(
        artWindowCardAspect(CardFrame.riftboundWide),
        closeTo(1 / cardAspectFor('riftbound'), 1e-12),
      );
    });
  });

  group('ArtWindow', () {
    testWidgets('la carte garde ses proportions — rien n\'est étiré', (
      tester,
    ) async {
      // Le défaut d'origine : la carte était peinte au rapport de la place
      // (1,0 ici) au lieu du sien (0,716), soit 40 % d'étirement horizontal.
      for (final frame in [
        CardFrame.riftbound,
        CardFrame.yugioh,
        CardFrame.pokemon,
        CardFrame.lorcana,
        CardFrame.swuUnit,
      ]) {
        final carte = await _monter(tester, frame);

        expect(
          carte.width / carte.height,
          closeTo(artWindowCardAspect(frame), 1e-3),
          reason: '${frame.name} : la carte est peinte déformée',
        );
      }
    });

    testWidgets('la fenêtre couvre la place, sans en montrer moins', (
      tester,
    ) async {
      final carte = await _monter(tester, CardFrame.riftbound);
      final fenetre = _fenetre(carte, CardFrame.riftbound);

      // Couvre : aucun bord de la place n'est laissé au fond uni.
      expect(fenetre.left, lessThanOrEqualTo(0.01));
      expect(fenetre.top, lessThanOrEqualTo(0.01));
      expect(fenetre.right, greaterThanOrEqualTo(_cote - 0.01));
      expect(fenetre.bottom, greaterThanOrEqualTo(_cote - 0.01));

      // Et rien de plus : l'un des deux axes tombe pile, sinon on aurait
      // recadré plus que nécessaire — le défaut du facteur de zoom unique, qui
      // mangeait ici la moitié de la largeur de la fenêtre.
      final debordement = [
        -fenetre.left,
        -fenetre.top,
      ].reduce((a, b) => a < b ? a : b);
      expect(debordement, closeTo(0, 0.01));
    });

    testWidgets('ce qui dépasse est rogné également des deux côtés', (
      tester,
    ) async {
      final carte = await _monter(tester, CardFrame.riftbound);
      final fenetre = _fenetre(carte, CardFrame.riftbound);

      expect(fenetre.left, closeTo(_cote - fenetre.right, 0.01));
      expect(fenetre.top, closeTo(_cote - fenetre.bottom, 0.01));
    });

    testWidgets('une fenêtre pleine carte ne divise pas par zéro', (
      tester,
    ) async {
      // `pokemonFull` va de 0 à 1 : l'illustration *est* la carte, et il ne
      // reste rien à décaler.
      final carte = await _monter(tester, CardFrame.pokemonFull);

      expect(carte.width, greaterThan(0));
      expect(
        carte.width / carte.height,
        closeTo(artWindowCardAspect(CardFrame.pokemonFull), 1e-3),
      );
    });

    testWidgets('sans cadre, l\'image est affichée telle quelle', (
      tester,
    ) async {
      // Le cas de Magic : `art_crop` *est* déjà l'illustration, la redécouper
      // n'en montrerait qu'un morceau.
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              width: _cote,
              height: _cote,
              child: ArtWindow(url: _url),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(FittedBox), findsNothing);
      expect(
        tester.widget<CardImage>(find.byType(CardImage)).fit,
        BoxFit.cover,
      );
    });
  });
}
