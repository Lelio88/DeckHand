/// L'application s'annonce-t-elle aux sources qu'elle interroge ?
///
/// **Ce que ce test protège est invisible autrement.** Scryfall rend
/// `HTTP 400 generic_user_agent` à un client qui ne se nomme pas — mesuré sur
/// `cards.scryfall.io`, qui sert toutes les illustrations. L'application
/// n'envoyait aucun `User-Agent` et passait quand même, le défaut de Dart
/// franchissant le filtre. Le jour où la source le resserre, **toutes** les
/// illustrations tombent d'un coup sur mobile — et rien, ni l'analyse ni les
/// tests d'écran, n'aurait vu venir la perte de l'en-tête.
///
/// Le web ne le verrait même pas : les navigateurs interdisent de remplacer
/// `User-Agent` et posent le leur, qui n'a rien de générique. La panne serait
/// donc mobile seulement, sur un chemin qu'aucun test d'intégration ne couvre.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:deckhand/src/common/card_image.dart';
import 'package:deckhand/src/config/user_agent.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Retient l'en-tête reçu, puis rend une réponse que le décodeur refusera —
/// ce qui suffit : l'assertion porte sur la requête, pas sur l'image.
class ClientTemoin extends http.BaseClient {
  Map<String, String>? dernierEntetes;
  final requetes = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    dernierEntetes = Map<String, String>.from(request.headers);
    requetes.add(request.url);
    final corps = Uint8List.fromList(const [0, 1, 2, 3]);
    return http.StreamedResponse(Stream.value(corps), 200,
        contentLength: corps.length, request: request);
  }
}

void main() {
  // La liaison donne l'`ImageCache` dont `resolve` a besoin.
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientTemoin temoin;

  setUp(() {
    temoin = ClientTemoin();
    cardImageClient = temoin;
  });
  tearDown(() => cardImageClient = null);

  test('la constante nomme l\'application et où la joindre', () {
    // Les deux choses que la source a besoin de savoir : qui appelle, et où
    // écrire. Un agent qui ne dirait ni l'un ni l'autre serait « générique »
    // au sens exact où Scryfall l'entend.
    expect(deckHandUserAgent, contains('DeckHand'));
    expect(deckHandUserAgent, contains('@'));
    expect(userAgentHeader['User-Agent'], deckHandUserAgent);
  });

  test("le téléchargement d'une illustration porte l'en-tête", () async {
    // Une URL distincte à chaque passe : le cache disque répondrait sinon à la
    // place du réseau, et le test n'observerait aucune requête.
    final unique = DateTime.now().microsecondsSinceEpoch;
    final provider = CardImageProvider(
      'https://cards.scryfall.io/normal/front/0/0/$unique.jpg',
    );

    // **Un `test` et non un `testWidgets`.** Le second installe une horloge
    // factice : la résolution de l'image y part sans jamais avancer, et le
    // témoin ne voyait aucune requête. Rien ici n'a besoin d'un arbre de
    // widgets — seulement de la liaison, pour l'`ImageCache`.
    final fini = Completer<void>();
    provider.resolve(ImageConfiguration.empty).addListener(
          ImageStreamListener(
            (_, _) {
              if (!fini.isCompleted) fini.complete();
            },
            // Le décodage échoue sur quatre octets qui ne sont pas une image :
            // c'est attendu, et sans conséquence pour ce qu'on vérifie.
            onError: (_, _) {
              if (!fini.isCompleted) fini.complete();
            },
          ),
        );
    await fini.future.timeout(const Duration(seconds: 10), onTimeout: () {});

    expect(temoin.requetes, isNotEmpty, reason: 'aucune requête observée');
    expect(temoin.dernierEntetes?['User-Agent'], deckHandUserAgent);
  });
}
