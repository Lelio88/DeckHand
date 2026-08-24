/// Ce que l'application reconnaît réellement, sur l'appareil (#8, #32).
///
/// **Le trou que ce banc comble.** `tool/plafond.dart` mesure la voie de
/// l'**empreinte** — il tourne en `dart run`, où ML Kit n'existe pas. Or le mode
/// photo réel lit d'abord les **noms** et ne tombe sur l'illustration que si
/// rien n'a été lu. Tous les taux publiés jusqu'ici décrivent donc le recours,
/// pas l'application, et rien ne permettait de déduire l'un de l'autre.
///
/// Ce test appelle `recognisePhoto` — le vrai, avec le vrai OCR, le vrai index,
/// le vrai catalogue — sur les photos du banc réel, et dit pour chacune par
/// quelle voie elle a conclu.
///
/// **Les photos ne sont pas dans le dépôt** : il est public. Elles sont poussées
/// dans le dossier externe de l'application, que celle-ci seule peut lire :
///
/// ```
/// adb push <photos>/. /sdcard/Android/data/app.deckhand.debug/files/
/// ```
///
/// **À la racine de `files/`, jamais dans un sous-dossier créé par `adb`.** Un
/// répertoire créé depuis `adb shell` appartient à `shell` ; l'application ne
/// peut alors pas le lister, et échoue en `PathAccessException` — mesuré. Les
/// fichiers, eux, se lisent sans peine une fois posés dans le dossier que
/// l'application possède déjà.
///
/// **Et sur `app.deckhand.debug`, pas `app.deckhand`.** Le build de mesure porte
/// un suffixe pour cohabiter avec celui du Play Store, dont la signature diffère
/// (voir `android/app/build.gradle.kts`). Pousser vers le dossier de
/// l'application réelle ne lui parvient donc pas.
///
/// **Réduites comme `image_picker` les réduirait** — largeur 1600, qualité 92.
/// Les passer en pleine résolution mesurerait une chaîne que l'application ne
/// voit jamais : le sélecteur de photo borne la largeur avant tout traitement.
///
/// Lancement :
///
/// ```
/// flutter test integration_test/plafond_reel_test.dart \
///   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
///   --dart-define=DECKHAND_TEST_EMAIL=... --dart-define=DECKHAND_TEST_PASSWORD=...
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:deckhand/src/config/supabase_config.dart';
import 'package:deckhand/src/features/scan/application/scan_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Le compte du **propriétaire**, pas celui de démonstration.
///
/// `search_cards` lit `collection_items` et exige donc une session ouverte ;
/// sans elle, tout échoue en 401 et le banc mesurerait l'absence de session.
const String _email = String.fromEnvironment('DECKHAND_TEST_EMAIL');
const String _motDePasse = String.fromEnvironment('DECKHAND_TEST_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ce que recognisePhoto rend sur le banc réel', (tester) async {
    expect(
      _email.isNotEmpty && _motDePasse.isNotEmpty,
      isTrue,
      reason: 'DECKHAND_TEST_EMAIL et DECKHAND_TEST_PASSWORD manquent',
    );
    SupabaseConfig.assertConfigured();
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
    await Supabase.instance.client.auth.signInWithPassword(
      email: _email,
      password: _motDePasse,
    );

    // **Le dossier que l'application possède, pas un sous-dossier d'`adb`.**
    // `path_provider` le rend ; un chemin écrit en dur sous `Android/data`
    // échoue depuis Android 10, et en silence.
    final dossier = await getExternalStorageDirectory();
    expect(dossier, isNotNull, reason: 'dossier externe indisponible');

    final photos =
        dossier!
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.jpg'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(
      photos,
      isNotEmpty,
      reason: 'photos absentes : adb push <photos>/. ${dossier.path}/',
    );
    print('PLAFOND-REEL ${photos.length} photos dans ${dossier.path}');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = await container.read(scanServiceProvider.future);
    print('PLAFOND-REEL index chargé');

    for (final photo in photos) {
      final nom = photo.uri.pathSegments.last;
      final octets = await photo.readAsBytes();
      final chrono = Stopwatch()..start();
      PhotoOutcome resultat;
      try {
        resultat = await service.recognisePhoto(octets, photoPath: photo.path);
      } catch (erreur) {
        print('PLAFOND-REEL $nom ERREUR $erreur');
        continue;
      }
      chrono.stop();

      // Une ligne par photo, préfixée pour être triée hors du bruit de test.
      // **Les identifiants plutôt que les noms** : la vérité du banc est en
      // extension et numéro de collection, et c'est Python qui les rapprochera.
      final cartes = resultat.cards
          .map((c) => '${c.card.oracleId}|${c.card.name}')
          .join(' ; ');
      print(
        'PLAFOND-REEL $nom '
        'noms_lus=${resultat.namesRead} '
        'voie=${resultat.fromArtwork ? "illustration" : "nom"} '
        'sur=${resultat.isConfident} '
        'methode=${resultat.method?.name ?? "-"} '
        'ms=${chrono.elapsedMilliseconds} '
        'cartes=[$cartes]',
      );
    }
    print('PLAFOND-REEL fini');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
