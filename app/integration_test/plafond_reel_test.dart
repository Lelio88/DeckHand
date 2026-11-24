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
/// **En pleine résolution, comme `image_picker` les rend** : le sélecteur ne
/// borne plus la largeur (issue n°50). `--dart-define=DECKHAND_LARGEUR=1600`
/// rejoue l'ancienne chaîne — réduites au plus proche, qualité 92 — pour
/// comparer les deux sur les mêmes photos. Le dossier `files/etalement` passe
/// à la place de `files/bench` avec `--dart-define=DECKHAND_ETALEMENT=true`.
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
import 'dart:typed_data';

import 'package:deckhand/src/config/supabase_config.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/scan/application/scan_service.dart';
import 'package:deckhand/src/features/scan/domain/print_line_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Le compte du **propriétaire**, pas celui de démonstration.
///
/// `search_cards` lit `collection_items` et exige donc une session ouverte ;
/// sans elle, tout échoue en 401 et le banc mesurerait l'absence de session.
const String _email = String.fromEnvironment('DECKHAND_TEST_EMAIL');
const String _motDePasse = String.fromEnvironment('DECKHAND_TEST_PASSWORD');

/// Rejoue le banc comme si l'utilisateur avait coché « la carte se lit en
/// travers ».
///
/// **Mesurer le geste, pas seulement l'automatique.** Les quatre orientations
/// coûtent un faux positif sur ce banc et en gagnent d'autres ; savoir lesquels
/// demande de passer les mêmes photos dans les deux réglages, et de soustraire.
const bool _toutesOrientations = bool.fromEnvironment(
  'DECKHAND_TOUTES_ORIENTATIONS',
);

/// Largeur à laquelle réduire les photos ; zéro : pleine résolution.
const int _largeur = int.fromEnvironment('DECKHAND_LARGEUR');

/// Passer les photos d'étalement (`files/etalement`) au lieu du banc.
const bool _etalement = bool.fromEnvironment('DECKHAND_ETALEMENT');

/// La photo telle que l'application la recevrait : ses octets et un fichier,
/// réduits à [_largeur] quand il est fixé.
Future<(Uint8List, String)> _commeLeSelecteur(File photo) async {
  final octets = await photo.readAsBytes();
  if (_largeur <= 0) return (octets, photo.path);
  final image = img.decodeImage(octets)!;
  if (image.width <= _largeur) return (octets, photo.path);
  final reduite = img.encodeJpg(
    img.copyResize(
      image,
      width: _largeur,
      interpolation: img.Interpolation.nearest,
    ),
    quality: 92,
  );
  final chemin = '${Directory.systemTemp.path}/${photo.uri.pathSegments.last}';
  await File(chemin).writeAsBytes(reduite);
  return (reduite, chemin);
}

/// Ce que l'écran ferait de la ligne basse d'une carte (issue n°50) : la même
/// règle, `pickByPrintLine` puis le code d'extension, sur les mêmes éditions
/// que `_fillFromPrintLine` demande — langue lue, toutes ou rien.
Future<String> _editionLue(SpreadFind find, List<String> ligne) async {
  final carte = find.card;
  final editions = await PrintingRepository(
    Supabase.instance.client,
  ).forCard(carte.oracleId, lang: carte.matchedLang, limit: 200);
  if (editions.length >= 200) return '-';
  final retenue =
      pickByPrintLine(ligne, [
        for (final e in editions)
          (
            id: e.printId,
            collectorNumber: e.collectorNumber,
            year: e.releasedAt?.year,
          ),
      ]) ??
      pickBySetCode(ligne, [
        for (final e in editions) (id: e.printId, setCode: e.setCode),
      ]);
  if (retenue == null) return '-';
  final e = editions.firstWhere((e) => e.printId == retenue);
  return '${e.setCode}#${e.collectorNumber}';
}

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
    final externe = await getExternalStorageDirectory();
    expect(externe, isNotNull, reason: 'dossier externe indisponible');

    // **Repli sur le dossier privé, garni par `run-as`.** Sur un émulateur
    // neuf, l'application n'a jamais créé son dossier externe : celui qu'`adb`
    // y crée appartient à `shell`, et la lecture échoue
    // (`PathAccessException`). Voir `ligne_basse_test.dart`.
    List<File> jpg(Directory d) => d.existsSync()
        ? (d
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.jpg'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];
    var dossier = externe!;
    var photos = <File>[];
    try {
      photos = jpg(dossier);
    } on FileSystemException {
      photos = [];
    }
    if (photos.isEmpty) {
      dossier = Directory(
        '${(await getApplicationSupportDirectory()).path}/'
        '${_etalement ? 'etalement' : 'bench'}',
      );
      photos = jpg(dossier);
    }
    expect(
      photos,
      isNotEmpty,
      reason: 'photos absentes : adb push <photos>/. ${dossier.path}/',
    );
    print(
      'PLAFOND-REEL ${photos.length} photos dans ${dossier.path} '
      'toutesOrientations=$_toutesOrientations largeur=$_largeur',
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = await container.read(scanServiceProvider.future);
    print('PLAFOND-REEL index chargé');

    for (final photo in photos) {
      final nom = photo.uri.pathSegments.last;
      final (octets, chemin) = await _commeLeSelecteur(photo);
      final chrono = Stopwatch()..start();
      PhotoOutcome resultat;
      try {
        resultat = await service.recognisePhoto(
          octets,
          photoPath: chemin,
          precisions: (toutesOrientations: _toutesOrientations),
        );
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

      // La ligne basse : celle de la photo pour une carte seule, celle de
      // chaque carte sur un étalement.
      if (resultat.printLine.isNotEmpty) {
        print(
          'PLAFOND-LIGNE $nom '
          'edition=${await _editionLue(resultat.cards.first, resultat.printLine)} '
          'ligne=[${resultat.printLine.join(" | ")}]',
        );
      }
      for (final carte in resultat.cards) {
        if (carte.printLine.isEmpty) continue;
        print(
          'PLAFOND-ETAL $nom ${carte.card.name} '
          'edition=${await _editionLue(carte, carte.printLine)} '
          'ligne=[${carte.printLine.join(" | ")}]',
        );
      }
    }
    print('PLAFOND-REEL fini');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
