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
  distinctSets: 5,
  bestSetName: 'Marvel Super Heroes',
  bestSetOwned: 234,
  bestSetTotal: 453,
);

/// Le chiffre dont le détail porte [motif].
///
/// **Chercher par le contenu, pas par le rang.** Une première version indexait
/// la liste ; l'insertion d'un chiffre au milieu a cassé treize tests dont
/// aucun ne parlait d'ordre.
CollectionFigure chiffre(List<CollectionFigure> figures, Pattern motif) =>
    figures.firstWhere((f) => f.detail.contains(motif));

void main() {
  group('ce que la collection contient', () {
    test('la série entière quand le booster du jeu est connu', () {
      final f = countFigures(totaux, 'magic');

      expect(f.map((e) => e.value), ['617', '266', '5', '44', '52 %']);
    });

    test('un booster entamé ne compte pas', () {
      // 617 cartes à 14 la boîte, c'est 44 boosters et des poussières. Arrondir
      // vers le haut annoncerait un booster qu'on n'a jamais ouvert.
      expect(chiffre(countFigures(totaux, 'magic'), 'le booster').value, '44');
      expect(617 ~/ 14, 44);
    });

    test('la taille du booster suit le jeu, pas une moyenne', () {
      // Yu-Gi-Oh tient en 9 cartes, Star Wars en 16 : le même tas de cartes ne
      // représente pas le même nombre de boosters selon le jeu.
      expect(
        chiffre(countFigures(totaux, 'yugioh'), 'le booster').value,
        '${617 ~/ 9}',
      );
      expect(
        chiffre(countFigures(totaux, 'swu'), 'le booster').value,
        '${617 ~/ 16}',
      );
    });

    test('un jeu inconnu de la table n’invente pas de booster', () {
      final f = countFigures(totaux, 'un-jeu-qui-nexiste-pas');

      expect(f.any((e) => e.detail.contains('le booster')), isFalse);
      expect(f.map((e) => e.value), ['617', '266', '5', '52 %']);
    });
  });

  group('les extensions', () {
    test('le taux est arrondi, et porte son assiette', () {
      final f = chiffre(countFigures(totaux, 'magic'), 'Marvel');

      // 234 / 453 = 51,65 % — arrondi, et le détail donne les deux termes pour
      // qu'on puisse refaire le calcul.
      expect(f.value, '52 %');
      expect(f.detail, 'Marvel Super Heroes, 234/453 cases');
    });

    test('sans extension entamée, ni compte ni taux', () {
      // Une collection entièrement sans édition précisée : les cartes existent,
      // aucune n'est rangeable. Annoncer « 0 extensions, 0 % » serait un
      // reproche là où ne pas préciser reste légitime.
      const flou = CollectionSummary(
        totalCards: 12,
        distinctCards: 12,
        totalValueEur: 3,
        unspecifiedPrints: 12,
      );
      final f = countFigures(flou, 'magic');

      expect(f.any((e) => e.detail.contains('entamées')), isFalse);
      expect(f.any((e) => e.value.endsWith('%')), isFalse);
    });

    test('une extension complète affiche cent, pas quatre-vingt-dix-neuf', () {
      const finie = CollectionSummary(
        totalCards: 453,
        distinctCards: 453,
        totalValueEur: 900,
        distinctSets: 1,
        bestSetName: 'Marvel Super Heroes',
        bestSetOwned: 453,
        bestSetTotal: 453,
      );

      expect(chiffre(countFigures(finie, 'magic'), 'Marvel').value, '100 %');
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
        (167.83 / 617).toStringAsFixed(2),
        // 617 / 14 × 6,90 € : ce qu'on aurait dépensé, et non ce qu'on
        // pourrait racheter.
        (617 / 14 * 6.90).toStringAsFixed(2),
        '15.49',
      ]);
    });

    test('le prix déclaré remplace le repère, et se dit', () {
      final f = valueFigures(totaux, 'magic', boosterPrices: {'magic': 4.20});

      expect(chiffre(f, '€ pièce').value, (617 / 14 * 4.20).toStringAsFixed(2));
      expect(chiffre(f, '€ pièce').detail, contains('4.20'));
    });

    test('un prix à zéro donne zéro, sans retomber sur le repère', () {
      final f = valueFigures(totaux, 'magic', boosterPrices: {'magic': 0});

      expect(chiffre(f, '€ pièce').value, '0.00');
    });

    test('seul le chiffre en boosters se déclare modifiable', () {
      // C'est ce marqueur qui décide où l'écran pose le geste de réglage :
      // le poser sur « la carte la plus chère » ouvrirait une boîte sans rapport.
      final f = valueFigures(totaux, 'magic');

      expect(f.where((e) => e.fromBoosterPrice).length, 1);
      expect(chiffre(f, '€ pièce').fromBoosterPrice, isTrue);
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

      expect(
        valueFigures(sansCote, 'magic').any((e) => e.detail.contains('chère')),
        isFalse,
      );
      expect(valueFigures(sansCote, 'magic').last.detail, contains('pièce'));
    });

    test('la moyenne par carte ne demande rien au serveur', () {
      // Une collection de mille communes et une de dix rares peuvent valoir la
      // même chose : c'est ce que ce chiffre distingue.
      final f = chiffre(valueFigures(totaux, 'magic'), 'en moyenne');

      expect(f.value, (167.83 / 617).toStringAsFixed(2));
    });

    test('une collection vide n’essaie pas de diviser par zéro', () {
      final f = valueFigures(CollectionSummary.empty, 'magic');

      expect(f.any((e) => e.detail.contains('en moyenne')), isFalse);
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
