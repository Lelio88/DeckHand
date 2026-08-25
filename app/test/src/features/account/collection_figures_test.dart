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

    test('le premier chiffre ne redit pas le deuxième', () {
      // Son détail annonçait « 266 références », qui est mot pour mot le
      // chiffre suivant : la première pression ne montrait rien de neuf.
      final f = countFigures(totaux, 'magic');

      expect(f.first.detail, isNot(contains('266')));
      expect(f.first.detail, isNot(contains('référence')));
    });

    test('les extensions de jetons sont dites écartées, pas tues', () {
      // Le compte les exclut comme le fait le chiffre de complétion. Un total
      // qui exclut quelque chose sans le dire se lit comme un bug.
      expect(chiffre(countFigures(totaux, 'magic'), 'entamées').detail,
          contains('hors jetons'));
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

    test('la taille déclarée remplace le repère, et se dit', () {
      // Celui qui n'ouvre que des Collector Boosters à 15 cartes n'a pas ouvert
      // le même nombre de boîtes que celui qui ouvre des Play Boosters.
      final f = countFigures(totaux, 'magic', boosterSizes: {'magic': 15});

      expect(chiffre(f, 'le booster').value, '${617 ~/ 15}');
      expect(chiffre(f, 'le booster').detail, 'à 15 cartes le booster');
    });

    test('une taille absurde ne divise pas par zéro', () {
      // La saisie refuse déjà zéro ; une base éditée à la main, ou un client
      // tiers, ne le refuse pas. Le repère reprend la main plutôt que de faire
      // planter la page.
      final f = countFigures(totaux, 'magic', boosterSizes: {'magic': 0});

      expect(chiffre(f, 'le booster').value, '${617 ~/ 14}');
    });

    test('le chiffre en boosters se déclare modifiable, lui seul', () {
      // C'est ce marqueur qui décide où l'écran pose le geste de réglage : le
      // poser sur « 266 références » ouvrirait une boîte sans rapport.
      final f = countFigures(totaux, 'magic');

      expect(f.where((e) => e.fromBoosterSettings).length, 1);
      expect(chiffre(f, 'le booster').fromBoosterSettings, isTrue);
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
        '167,83 €',
        '119,64 €',
        '0,27 €',
        // 617 / 14 × 6,90 € : ce qu'on aurait dépensé, et non ce qu'on
        // pourrait racheter.
        euros(617 / 14 * 6.90),
        '15,49 €',
      ]);
    });

    test('chaque chiffre dit ce qu’il compte, et pas son unité', () {
      // Cinq nombres annoncés « euros » ne se distinguaient que par leur
      // légende, au point qu'on pouvait ouvrir la page sans savoir ce que
      // comptait le dernier.
      final f = valueFigures(totaux, 'magic');

      expect(f.map((e) => e.label), [
        'au total',
        'sans doublons',
        'par carte',
        'dépensé',
        'la plus chère',
      ]);
      expect(f.every((e) => e.label != 'euros'), isTrue);
    });

    test('le prix déclaré remplace le repère, et se dit', () {
      final f = valueFigures(totaux, 'magic', boosterPrices: {'magic': 4.20});

      expect(chiffre(f, '€ pièce').value, euros(617 / 14 * 4.20));
      expect(chiffre(f, '€ pièce').detail, contains('4,20'));
    });

    test('la taille déclarée change aussi la dépense', () {
      // À 15 cartes la boîte, la même collection représente moins de boosters,
      // donc moins d'argent.
      final f = valueFigures(totaux, 'magic', boosterSizes: {'magic': 15});

      expect(chiffre(f, '€ pièce').value, euros(617 / 15 * 6.90));
    });

    test('un prix à zéro donne zéro, sans retomber sur le repère', () {
      final f = valueFigures(totaux, 'magic', boosterPrices: {'magic': 0});

      expect(chiffre(f, '€ pièce').value, '0,00 €');
    });

    test('une taille à zéro n’est pas une réponse, contrairement au prix', () {
      // Elle diviserait par zéro : le repère reprend la main.
      final f = valueFigures(totaux, 'magic', boosterSizes: {'magic': 0});

      expect(chiffre(f, '€ pièce').value, euros(617 / 14 * 6.90));
    });

    test('seul le chiffre en boosters se déclare modifiable', () {
      // C'est ce marqueur qui décide où l'écran pose le geste de réglage :
      // le poser sur « la carte la plus chère » ouvrirait une boîte sans rapport.
      final f = valueFigures(totaux, 'magic');

      expect(f.where((e) => e.fromBoosterSettings).length, 1);
      expect(chiffre(f, '€ pièce').fromBoosterSettings, isTrue);
    });

    test('un jeu inconnu n’a rien à régler', () {
      final f = valueFigures(totaux, 'un-jeu-qui-nexiste-pas');

      expect(f.any((e) => e.fromBoosterSettings), isFalse);
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
        valueFigures(sansCote, 'magic').any((e) => e.label == 'la plus chère'),
        isFalse,
      );
      expect(valueFigures(sansCote, 'magic').last.detail, contains('pièce'));
    });

    test('la moyenne par carte ne demande rien au serveur', () {
      // Une collection de mille communes et une de dix rares peuvent valoir la
      // même chose : c'est ce que ce chiffre distingue.
      final f = chiffre(valueFigures(totaux, 'magic'), 'en moyenne');

      expect(f.value, euros(167.83 / 617));
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

  group('écrire une somme en euros', () {
    test('la virgule, et le symbole plutôt que le mot', () {
      expect(euros(167.8), '167,80 €');
      expect(euros(0), '0,00 €');
    });

    test('l’espace avant le symbole est insécable', () {
      // Sur une tuile qui occupe une demi-largeur d'écran, une espace
      // ordinaire laisserait « 167,45 » et « € » tomber sur deux lignes, et le
      // chiffre principal de la page se lirait en escalier.
      expect(euros(167.45), isNot(contains('167,45 €')));
      expect(euros(167.45).codeUnits, contains(0x00A0));
    });
  });

  group('quelle taille de booster est retenue', () {
    test('sans réponse de l’utilisateur, le repère s’applique', () {
      expect(boosterSizeFor('magic', const {}), 14);
      expect(boosterSizeFor('swu', const {}), 16);
    });

    test('la réponse de l’utilisateur prime sur le repère', () {
      expect(boosterSizeFor('magic', const {'magic': 15}), 15);
    });

    test('zéro n’est pas une réponse, au contraire du prix', () {
      // Un booster à zéro carte ne décrit aucun produit, et il diviserait par
      // zéro les deux indicateurs qui s'en servent.
      expect(boosterSizeFor('magic', const {'magic': 0}), 14);
      expect(boosterSizeFor('magic', const {'magic': -3}), 14);
    });

    test('la taille d’un jeu ne déborde pas sur un autre', () {
      expect(boosterSizeFor('pokemon', const {'magic': 15}), 10);
    });

    test('un jeu inconnu n’a aucune taille, même de repère', () {
      expect(boosterSizeFor('un-jeu-qui-nexiste-pas', const {}), isNull);
    });
  });

  group('lire une taille saisie à la main', () {
    test('un entier, et rien d’autre', () {
      expect(parseBoosterSize('15'), 15);
      expect(parseBoosterSize(' 15 '), 15);
    });

    test('vide veut dire « je retire ma réponse »', () {
      expect(parseBoosterSize(''), isNull);
      expect(parseBoosterSize('   '), isNull);
    });

    test('zéro et les négatifs sont refusés', () {
      expect(parseBoosterSize('0'), isNull);
      expect(parseBoosterSize('-3'), isNull);
    });

    test('ce qui n’est pas un entier est refusé', () {
      expect(parseBoosterSize('quatorze'), isNull);
      expect(parseBoosterSize('14,5'), isNull);
    });
  });

  group('lire la colonne booster_sizes', () {
    test('un entier venu de Postgres est une taille', () {
      expect(boosterSizesFromColumn({'magic': 15}), {'magic': 15});
    });

    test('une taille écrite en décimal est acceptée, et tronquée', () {
      // Le nombre décrit un compte d'objets ; refuser la forme décimale d'un
      // entier ferait perdre la déclaration sans rien protéger.
      expect(boosterSizesFromColumn({'magic': 15.0}), {'magic': 15});
    });

    test('une colonne absente ne casse rien', () {
      expect(boosterSizesFromColumn(null), isEmpty);
      expect(boosterSizesFromColumn('n’importe quoi'), isEmpty);
    });

    test('ce qui ne décrit pas un produit est écarté, pas deviné', () {
      final lu = boosterSizesFromColumn({
        'magic': 15,
        'pokemon': 0,
        'yugioh': -2,
        'swu': 'douze',
        'lorcana': null,
      });

      expect(lu, {'magic': 15});
    });
  });
}
