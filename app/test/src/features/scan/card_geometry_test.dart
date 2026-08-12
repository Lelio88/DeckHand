/// Tests des proportions de carte par jeu.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chaque jeu couvert déclare ses proportions', () {
    // **C'est le seul garde-fou possible ici.** Le domaine du scan reçoit le
    // jeu sous forme de chaîne — pour rester jumelable avec le Python et
    // testable sans Flutter —, donc le compilateur ne peut pas exiger une
    // entrée par jeu comme il le fait pour `cardTypesFor` ou `deckFormatsFor`.
    // Sans ce test, ajouter un jeu le ferait retomber sur les proportions de
    // Magic sans un mot, et le repli du scan découperait de travers.
    for (final game in Game.values) {
      expect(
        cardAspects.containsKey(game.id),
        isTrue,
        reason:
            'Le jeu « ${game.id} » n\'a pas de proportions déclarées dans '
            'cardAspects. Sans elles, il hérite de celles de Magic en silence.',
      );
    }
  });

  test('un jeu inconnu retombe sur le repli plutôt que de lever', () {
    // Refuser de scanner serait pire que scanner de travers : le repli garde la
    // reconnaissance en marche, et le test précédent est ce qui empêche d'y
    // arriver par accident.
    expect(cardAspectFor('un-jeu-qui-n-existe-pas'), defaultCardAspect);
  });

  test('les deux jeux couverts impriment sur le même carton', () {
    // Fait établi, et c'est précisément ce qui a permis à la constante de rester
    // en dur si longtemps sans que rien ne casse.
    expect(cardAspectFor('magic'), cardAspectFor('riftbound'));
    expect(cardAspectFor('magic'), closeTo(0.716, 0.001));
  });
}
