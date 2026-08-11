/// Tests du garde-fou de délai.
///
/// **Ce qu'ils protègent : qu'une requête sans réponse finisse.** Le défaut
/// qu'ils verrouillent n'était pas une lenteur mais une absence — une
/// connexion morte ne renvoie ni réponse ni erreur, et le `Future` restait en
/// attente pour toujours, l'écran tournant avec lui.
library;

import 'dart:async';

import 'package:deckhand/src/config/request_timeout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;

void main() {
  group('une requête qui ne revient jamais', () {
    test('finit par échouer plutôt que d\'attendre sans fin', () async {
      // Une connexion morte, exactement : rien n'arrive, rien n'échoue.
      final jamais = Completer<int>().future;

      await expectLater(
        jamais.timedOut(const Duration(milliseconds: 20)),
        throwsA(isA<RequestTimedOut>()),
      );
    });

    test('se dit dans une langue lisible', () {
      // « TimeoutException after 0:00:20.000000 » ne dit rien à qui tient un
      // téléphone : l'interface affiche ce texte tel quel.
      expect(
        const RequestTimedOut().toString(),
        contains('Vérifiez votre connexion'),
      );
    });
  });

  group('un serveur qu\'on ne sait pas joindre', () {
    // Vécu sur le téléphone : « ClientException with SocketException: Failed
    // host lookup: 'udqoptxqipmxqwfhgted.supabase.co' » s'affichait tel quel
    // dans l'écran Collection. Le nom du serveur n'avait pas pu être résolu —
    // un VPN actif impose son propre résolveur, qui peut échouer alors que le
    // reste du réseau fonctionne.
    test('se dit dans une langue lisible', () async {
      await expectLater(
        Future<int>.error(
          ClientException('Failed host lookup: \'exemple.supabase.co\''),
        ).timedOut(),
        throwsA(isA<NetworkUnreachable>()),
      );
    });

    test('nomme la cause plutôt que le type Dart', () {
      final message = const NetworkUnreachable().toString();
      expect(message, contains('Vérifiez votre connexion'));
      expect(message, contains('VPN'));
      expect(message, isNot(contains('Exception')));
    });

    test('ne se confond pas avec un délai dépassé', () {
      // Deux pannes distinctes, dont une seule se guérit en attendant : le
      // délai laisse espérer qu'un second essai aboutisse, l'injoignable dit
      // que la requête n'est jamais partie.
      expect(const NetworkUnreachable(), isNot(isA<RequestTimedOut>()));
    });
  });

  group('une requête qui revient', () {
    test('passe intacte', () async {
      expect(await Future.value(42).timedOut(), 42);
    });

    test('laisse remonter son erreur sans la travestir', () async {
      // Le délai ne doit pas transformer une erreur du serveur en panne de
      // réseau : le diagnostic en dépend.
      await expectLater(
        Future<int>.error(const FormatException('nombre attendu')).timedOut(),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
