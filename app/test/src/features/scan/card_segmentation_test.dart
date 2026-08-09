/// Tests de la délimitation des cartes et de ses garde-fous.
///
/// **Ce qui est éprouvé ici n'est pas la justesse du découpage** — elle se
/// mesure sur de vraies photos, avec `tool/find_cards.dart`, et se consigne dans
/// `docs/spread-detection.md`. Ce qui est éprouvé ici, ce sont les **garanties
/// de sûreté** : ce filtrage vient en supplément d'un scan qui fonctionne, et il
/// ne doit jamais pouvoir le dégrader.
library;

import 'package:deckhand/src/features/scan/domain/card_segmentation.dart';
import 'package:flutter_test/flutter_test.dart';

CardBounds card(double left, double top, double w, double h) =>
    CardBounds(left, top, left + w, top + h);

void main() {
  group('seules les cartes isolées servent au filtrage', () {
    test('un bloc de cartes soudées est écarté', () {
      // **Le rapport ne suffit pas à reconnaître une carte.** Sur une photo
      // d'épreuve, un groupe soudé couvrant 49 % de la surface encrée
      // présentait un rapport de 1,44 — exactement celui d'une carte. C'est la
      // surface, comparée aux autres rectangles, qui le démasque.
      final found = [
        card(0.0, 0.0, 0.20, 0.28),
        card(0.3, 0.0, 0.20, 0.28),
        card(0.6, 0.0, 0.20, 0.28),
        card(0.0, 0.4, 0.42, 0.58), // bloc : quatre fois la surface
      ];

      final kept = singleCards(found);

      expect(kept.length, 3);
      expect(kept.every((c) => c.width * c.height < 0.1), isTrue);
    });

    test('des cartes de tailles voisines passent toutes', () {
      // La perspective fait varier la taille d'une carte à l'autre ; la
      // tolérance doit l'absorber sans écarter les cartes du fond.
      final found = [
        card(0.0, 0.0, 0.20, 0.28),
        card(0.3, 0.0, 0.22, 0.30),
        card(0.6, 0.0, 0.18, 0.25),
      ];

      expect(singleCards(found).length, 3);
    });

    test('en dessous de trois rectangles, on ne compare rien', () {
      // La médiane n'a pas de sens sur deux valeurs : mieux vaut tout garder
      // que d'écarter au hasard. Le filtrage en aval ne s'appliquera de toute
      // façon qu'aux rectangles contenant plusieurs correspondances.
      final two = [card(0.0, 0.0, 0.20, 0.28), card(0.3, 0.0, 0.60, 0.84)];

      expect(singleCards(two).length, 2);
    });

    test('une liste vide reste vide', () {
      expect(singleCards(const []), isEmpty);
    });
  });

  group('les réglages restent dans la bande mesurée', () {
    test("la marge couvre le débordement d'un nom sans happer le voisin", () {
      // Mesuré : un nom déborde de sa carte jusqu'à 5,3 %, et le nom d'une
      // carte voisine entre à 14,4 %. Sortir de cette bande casse l'un ou
      // l'autre — perdre un nom, ou en voler un.
      expect(boundsMargin, greaterThan(0.053));
      expect(boundsMargin, lessThan(0.144));
    });

    test('la profondeur de citation sépare les deux populations', () {
      // Mesuré sur les lignes présentes dans un rectangle qui en a élu une
      // autre : un vrai nom débordant de chez la voisine reste à 2,7-8 %, une
      // citation siège à 14-22 %.
      expect(citationDepth, greaterThan(0.08));
      expect(citationDepth, lessThan(0.14));
    });
  });
}
