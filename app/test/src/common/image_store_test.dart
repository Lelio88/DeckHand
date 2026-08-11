/// Ce que le cache d'images doit garantir.
///
/// **Un seul défaut est inacceptable ici : servir la mauvaise carte.** Le nom
/// de fichier est un condensé 64 bits de l'URL, donc sujet aux collisions ; la
/// parade est l'URL réécrite en tête du fichier et vérifiée à la lecture. Sans
/// elle, deux cartes malchanceuses échangeraient leurs illustrations en
/// silence, et le défaut se lirait comme une erreur de saisie de
/// l'utilisateur.
///
/// Tout le reste — disque plein, fichier tronqué, répertoire absent — doit
/// dégrader vers « pas de cache », jamais vers une exception : une image est un
/// ornement et ne doit pas pouvoir faire tomber l'écran qui la porte.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deckhand/src/common/image_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Une URL de carte telle que le catalogue les porte.
const _url =
    'https://cards.scryfall.io/normal/front/e/0/e040b456.jpg?1783902897';
const _autre =
    'https://cards.scryfall.io/normal/front/a/1/a1b2c3d4.jpg?1783902897';

Uint8List _bytes(String contenu) => Uint8List.fromList(utf8.encode(contenu));

/// Le fichier qu'une URL occupe, retrouvé par balayage : le condensé est privé
/// au module, et c'est très bien — le test ne doit pas en dépendre.
File? _fileHolding(String contenu) {
  final dir = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'deckhand_card_images_v1',
  );
  if (!dir.existsSync()) return null;
  for (final file in dir.listSync().whereType<File>()) {
    if (utf8
        .decode(file.readAsBytesSync(), allowMalformed: true)
        .contains(contenu)) {
      return file;
    }
  }
  return null;
}

void main() {
  setUp(clearImageCache);
  tearDown(clearImageCache);

  test('une image conservée se relit à l\'identique', () async {
    await writeCachedImage(_url, _bytes('les octets de la carte'));

    expect(await readCachedImage(_url), _bytes('les octets de la carte'));
  });

  test('une URL jamais vue ne rend rien', () async {
    expect(await readCachedImage(_url), isNull);
  });

  test('deux URL distinctes ne se mélangent pas', () async {
    await writeCachedImage(_url, _bytes('première'));
    await writeCachedImage(_autre, _bytes('seconde'));

    expect(await readCachedImage(_url), _bytes('première'));
    expect(await readCachedImage(_autre), _bytes('seconde'));
  });

  test('un fichier écrit pour une autre URL n\'est jamais servi', () async {
    // Simule exactement ce qu'une collision de condensé produirait : le
    // fichier existe, il est bien formé, mais il décrit une autre carte.
    // L'en-tête doit le faire rejeter.
    await writeCachedImage(_autre, _bytes('la carte du voisin'));
    final file = _fileHolding('la carte du voisin');
    expect(file, isNotNull, reason: 'le cache doit avoir écrit un fichier');

    // On renomme le fichier sous le condensé qu'aurait _url : impossible à
    // deviner sans le condensé, donc on l'obtient par l'écriture puis on
    // recopie le contenu sous ce nom.
    await writeCachedImage(_url, _bytes('la bonne carte'));
    final sien = _fileHolding('la bonne carte')!;
    sien.writeAsBytesSync(file!.readAsBytesSync());

    expect(
      await readCachedImage(_url),
      isNull,
      reason:
          'servir la carte d\'une autre URL est le seul défaut '
          'inacceptable d\'un cache d\'images',
    );
  });

  test('un fichier tronqué est traité comme absent', () async {
    await writeCachedImage(_url, _bytes('la bonne carte'));
    _fileHolding('la bonne carte')!.writeAsBytesSync([1, 2]);

    expect(await readCachedImage(_url), isNull);
  });

  test('une image vide n\'est pas conservée', () async {
    await writeCachedImage(_url, Uint8List(0));

    expect(await readCachedImage(_url), isNull);
  });
}
