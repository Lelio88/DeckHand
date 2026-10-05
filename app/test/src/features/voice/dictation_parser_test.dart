/// Tests du découpage d'une dictée en cartes.
///
/// Les cas viennent de ce qu'un moteur vocal rend réellement : pas de
/// ponctuation fiable, des mots de liaison, des quantités en toutes lettres, et
/// du bruit de langage.
///
/// Les cas d'édition et de finition viennent, eux, du catalogue : chaque mot
/// réservé à la dictée est aussi un mot de nom de carte quelque part — « Plan
/// brillant », « Extension de la sphère », « Into the Story: Assassin
/// Edition », « Foil ». Ces cartes-là doivent rester trouvables.
library;

import 'package:deckhand/src/features/voice/domain/dictation_parser.dart';
import 'package:deckhand/src/features/voice/domain/spoken_printing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('une seule carte', () {
    test('une dictée simple donne une carte en un exemplaire', () {
      expect(parseDictation('foudre'), [DictatedCard('foudre')]);
    });

    test('un nom composé reste entier', () {
      expect(parseDictation('anneau solaire'), [
        DictatedCard('anneau solaire'),
      ]);
    });

    test('la casse et les espaces superflus sont absorbés', () {
      expect(parseDictation('  Sol   Ring  '), [DictatedCard('sol ring')]);
    });

    test('la ponctuation finale est retirée', () {
      expect(parseDictation('contresort.'), [DictatedCard('contresort')]);
    });
  });

  group('quantités', () {
    test('un nombre en toutes lettres est reconnu', () {
      expect(parseDictation('quatre foudre'), [
        DictatedCard('foudre', quantity: 4),
      ]);
    });

    test('un nombre en chiffres est reconnu', () {
      expect(parseDictation('3 contresort'), [
        DictatedCard('contresort', quantity: 3),
      ]);
    });

    test('un nombre anglais est reconnu aussi', () {
      expect(parseDictation('two sol ring'), [
        DictatedCard('sol ring', quantity: 2),
      ]);
    });

    test('un nombre en fin de segment appartient au nom de la carte', () {
      // « Fire // Ice », « Borrowing 100 000 Arrows »… un nombre placé après le
      // nom n'est pas une quantité.
      expect(parseDictation('borrowing 100'), [DictatedCard('borrowing 100')]);
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
        DictatedCard('foudre'),
        DictatedCard('anneau solaire'),
      ]);
    });

    test('« ensuite » et « et » séparent également', () {
      final result = parseDictation('foudre ensuite contresort et île');
      expect(result.map((c) => c.query), ['foudre', 'contresort', 'île']);
    });

    test('chaque segment garde sa propre quantité', () {
      expect(parseDictation('quatre foudre puis deux contresort'), [
        DictatedCard('foudre', quantity: 4),
        DictatedCard('contresort', quantity: 2),
      ]);
    });

    test('les virgules séparent les mots sans découper les cartes', () {
      // La ponctuation d'un moteur vocal n'est pas fiable ; seuls les mots
      // de liaison font foi.
      expect(parseDictation('anneau, solaire'), [
        DictatedCard('anneau solaire'),
      ]);
    });
  });

  group('bruit de langage', () {
    test('les hésitations sont écartées', () {
      expect(parseDictation('euh foudre'), [DictatedCard('foudre')]);
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

  group('édition dite', () {
    test('« édition » sépare le nom de la carte de son extension', () {
      expect(parseDictation('foudre édition dominaria'), [
        const DictatedCard(
          'foudre',
          printing: SpokenPrinting(set: 'dominaria'),
        ),
      ]);
    });

    test('« extension » et « edition » sans accent valent « édition »', () {
      expect(
        parseDictation('foudre extension m21').single.printing,
        const SpokenPrinting(set: 'm21'),
      );
      expect(
        parseDictation('foudre edition m21').single.printing,
        const SpokenPrinting(set: 'm21'),
      );
    });

    test('la quantité et une extension en plusieurs mots coexistent', () {
      expect(
        parseDictation('quatre anneau solaire édition commander legends'),
        [
          const DictatedCard(
            'anneau solaire',
            quantity: 4,
            printing: SpokenPrinting(set: 'commander legends'),
          ),
        ],
      );
    });

    test("« numéro » détache le numéro de collection de l'extension", () {
      expect(
        parseDictation('foudre édition m21 numéro 137').single.printing,
        const SpokenPrinting(set: 'm21', number: '137'),
      );
      expect(
        parseDictation('foudre édition m21 n° 137').single.printing,
        const SpokenPrinting(set: 'm21', number: '137'),
      );
    });

    test("un nombre dans le nom d'extension lui appartient", () {
      // « Modern Horizons 2 », « Core Set 2021 » : sans « numéro », un nombre
      // ne désigne rien d'autre que l'extension.
      expect(
        parseDictation('foudre édition modern horizons 2').single.printing,
        const SpokenPrinting(set: 'modern horizons 2'),
      );
    });

    test("un numéro sans extension reste dans ce qu'on cherche", () {
      // Seul, un numéro ne désigne rien — la même règle que le serveur des
      // assistants. Laissé tel quel, il ne trouvera aucune extension, et la
      // ligne dira pourquoi.
      expect(
        parseDictation('foudre édition numéro 137').single.printing,
        const SpokenPrinting(set: 'numéro 137'),
      );
    });

    test("chaque carte d'une dictée continue a sa propre édition", () {
      expect(parseDictation('foudre édition m21 puis contresort'), [
        const DictatedCard('foudre', printing: SpokenPrinting(set: 'm21')),
        const DictatedCard('contresort'),
      ]);
    });

    test('un mot-clé en tête appartient au nom de la carte', () {
      // « Extension de la sphère » : rien ne précède le mot-clé, il n'y a donc
      // pas de carte à qui donner une extension.
      expect(parseDictation('extension de la sphère'), [
        const DictatedCard('extension de la sphère'),
      ]);
      expect(parseDictation('deux extension de la sphère'), [
        const DictatedCard('extension de la sphère', quantity: 2),
      ]);
    });

    test('un mot-clé en fin de segment appartient au nom de la carte', () {
      // « Into the Story: Assassin Edition » : rien ne suit le mot-clé.
      expect(parseDictation('into the story assassin edition'), [
        const DictatedCard('into the story assassin edition'),
      ]);
    });
  });

  group('finition dite', () {
    test("« brillante » après l'extension demande la version brillante", () {
      expect(
        parseDictation('foudre édition m21 brillante').single.printing,
        const SpokenPrinting(set: 'm21', foil: true),
      );
      expect(
        parseDictation('deux foudre édition m21 brillantes').single.printing,
        const SpokenPrinting(set: 'm21', foil: true),
      );
    });

    test('la finition suit le numéro', () {
      expect(
        parseDictation('foudre édition m21 numéro 137 foil').single.printing,
        const SpokenPrinting(set: 'm21', number: '137', foil: true),
      );
    });

    test('« foil » se dit aussi sans édition', () {
      expect(parseDictation('quatre foudre foil'), [
        const DictatedCard(
          'foudre',
          quantity: 4,
          printing: SpokenPrinting(foil: true),
        ),
      ]);
    });

    test('« en brillante » se dit sans édition', () {
      expect(parseDictation('foudre en brillante'), [
        const DictatedCard('foudre', printing: SpokenPrinting(foil: true)),
      ]);
    });

    test('« brillant » seul en fin de nom appartient à la carte', () {
      // Six cartes françaises finissent par ce mot : « Plan brillant »,
      // « Spectre brillant », « Restauration brillante »… Sans extension pour
      // le précéder ni « en » pour l'annoncer, c'est un nom.
      expect(parseDictation('plan brillant'), [
        const DictatedCard('plan brillant'),
      ]);
      expect(parseDictation('plan brillant édition m21'), [
        const DictatedCard(
          'plan brillant',
          printing: SpokenPrinting(set: 'm21'),
        ),
      ]);
    });

    test('« foil » seul est la carte de ce nom', () {
      expect(parseDictation('foil'), [const DictatedCard('foil')]);
      expect(parseDictation('foil édition m21'), [
        const DictatedCard('foil', printing: SpokenPrinting(set: 'm21')),
      ]);
    });

    test("la finition se dit aussi avant l'extension", () {
      expect(parseDictation('foudre en foil édition m21'), [
        const DictatedCard(
          'foudre',
          printing: SpokenPrinting(set: 'm21', foil: true),
        ),
      ]);
      expect(
        parseDictation('foudre foil édition m21').single.printing,
        const SpokenPrinting(set: 'm21', foil: true),
      );
    });

    test('la finition se dit aussi avant le numéro', () {
      expect(
        parseDictation(
          'foudre édition m21 brillante numéro 137',
        ).single.printing,
        const SpokenPrinting(set: 'm21', number: '137', foil: true),
      );
    });

    test("en dictée anglaise, « in foil » et « number »", () {
      expect(parseDictation('lightning bolt in foil'), [
        const DictatedCard(
          'lightning bolt',
          printing: SpokenPrinting(foil: true),
        ),
      ]);
      expect(
        parseDictation('lightning bolt edition m21 number 137').single.printing,
        const SpokenPrinting(set: 'm21', number: '137'),
      );
    });
  });
}
