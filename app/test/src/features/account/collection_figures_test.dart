/// Les chiffres que la page de profil sait dire (#profil).
///
/// **Pourquoi ces règles se testent hors de l'écran.** Une valeur qui ne se lit
/// qu'en dessinant une page ne se vérifie qu'en la dessinant ; celles-ci sont
/// des règles de calcul, et elles méritent d'échouer bruyamment.
library;

import 'package:deckhand/src/features/account/domain/collection_figures.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:flutter_test/flutter_test.dart';

const totaux = CollectionSummary(
  totalCards: 617,
  distinctCards: 266,
  totalValueEur: 167.83,
  uniqueValueEur: 119.64,
  topCardName: 'Simulacrum Synthesizer',
  topCardEur: 15.49,
);

void main() {
  group('ce que la collection contient', () {
    test('trois chiffres quand le booster du jeu est connu', () {
      final f = countFigures(totaux, 'magic');

      expect(f.map((e) => e.value), ['617', '266', '44']);
    });

    test('un booster entamé ne compte pas', () {
      // 617 cartes à 14 la boîte, c'est 44 boosters et des poussières. Arrondir
      // vers le haut annoncerait un booster qu'on n'a jamais ouvert.
      expect(countFigures(totaux, 'magic')[2].value, '44');
      expect(617 ~/ 14, 44);
    });

    test('un jeu sans booster connu n’en invente pas', () {
      // Riftbound et Wankul ne sont pas dans la table : mieux vaut deux chiffres
      // justes que trois dont un fabriqué.
      final f = countFigures(totaux, 'riftbound');

      expect(f.length, 2);
      expect(f.map((e) => e.value), ['617', '266']);
    });
  });

  group('ce que la collection vaut', () {
    test('le total, une de chaque, les boosters, la plus chère', () {
      final f = valueFigures(totaux, 'magic');

      expect(f.map((e) => e.value), [
        '167.83',
        '119.64',
        // 617 / 14 × 5,50 € : ce qu'on aurait dépensé, et non ce qu'on
        // pourrait racheter.
        (617 / 14 * 5.50).toStringAsFixed(2),
        '15.49',
      ]);
    });

    test('la plus chère porte son nom, faute de quoi le chiffre ne dit rien', () {
      final f = valueFigures(totaux, 'magic');

      expect(f.last.detail, 'Simulacrum Synthesizer');
    });

    test('sans carte cotée, la plus chère disparaît de la liste', () {
      // Une collection dont rien n'est coté afficherait « 0,00 € » sous un nom
      // vide : mieux vaut ne pas proposer le chiffre.
      const sansCote = CollectionSummary(
        totalCards: 3,
        distinctCards: 3,
        totalValueEur: 0,
      );

      expect(valueFigures(sansCote, 'magic').length, 3);
    });

    test('les éditions inconnues sont dites, pas tues', () {
      // Une valorisation fondée sur des éditions inconnues est un plancher, pas
      // une estimation.
      const flou = CollectionSummary(
        totalCards: 10,
        distinctCards: 10,
        totalValueEur: 12,
        unspecifiedPrints: 4,
      );

      expect(valueFigures(flou, 'magic').first.detail, '4 sans édition');
    });
  });
}
