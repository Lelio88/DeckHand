/// Tests du panier du scan au fil de la caméra (#8).
///
/// **Ce panier existe pour le §IV.8** : rien n'entre en collection sans
/// confirmation. Ce qui se vérifie ici est donc ce que l'utilisateur peut faire
/// avant de confirmer — décocher, retirer, et voir compter juste.
library;

import 'package:deckhand/src/features/scan/domain/scan_basket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compter', () {
    test('une carte vue deux fois fait deux exemplaires', () {
      // C'est `CardTracker` qui a déjà décidé qu'il s'agissait de deux passages
      // distincts ; le panier ne fait que compter, et n'a aucune raison de
      // remettre cette décision en cause.
      final basket = ScanBasket()
        ..add('alpha')
        ..add('alpha');

      expect(basket.lines, hasLength(1));
      expect(basket.lines.single.quantity, 2);
      expect(basket.keptCount, 2);
    });

    test('deux cartes différentes font deux lignes', () {
      final basket = ScanBasket()
        ..add('alpha')
        ..add('beta');

      expect(basket.lines, hasLength(2));
      expect(basket.keptCount, 2);
    });

    test('la dernière vue est en tête', () {
      // Un booster se dépouille dans un ordre : retrouver la dernière carte en
      // haut est ce qui permet de vérifier d'un coup d'œil que le flux suit.
      final basket = ScanBasket()
        ..add('alpha')
        ..add('beta');

      expect(basket.lines.first.oracleId, 'beta');
    });
  });

  group('décocher', () {
    test('exclut du compte et de ce qu\'on enregistrera', () {
      final basket = ScanBasket()
        ..add('alpha')
        ..add('beta');
      basket.lines.firstWhere((l) => l.oracleId == 'beta').keep = false;

      expect(basket.keptCount, 1);
      expect(basket.kept.map((l) => l.oracleId), ['alpha']);
      // La ligne reste visible : la décocher n'est pas la supprimer.
      expect(basket.lines, hasLength(2));
    });

    test('une carte décochée puis revue redevient gardée', () {
      // Repasser la même carte devant l'objectif est un geste délibéré : le
      // lire comme « je la veux finalement » est la seule interprétation qui ne
      // perde pas l'intention.
      final basket = ScanBasket()..add('alpha');
      basket.lines.single.keep = false;
      expect(basket.keptCount, 0);

      basket.add('alpha');
      expect(basket.lines.single.keep, isTrue);
      expect(basket.lines.single.quantity, 2);
    });

    test('tout décocher laisse un panier sans rien à enregistrer', () {
      final basket = ScanBasket()..add('alpha');
      basket.lines.single.keep = false;

      expect(basket.kept, isEmpty);
      expect(basket.keptCount, 0);
      expect(basket.isEmpty, isFalse, reason: 'la ligne est là, non cochée');
    });
  });

  group('retirer', () {
    test('fait disparaître la ligne entière', () {
      final basket = ScanBasket()
        ..add('alpha')
        ..add('alpha')
        ..add('beta');
      basket.remove('alpha');

      expect(basket.lines.map((l) => l.oracleId), ['beta']);
      expect(basket.keptCount, 1);
    });

    test('vider rend le panier à son état initial', () {
      final basket = ScanBasket()
        ..add('alpha')
        ..clear();
      expect(basket.isEmpty, isTrue);
      expect(basket.keptCount, 0);
    });
  });

  group('la liste rendue', () {
    test('ne se modifie pas dans le dos du panier', () {
      // Une liste modifiable rendue au dehors laisserait l'écran ajouter une
      // ligne sans passer par `add`, donc sans le compte des exemplaires.
      final basket = ScanBasket()..add('alpha');
      expect(() => basket.lines.add(BasketLine('beta')), throwsUnsupportedError);
    });
  });
}
