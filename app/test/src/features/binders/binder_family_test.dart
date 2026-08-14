/// Regroupement des classeurs par famille d'extension.
///
/// **Ce que le regroupement doit faire, et surtout ne pas faire.** Il rassemble
/// à l'affichage ce qu'une même sortie a produit — l'extension de boosters, les
/// decks Commander, et les jetons de chacune. Il ne **fusionne** rien : chaque
/// extension garde son classeur, parce que les numérotations se chevauchent et
/// que trois cartes différentes portent le n° 1.
library;

import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/domain/binder_family.dart';
import 'package:flutter_test/flutter_test.dart';

BinderShelfEntry shelf(
  String code, {
  String? parent,
  String type = 'expansion',
  int cells = 100,
}) => BinderShelfEntry(
  setCode: code,
  setName: code.toUpperCase(),
  totalCells: 500,
  ownedCells: cells,
  ownedCopies: cells,
  parentSetCode: parent,
  setType: type,
);

void main() {
  group('la famille rassemble ce qu_une sortie a produit', () {
    test('les satellites rejoignent leur extension mère', () {
      final familles = groupIntoFamilies([
        shelf('msh', cells: 310),
        shelf('tmsh', parent: 'msh', type: 'token', cells: 15),
        shelf('msc', parent: 'msh', type: 'commander', cells: 14),
      ]);

      expect(familles.length, 1);
      expect(familles.single.head.setCode, 'msh');
      expect(
        familles.single.satellites.map((e) => e.setCode),
        containsAll(['tmsh', 'msc']),
      );
    });

    test('un petit-enfant remonte jusqu_à la racine', () {
      // `tmsc` dépend de `msc`, qui dépend de `msh` : les trois sont une seule
      // sortie, et s'arrêter au premier parent ferait deux familles.
      final familles = groupIntoFamilies([
        shelf('msh', cells: 310),
        shelf('msc', parent: 'msh', type: 'commander', cells: 14),
        shelf('tmsc', parent: 'msc', type: 'token', cells: 1),
      ]);

      expect(familles.length, 1);
      expect(familles.single.satellites.map((e) => e.setCode), hasLength(2));
    });

    test('une extension sans parent forme sa propre famille', () {
      final familles = groupIntoFamilies([
        shelf('msh', cells: 310),
        shelf('mar', type: 'masterpiece', cells: 3),
      ]);

      expect(familles.map((f) => f.head.setCode), ['msh', 'mar']);
      expect(familles.every((f) => f.satellites.isEmpty), isTrue);
    });
  });

  group('les cas où la mère manque', () {
    test('un satellite orphelin devient sa propre tête', () {
      // **On peut posséder des jetons sans posséder l'extension.** Les
      // rattacher à une mère absente les ferait disparaître de l'étagère.
      final familles = groupIntoFamilies([
        shelf('tmsh', parent: 'msh', type: 'token', cells: 15),
      ]);

      expect(familles.length, 1);
      expect(familles.single.head.setCode, 'tmsh');
      expect(familles.single.satellites, isEmpty);
    });

    test('une chaîne interrompue s_arrête au dernier possédé', () {
      // `tmsc` → `msc` → `msh`, mais `msh` n'est pas possédé : la famille se
      // forme autour de `msc`, pas autour d'un fantôme.
      final familles = groupIntoFamilies([
        shelf('msc', parent: 'msh', type: 'commander', cells: 14),
        shelf('tmsc', parent: 'msc', type: 'token', cells: 1),
      ]);

      expect(familles.length, 1);
      expect(familles.single.head.setCode, 'msc');
      expect(familles.single.satellites.single.setCode, 'tmsc');
    });

    test('une parenté circulaire ne fait pas tourner la boucle', () {
      // La source ne devrait jamais en produire, mais une donnée fausse ne doit
      // pas figer l'écran.
      final familles = groupIntoFamilies([
        shelf('a', parent: 'b'),
        shelf('b', parent: 'a'),
      ]);

      expect(familles, isNotEmpty);
    });
  });

  group('les jetons se rangent après le reste', () {
    test('ils passent derrière les satellites jouables', () {
      final familles = groupIntoFamilies([
        shelf('msh', cells: 310),
        shelf('tmsh', parent: 'msh', type: 'token', cells: 99),
        shelf('msc', parent: 'msh', type: 'commander', cells: 14),
      ]);

      // `tmsh` a plus de cases que `msc` : sans la règle, il passerait devant.
      expect(
        familles.single.satellites.map((e) => e.setCode),
        ['msc', 'tmsh'],
      );
    });

    test('une extension de jetons se reconnaît à son type', () {
      expect(shelf('tmsh', type: 'token').isTokenSet, isTrue);
      expect(shelf('msh').isTokenSet, isFalse);
      expect(shelf('msc', type: 'commander').isTokenSet, isFalse);
    });
  });

  group('l_ordre des familles suit celui reçu', () {
    test('la tête la mieux garnie ouvre l_étagère', () {
      // La base trie déjà par nombre de cases : le regroupement ne doit pas
      // remonter une famille au motif qu'elle a plus de satellites.
      final familles = groupIntoFamilies([
        shelf('grand', cells: 300),
        shelf('petit', cells: 10),
        shelf('t-petit', parent: 'petit', type: 'token', cells: 9),
        shelf('t2-petit', parent: 'petit', type: 'token', cells: 8),
      ]);

      expect(familles.map((f) => f.head.setCode), ['grand', 'petit']);
    });

    test('une mère moins garnie que son satellite reste la tête', () {
      final familles = groupIntoFamilies([
        shelf('tmsh', parent: 'msh', type: 'token', cells: 300),
        shelf('msh', cells: 10),
      ]);

      expect(familles.single.head.setCode, 'msh');
    });
  });
}
