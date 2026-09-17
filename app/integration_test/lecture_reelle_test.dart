/// Ce que l'OCR lit vraiment sur une photo, et ce que la sélection en garde.
///
/// **Le trou que ce banc comble.** `plafond_reel_test.dart` dit *par quelle
/// voie* une photo a conclu, jamais *pourquoi* la voie du nom a échoué. Sur les
/// deux `Turn // Burn` du banc, il annonce `noms_lus=10` puis `voie=illustration`
/// — dix lignes lues, aucune n'ayant rencontré le catalogue. Sans voir ces
/// lignes, corriger reviendrait à deviner : la carte est pourtant indexée sous
/// « Turn », « Burn » et « Turn // Burn ».
///
/// Ce test affiche, pour chaque photo, **toutes** les lignes avec leur position
/// et leur hauteur, puis marque celles que [cardNameCandidates] retient. Il
/// rejoue aussi les écritures de repli, la cascade pouvant lire ce que le latin
/// manque.
///
/// **Aucune assertion sur le contenu.** Sa sortie *est* son résultat, comme les
/// autres bancs : il n'y a pas de bonne réponse à opposer, on cherche à voir.
///
/// Photos et lancement : voir `plafond_reel_test.dart`. Par défaut toutes les
/// photos du dossier y passent ; `--dart-define=DECKHAND_PHOTOS=<filtre>` les
/// restreint à celles dont le nom contient le filtre, seul moyen de ne pas
/// noyer le cas étudié sous quarante-cinq autres.
///
/// ```
/// flutter test integration_test/lecture_reelle_test.dart -d <appareil> \
///   --dart-define=DECKHAND_PHOTOS=191327493 \
///   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:deckhand/src/config/ocr_script.dart';
import 'package:deckhand/src/features/scan/data/card_text_reader.dart';
import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Ne garder que les photos dont le nom contient ce texte. Vide : toutes.
const String _filtre = String.fromEnvironment('DECKHAND_PHOTOS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ce que chaque écriture lit sur les photos du banc', (
    tester,
  ) async {
    final dossier = await getExternalStorageDirectory();
    expect(dossier, isNotNull, reason: 'dossier externe indisponible');

    final photos =
        dossier!
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.jpg'))
            .where((f) => _filtre.isEmpty || f.path.contains(_filtre))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(
      photos,
      isNotEmpty,
      reason: 'aucune photo ne correspond au filtre « $_filtre »',
    );
    print('LECTURE ${photos.length} photo(s), filtre « $_filtre »');

    // Le latin d'abord — c'est le réglage par défaut, donc ce que vit
    // l'utilisateur — puis les écritures que la cascade essaierait.
    final ecritures = <OcrScript>[
      OcrScript.latin,
      ...OcrScript.latin.fallbacks,
    ];

    for (final photo in photos) {
      final nom = photo.uri.pathSegments.last;
      for (final ecriture in ecritures) {
        final lecteur = CardTextReader(script: ecriture);
        List<ReadLine> lignes;
        try {
          lignes = await lecteur.readLines(photo.path);
        } catch (erreur) {
          print('LECTURE $nom ${ecriture.id} ERREUR $erreur');
          lecteur.dispose();
          continue;
        }
        final retenus = cardNameCandidates(lignes);
        final gardes = retenus.map((t) => t.toLowerCase()).toSet();

        print(
          'LECTURE $nom ${ecriture.id} '
          'lignes=${lignes.length} retenus=${retenus.length} '
          'candidats=[${retenus.join(" | ")}]',
        );
        for (final ligne in lignes) {
          final propre = cleanNameLine(ligne.text);
          final garde = gardes.contains(propre.toLowerCase());
          // `looksLikeCardName` dit si la ligne *pourrait* être un nom ; la
          // comparer à ce qui est retenu sépare « écartée par un filtre » de
          // « hors de la zone du nom », deux causes qui ne se corrigent pas
          // au même endroit.
          final plausible = looksLikeCardName(propre);
          final dansZone = ligne.top < 0.66;
          print(
            '  ${garde ? "GARDE " : "      "}'
            'top=${ligne.top.toStringAsFixed(3)} '
            'left=${ligne.left.toStringAsFixed(3)} '
            'h=${ligne.height.toStringAsFixed(3)} '
            'w=${ligne.width.toStringAsFixed(3)} '
            '${plausible ? "nom?oui" : "nom?non"} '
            '${dansZone ? "zone?oui" : "zone?NON"} '
            '« ${ligne.text} »',
          );
        }
        lecteur.dispose();
      }
    }
    print('LECTURE fini');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
