/// Le choix de l'écriture que la reconnaissance sait lire.
///
/// **Ce que ces tests protègent.** Le réglage ne se voit nulle part quand il
/// marche : il change le modèle de ML Kit, qui n'existe pas en test. Ce qui est
/// vérifiable, et ce qui casserait pour de bon, c'est la chaîne autour — la
/// préférence écrite, la préférence relue, le repli sur le latin quand elle est
/// illisible, et le fait que le lecteur soit **reconstruit** quand le choix
/// change. Sans ce dernier, le réglage n'agirait qu'au prochain démarrage, sans
/// que rien ne le dise.
library;

import 'package:deckhand/src/config/ocr_script.dart';
import 'package:deckhand/src/features/scan/data/card_text_reader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('identité des écritures', () {
    test('un identifiant connu retrouve son écriture', () {
      expect(OcrScript.fromId('japanese'), OcrScript.japanese);
      expect(OcrScript.fromId('latin'), OcrScript.latin);
    });

    test('un identifiant inconnu retombe sur le latin', () {
      // Préférence écrite par une version plus récente, ou valeur corrompue.
      // Lever ici rendrait la reconnaissance muette, panne que le repli sur
      // l'illustration rendrait presque invisible.
      expect(OcrScript.fromId('klingon'), OcrScript.latin);
      expect(OcrScript.fromId(null), OcrScript.latin);
    });

    test('chaque écriture dit qu\'elle couvre aussi le latin, ou l\'est', () {
      // Le japonais lit *aussi* le latin. Ne pas le dire ferait passer le choix
      // pour un renoncement au français, et personne ne le cocherait.
      expect(OcrScript.japanese.blurb.toLowerCase(), contains('latine'));
    });
  });

  group('la cascade de replis', () {
    test('le latin essaie les trois autres ecritures, dans l ordre', () {
      // L'ordre suit la couverture du catalogue Magic, seul a porter ces
      // ecritures : ja 29 979 noms, zhs+zht 33 638, ko 10 574.
      expect(OcrScript.latin.fallbacks, [
        OcrScript.japanese,
        OcrScript.chinese,
        OcrScript.korean,
      ]);
    });

    test('une ecriture ne se replie jamais sur elle-meme', () {
      for (final script in OcrScript.values) {
        expect(script.fallbacks, isNot(contains(script)), reason: script.label);
      }
    });

    test('on ne se replie jamais vers le latin', () {
      // Chaque modele non latin couvre deja le latin — LATIN_AND_JAPANESE et
      // ses homologues. Y revenir couterait une passe pour rien.
      for (final script in OcrScript.values) {
        expect(script.fallbacks, isNot(contains(OcrScript.latin)));
      }
    });

    test('chaque repli a un modele empaquete', () {
      // Un repli vers une ecriture absente de build.gradle.kts echouerait a
      // l'execution, et le repli sur l'illustration masquerait la panne.
      for (final script in OcrScript.values) {
        for (final repli in script.fallbacks) {
          expect(OcrScript.values, contains(repli));
        }
      }
    });
  });


  group('la préférence', () {
    test('part sur le latin quand rien n\'est enregistré', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(selectedOcrScriptProvider), OcrScript.latin);
    });

    test('un choix enregistré est restauré', () async {
      SharedPreferences.setMockInitialValues({'ocr_script': 'japanese'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Le notifier est synchrone et lit la préférence en tâche de fond : il
      // part sur le latin, puis se corrige. Attendre la file d'événements est
      // exactement ce que fait l'application au démarrage.
      expect(container.read(selectedOcrScriptProvider), OcrScript.latin);
      await pumpEventQueue();
      expect(container.read(selectedOcrScriptProvider), OcrScript.japanese);
    });

    test('choisir écrit la préférence', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(selectedOcrScriptProvider.notifier)
          .select(OcrScript.japanese);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ocr_script'), 'japanese');
      expect(container.read(selectedOcrScriptProvider), OcrScript.japanese);
    });
  });

  group('le lecteur suit le réglage', () {
    test('il naît sur l\'écriture choisie', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(cardTextReaderProvider).script, OcrScript.latin);
    });

    test('changer d\'écriture reconstruit le lecteur', () async {
      // **Le test qui compte.** Le reconnaisseur est gardé entre deux lectures ;
      // si le provider lisait la préférence au lieu de l'observer, le choix ne
      // prendrait effet qu'au redémarrage.
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final avant = container.read(cardTextReaderProvider);
      expect(avant.script, OcrScript.latin);

      await container
          .read(selectedOcrScriptProvider.notifier)
          .select(OcrScript.japanese);

      final apres = container.read(cardTextReaderProvider);
      expect(apres.script, OcrScript.japanese);
      expect(identical(avant, apres), isFalse);
    });
  });
}
