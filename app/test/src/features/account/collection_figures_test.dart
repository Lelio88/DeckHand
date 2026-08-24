/// Les chiffres que la page de profil sait dire, et d'où vient leur prix.
///
/// **Pourquoi ces règles se testent hors de l'écran.** Une valeur qui ne se lit
/// qu'en dessinant une page ne se vérifie qu'en la dessinant ; celles-ci sont
/// des règles de calcul, et elles méritent d'échouer bruyamment.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/account/data/profile_repository.dart';
import 'package:deckhand/src/features/account/domain/collection_figures.dart';
import 'package:deckhand/src/features/collection/domain/booster_size.dart';
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

    test('la taille du booster suit le jeu, pas une moyenne', () {
      // Yu-Gi-Oh tient en 9 cartes, Star Wars en 16 : le même tas de cartes ne
      // représente pas le même nombre de boosters selon le jeu.
      expect(countFigures(totaux, 'yugioh')[2].value, '${617 ~/ 9}');
      expect(countFigures(totaux, 'swu')[2].value, '${617 ~/ 16}');
    });

    test('un jeu inconnu de la table n’invente pas de booster', () {
      final f = countFigures(totaux, 'un-jeu-qui-nexiste-pas');

      expect(f.length, 2);
      expect(f.map((e) => e.value), ['617', '266']);
    });
  });

  group('les faits de booster', () {
    test('les huit jeux couverts ont les leurs', () {
      // **Tripwire.** Un neuvième jeu ajouté à `Game` sans entrée ici perdrait
      // silencieusement deux indicateurs ; ce test le dit à l'ajout, pas six
      // mois plus tard devant un écran incomplet.
      final manquants = [
        for (final game in Game.values)
          if (boosterFactsFor(game.id) == null) game.id,
      ];

      expect(manquants, isEmpty);
    });

    test('chacun dit où son prix a été relevé', () {
      // Sans provenance, le prix redevient dans six mois un nombre dont
      // personne ne sait d'où il sort — ce qu'il était.
      for (final facts in boosterFacts.values) {
        expect(facts.source, isNotEmpty);
        expect(facts.cards, greaterThan(0));
        expect(facts.referencePriceEur, greaterThan(0));
      }
    });
  });

  group('quel prix est retenu', () {
    test('sans réponse de l’utilisateur, le repère s’applique', () {
      expect(boosterPriceFor('magic', const {}), 6.90);
    });

    test('la réponse de l’utilisateur prime sur le repère', () {
      expect(boosterPriceFor('magic', const {'magic': 4.20}), 4.20);
    });

    test('zéro est une réponse, pas une absence', () {
      // « Je n'achète pas de boosters » doit donner zéro euro, et non le prix
      // de repère — un repli sur `??` ferait exactement l'inverse.
      expect(boosterPriceFor('magic', const {'magic': 0}), 0);
    });

    test('le prix d’un jeu ne déborde pas sur un autre', () {
      final mine = {'magic': 4.20};

      expect(boosterPriceFor('pokemon', mine), 4.99);
    });

    test('un jeu inconnu n’a aucun prix, même de repère', () {
      expect(boosterPriceFor('un-jeu-qui-nexiste-pas', const {}), isNull);
    });
  });

  group('lire un prix saisi à la main', () {
    test('la virgule est acceptée, comme au comptoir', () {
      expect(parseBoosterPrice('6,90'), 6.90);
      expect(parseBoosterPrice('6.90'), 6.90);
      expect(parseBoosterPrice(' 6,90 '), 6.90);
    });

    test('vide veut dire « je retire ma réponse »', () {
      expect(parseBoosterPrice(''), isNull);
      expect(parseBoosterPrice('   '), isNull);
    });

    test('zéro se distingue du vide', () {
      expect(parseBoosterPrice('0'), 0);
    });

    test('un prix négatif est refusé', () {
      // Il produirait une dépense négative : « vous auriez gagné 240 € en
      // achetant des boosters ».
      expect(parseBoosterPrice('-3'), isNull);
    });

    test('ce qui n’est pas un nombre est refusé', () {
      expect(parseBoosterPrice('gratuit'), isNull);
      expect(parseBoosterPrice('6,9,0'), isNull);
    });
  });

  group('lire la colonne booster_prices', () {
    test('un entier venu de Postgres est un prix', () {
      // `jsonb` rend 6 en `int` : tester `is double` perdrait tout prix rond.
      expect(boosterPricesFromColumn({'magic': 6}), {'magic': 6.0});
    });

    test('une colonne absente ne casse rien', () {
      expect(boosterPricesFromColumn(null), isEmpty);
      expect(boosterPricesFromColumn('n’importe quoi'), isEmpty);
    });

    test('ce qui n’est pas un prix est écarté, pas deviné', () {
      final lu = boosterPricesFromColumn({
        'magic': 6.90,
        'pokemon': 'cher',
        'yugioh': -2,
        'swu': null,
      });

      expect(lu, {'magic': 6.90});
    });
  });

  group('ce que la collection vaut', () {
    test('le total, une de chaque, les boosters, la plus chère', () {
      final f = valueFigures(totaux, 'magic');

      expect(f.map((e) => e.value), [
        '167.83',
        '119.64',
        // 617 / 14 × 6,90 € : ce qu'on aurait dépensé, et non ce qu'on
        // pourrait racheter.
        (617 / 14 * 6.90).toStringAsFixed(2),
        '15.49',
      ]);
    });

    test('le prix déclaré remplace le repère, et se dit', () {
      final f = valueFigures(totaux, 'magic', boosterPrices: {'magic': 4.20});

      expect(f[2].value, (617 / 14 * 4.20).toStringAsFixed(2));
      expect(f[2].detail, contains('4.20'));
    });

    test('un prix à zéro donne zéro, sans retomber sur le repère', () {
      final f = valueFigures(totaux, 'magic', boosterPrices: {'magic': 0});

      expect(f[2].value, '0.00');
    });

    test('seul le chiffre en boosters se déclare modifiable', () {
      // C'est ce marqueur qui décide où l'écran pose le geste de réglage :
      // le poser sur « la carte la plus chère » ouvrirait une boîte sans rapport.
      final f = valueFigures(totaux, 'magic');

      expect(f.where((e) => e.fromBoosterPrice).length, 1);
      expect(f[2].fromBoosterPrice, isTrue);
    });

    test('un jeu inconnu n’a rien à régler', () {
      final f = valueFigures(totaux, 'un-jeu-qui-nexiste-pas');

      expect(f.any((e) => e.fromBoosterPrice), isFalse);
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
