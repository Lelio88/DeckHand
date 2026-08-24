/// Où l'index est rangé, et comment il y a déménagé.
///
/// **Ce que ces tests protègent : un téléchargement de six mégaoctets.** L'index
/// vivait dans `shared_preferences`, encodé en base64 — 5 239 Kio pour Magic,
/// chargés en mémoire Dart au premier accès aux préférences, qui a lieu au
/// démarrage pour lire le jeu courant. Il vit désormais dans un fichier. Une
/// reprise ratée ne casserait rien de visible : l'index se retéléchargerait, et
/// personne ne saurait pourquoi le premier scan met dix secondes.
///
/// Le second point est le **découpage en lots**. Les pages partent désormais par
/// quatre ; une erreur d'un rang y perdrait mille empreintes sans que rien ne le
/// signale, l'index restant fonctionnel pour toutes les autres cartes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/scan/data/art_index_cache.dart';
import 'package:deckhand/src/features/scan/data/art_index_repository.dart';
import 'package:deckhand/src/features/scan/data/art_index_store.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ArtHashIndex indexOf(List<String> ids) => ArtHashIndex.fromEntries([
  for (final id in ids)
    (oracleId: id, printId: id, hash: ArtHash.fromHex('0000000000000000')),
]);

/// La clé qu'utilisait l'ancien rangement.
String ancienneClef(Game game) => 'art_hash_index_dhash64_v1_${game.id}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cache = ArtIndexCache();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Les fichiers survivent d'un test à l'autre : sans cela, un index écrit
    // par le test précédent ferait passer une reprise qui n'a pas eu lieu.
    for (final game in Game.values) {
      await cache.clear(game);
    }
  });

  group('le rangement', () {
    test('un index écrit se relit à l’identique', () async {
      await cache.write(Game.magic, indexOf(['bolt', 'ring', 'island']));

      final relu = await cache.read(Game.magic);

      expect(relu?.count, 3);
      expect(
        relu?.index.search(ArtHash.fromHex('0000000000000000')).best?.oracleId,
        isNotNull,
      );
    });

    test('rien à relire quand rien n’a été écrit', () async {
      expect(await cache.read(Game.pokemon), isNull);
    });

    test('un jeu ne lit pas l’index d’un autre', () async {
      // 379 empreintes Riftbound tombent sous le seuil de confiance d'une
      // empreinte Magic : servir le mauvais index répondrait une carte de
      // l'autre jeu, ce qui est pire qu'un index vide.
      await cache.write(Game.magic, indexOf(['bolt', 'ring']));

      expect(await cache.read(Game.riftbound), isNull);
    });

    test('effacer un index n’efface que celui-là', () async {
      await cache.write(Game.magic, indexOf(['bolt']));
      await cache.write(Game.pokemon, indexOf(['pikachu', 'salameche']));

      await cache.clear(Game.magic);

      expect(await cache.read(Game.magic), isNull);
      expect((await cache.read(Game.pokemon))?.count, 2);
    });
  });

  group('la reprise de l’ancien rangement', () {
    test('un index laissé dans les préférences est adopté, pas retéléchargé',
        () async {
      final ancien = indexOf(['bolt', 'ring', 'island']);
      SharedPreferences.setMockInitialValues({
        ancienneClef(Game.magic): base64Encode(ancien.toBytes()),
      });

      final relu = await cache.read(Game.magic);

      expect(relu?.count, 3);
    });

    test('et la clé disparaît des préférences', () async {
      SharedPreferences.setMockInitialValues({
        ancienneClef(Game.magic): base64Encode(indexOf(['bolt']).toBytes()),
      });

      await cache.read(Game.magic);
      final prefs = await SharedPreferences.getInstance();

      // C'est tout l'objet du déménagement : ne plus avoir des mégaoctets de
      // base64 chargés au démarrage pour lire le jeu courant.
      expect(prefs.containsKey(ancienneClef(Game.magic)), isFalse);
    });

    test('la reprise n’a lieu qu’une fois', () async {
      SharedPreferences.setMockInitialValues({
        ancienneClef(Game.magic): base64Encode(indexOf(['bolt']).toBytes()),
      });

      await cache.read(Game.magic);
      // La seconde lecture doit trouver le fichier, les préférences étant
      // désormais vides : sans l'écriture faite pendant la reprise, elle
      // rendrait `null` et déclencherait un téléchargement.
      final seconde = await cache.read(Game.magic);

      expect(seconde?.count, 1);
    });

    test('un ancien index illisible ne bloque pas le scan', () async {
      SharedPreferences.setMockInitialValues({
        ancienneClef(Game.magic): 'ceci n_est pas du base64 !!!',
      });

      // Un cache corrompu se traite comme un cache absent : retélécharger coûte
      // quelques secondes, une exception rendrait le scan inaccessible.
      expect(await cache.read(Game.magic), isNull);
    });
  });

  group('le magasin brut', () {
    test('des octets écrits se relisent tels quels', () async {
      final bytes = indexOf(['bolt', 'ring']).toBytes();

      await writeIndexBytes('magic', bytes);

      expect(await readIndexBytes('magic'), bytes);
      await deleteIndexBytes('magic');
    });

    test('rien n’est écrit pour un contenu vide', () async {
      await writeIndexBytes('magic', Uint8List(0));

      expect(await readIndexBytes('magic'), isNull);
    });
  });

  group('le découpage en lots', () {
    test('rien à demander pour un index vide', () {
      expect(indexBatches(0), isEmpty);
      expect(indexBatches(-1), isEmpty);
    });

    test('un index plus petit qu’une page tient en un lot d’une page', () {
      expect(indexBatches(42), [
        [0],
      ]);
    });

    test('les pages partent par quatre', () {
      expect(indexBatches(4 * indexPageSize), [
        [0, indexPageSize, 2 * indexPageSize, 3 * indexPageSize],
      ]);
    });

    test('le dernier lot est incomplet sans être perdu', () {
      final lots = indexBatches(5 * indexPageSize);

      expect(lots.length, 2);
      expect(lots.last, [4 * indexPageSize]);
    });

    test('aucune empreinte n’est laissée de côté', () {
      // Le cas réel : 49 067 empreintes Magic. Une erreur d'un rang perdrait
      // ici mille cartes en silence.
      const total = 49067;
      final offsets = [for (final lot in indexBatches(total)) ...lot];

      expect(offsets.first, 0);
      expect(offsets.length, (total / indexPageSize).ceil());
      expect(offsets.last + indexPageSize, greaterThanOrEqualTo(total));
      // Strictement croissants, sans trou ni doublon : l'index doit être
      // reproductible d'un téléchargement à l'autre.
      for (var i = 1; i < offsets.length; i++) {
        expect(offsets[i] - offsets[i - 1], indexPageSize);
      }
    });
  });
}
