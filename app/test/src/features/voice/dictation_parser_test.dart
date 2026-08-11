/// Tests du découpage d'une dictée en cartes.
///
/// Les cas viennent de ce qu'un moteur vocal rend réellement : pas de
/// ponctuation fiable, des mots de liaison, des quantités en toutes lettres, et
/// du bruit de langage.
library;

import 'package:deckhand/src/features/voice/domain/dictation_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('une seule carte', () {
    test('une dictée simple donne une carte en un exemplaire', () {
      expect(parseDictation('foudre'), [(query: 'foudre', quantity: 1)]);
    });

    test('un nom composé reste entier', () {
      expect(parseDictation('anneau solaire'), [
        (query: 'anneau solaire', quantity: 1),
      ]);
    });

    test('la casse et les espaces superflus sont absorbés', () {
      expect(parseDictation('  Sol   Ring  '), [
        (query: 'sol ring', quantity: 1),
      ]);
    });

    test('la ponctuation finale est retirée', () {
      expect(parseDictation('contresort.'), [
        (query: 'contresort', quantity: 1),
      ]);
    });
  });

  group('quantités', () {
    test('un nombre en toutes lettres est reconnu', () {
      expect(parseDictation('quatre foudre'), [(query: 'foudre', quantity: 4)]);
    });

    test('un nombre en chiffres est reconnu', () {
      expect(parseDictation('3 contresort'), [
        (query: 'contresort', quantity: 3),
      ]);
    });

    test('un nombre anglais est reconnu aussi', () {
      expect(parseDictation('two sol ring'), [
        (query: 'sol ring', quantity: 2),
      ]);
    });

    test('un nombre en fin de segment appartient au nom de la carte', () {
      // « Fire // Ice », « Borrowing 100 000 Arrows »… un nombre placé après le
      // nom n'est pas une quantité.
      expect(parseDictation('borrowing 100'), [
        (query: 'borrowing 100', quantity: 1),
      ]);
    });

    test('un nombre seul n\'est pas une carte', () {
      expect(parseDictation('quatre'), isEmpty);
    });

    test('une quantité aberrante est ignorée et rattachée au nom', () {
      final result = parseDictation('9999 foudre');
      expect(result.single.quantity, 1);
      expect(result.single.query, contains('9999'));
    });
  });

  group('dictée continue', () {
    test('« puis » sépare deux cartes', () {
      expect(parseDictation('foudre puis anneau solaire'), [
        (query: 'foudre', quantity: 1),
        (query: 'anneau solaire', quantity: 1),
      ]);
    });

    test('« ensuite » et « et » séparent également', () {
      final result = parseDictation('foudre ensuite contresort et île');
      expect(result.map((c) => c.query), ['foudre', 'contresort', 'île']);
    });

    test('chaque segment garde sa propre quantité', () {
      expect(parseDictation('quatre foudre puis deux contresort'), [
        (query: 'foudre', quantity: 4),
        (query: 'contresort', quantity: 2),
      ]);
    });

    test('les virgules séparent les mots sans découper les cartes', () {
      // La ponctuation d'un moteur vocal n'est pas fiable ; seuls les mots
      // de liaison font foi.
      expect(parseDictation('anneau, solaire'), [
        (query: 'anneau solaire', quantity: 1),
      ]);
    });
  });

  group('bruit de langage', () {
    test('les hésitations sont écartées', () {
      expect(parseDictation('euh foudre'), [(query: 'foudre', quantity: 1)]);
    });

    test('une dictée vide ne produit rien', () {
      expect(parseDictation(''), isEmpty);
      expect(parseDictation('   '), isEmpty);
    });

    test('un souffle isolé ne produit pas de carte', () {
      expect(
        parseDictation('a'),
        isEmpty,
        reason:
            'proposer une carte au hasard sur du bruit serait pire '
            'que de ne rien proposer',
      );
    });

    test('des séparateurs enchaînés ne créent pas de cartes vides', () {
      expect(parseDictation('puis et ensuite'), isEmpty);
    });

    test('une dictée faite uniquement de bruit ne produit rien', () {
      expect(parseDictation('euh alors donc'), isEmpty);
    });
  });
}
