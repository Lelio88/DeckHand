/// Tests du répit de relance de la dictée.
///
/// **Ce que ces tests protègent.** Le moteur clôt parfois sa session sans
/// livrer de résultat final : la phrase est transcrite, elle s'affiche, mais
/// rien n'est jamais rendu comme définitif — donc rien n'est cherché au
/// catalogue. Le paquet rattrape ce cas en promouvant, deux secondes après
/// l'arrêt, la dernière transcription partielle. Mais `listen()` annule ce
/// rattrapage dès son premier geste : relancer trop tôt le détruit, et la carte
/// dictée est perdue sans un mot d'explication.
///
/// Ce défaut a été mesuré sur l'appareil — une carte dictée, neuf
/// transcriptions partielles, aucun résultat final, relance à +401 ms. Il est
/// invisible depuis un test d'intégration : il faut un vrai moteur, une vraie
/// voix. D'où ce test sur la seule décision qui compte, isolée pour être
/// vérifiable sans microphone.
library;

import 'package:deckhand/src/features/voice/data/speech_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() {
  test('sans résultat final, la relance laisse jouer le rattrapage', () {
    // Le seuil vient du paquet et non d'une constante recopiée : s'il changeait
    // son délai de rattrapage, ce test le signalerait au lieu de laisser la
    // dictée redevenir muette en silence.
    expect(
      restartDelayAfter(finalSeen: false),
      greaterThan(SpeechToText.defaultFinalTimeout),
      reason:
          'relancer avant la fin du rattrapage annule la promotion du '
          'dernier partiel en résultat final, et la phrase est perdue',
    );
  });

  test('après un résultat final, la relance reste immédiate', () {
    // Le cas courant ne doit pas payer le prix du cas dégradé : la phrase est
    // déjà livrée, il n'y a plus rien à attendre, et deux secondes de trou
    // entre chaque carte rendraient la dictée continue plus lente que le
    // clavier — sa seule raison d'être.
    expect(
      restartDelayAfter(finalSeen: true),
      lessThan(const Duration(seconds: 1)),
    );
  });
}
