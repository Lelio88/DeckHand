/// Tests de la règle qui distingue « nouvelle carte » de « encore la même ».
///
/// Le flux sert des dizaines d'images par seconde ; une carte posée devant
/// l'objectif y apparaît des dizaines de fois. Sans règle temporelle, le panier
/// se remplirait de trente exemplaires de la même carte par seconde, et le
/// journal serait illisible.
///
/// Les séquences ci-dessous décrivent ce que voit la reconnaissance image par
/// image : un identifiant, ou `null` quand elle se tait.
library;

import 'package:deckhand/src/features/scan/domain/card_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Passe toute une séquence et rend les cartes émises, dans l'ordre.
List<String> emitted(CardTracker tracker, List<String?> frames) => [
  for (final frame in frames)
    if (tracker.observe(frame) case final String id) id,
];

void main() {
  group('une carte tenue devant l\'objectif n\'est comptée qu\'une fois', () {
    test('la série suffisante émet, une seule fois', () {
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'a', 'a', 'a', 'a', 'a']), ['a']);
    });

    test('une série trop courte n\'émet rien', () {
      // Deux images ne font pas une carte : c'est le prix à payer pour que la
      // reconnaissance d'une image isolée, fausse par accident, n'entre pas au
      // panier.
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'a']), isEmpty);
    });

    test('une image parasite ne coupe pas la série', () {
      // La reconnaissance se tait sur une image floue — un mouvement, une mise
      // au point. La carte, elle, n'a pas bougé.
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'a', null, 'a', 'a']), ['a']);
    });
  });

  group('deux cartes successives sont comptées deux fois', () {
    test('des cartes différentes émettent chacune', () {
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'a', 'a', 'b', 'b', 'b']), ['a', 'b']);
    });

    test('deux exemplaires de la même carte, séparés par un trou', () {
      // Le cas qui compte le plus : les communes arrivent par quatre. Retirer
      // la carte puis en poser une identique doit donner deux exemplaires.
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'a', 'a', null, null, 'a', 'a', 'a']), [
        'a',
        'a',
      ]);
    });

    test('une autre carte vue entre-temps vaut preuve de retrait', () {
      // Voir une carte différente prouve mieux qu'un blanc que la première a
      // été retirée : personne ne pose la seconde par-dessus la première. Ce
      // cas ne doit donc pas exiger d'écart d'images muettes.
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'a', 'a', 'b', 'b', 'b', 'a', 'a', 'a']), [
        'a',
        'b',
        'a',
      ]);
    });

    test('sans trou assez long, la même carte ne compte qu\'une fois', () {
      // Une seule image muette ne prouve pas qu'on a retiré la carte : c'est
      // le cas d'une mise au point qui hésite. Compter deux fois inventerait
      // un exemplaire que l'utilisateur ne possède pas — l'erreur la plus
      // coûteuse, puisqu'elle fausse ensuite les suggestions de decks.
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'a', 'a', null, 'a', 'a', 'a']), ['a']);
    });
  });

  group('ce que la règle refuse de faire', () {
    test('une suite d\'images muettes n\'émet rien', () {
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, [null, null, null, null]), isEmpty);
    });

    test('une alternance rapide n\'émet rien', () {
      // Deux cartes qui se disputent l'image — un chevauchement, un reflet —
      // ne forment aucune série. Se taire est le bon résultat.
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'b', 'a', 'b', 'a', 'b']), isEmpty);
    });

    test('changer de carte remet le compteur à zéro', () {
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      expect(emitted(tracker, ['a', 'a', 'b', 'a', 'a']), isEmpty);
    });
  });

  group('ce que le suivi expose pour le journal', () {
    test('la carte en cours est lisible sans attendre son émission', () {
      // Le journal et l'écran ont besoin de savoir ce que l'appareil regarde
      // *maintenant*, pas seulement ce qu'il a fini par retenir : c'est ce qui
      // permet d'afficher un aperçu pendant que la série se constitue.
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      tracker.observe('a');
      expect(tracker.watching, 'a');
      expect(tracker.streak, 1);

      tracker.observe('a');
      expect(tracker.streak, 2);

      tracker.observe('b');
      expect(tracker.watching, 'b');
      expect(tracker.streak, 1);
    });

    test('le suivi se remet à zéro', () {
      // Entre deux boosters, l'état ne doit pas survivre : la première carte du
      // second lot compterait sinon comme la suite du premier.
      final tracker = CardTracker(minFrames: 3, gapFrames: 2);

      emitted(tracker, ['a', 'a', 'a']);
      tracker.reset();

      expect(tracker.watching, isNull);
      expect(emitted(tracker, ['a', 'a', 'a']), ['a']);
    });
  });
}
