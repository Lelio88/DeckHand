/// L'index d'empreintes, rangé dans un fichier plutôt que dans les préférences.
///
/// **Pourquoi pas `shared_preferences`.** Il l'était, et c'était un mauvais
/// endroit pour un objet de cette taille. Mesuré le 2026-08-24 : l'index Magic
/// pèse 3 929 Kio, soit **5 239 Kio une fois encodé en base64** — et les huit
/// jeux mis en cache montent à 10,1 Mio. Or le greffon charge **toutes** les
/// clés dans la mémoire Dart au premier appel de `getInstance()`, et celui-ci a
/// lieu au démarrage pour lire le jeu courant, cinq caractères. L'application
/// tenait donc en permanence des mégaoctets de base64 dont elle ne se sert qu'à
/// l'ouverture du scan, et chaque mise à jour d'index réécrivait le fichier de
/// préférences en entier.
///
/// **Le base64 disparaît avec.** Un fichier accepte les octets tels quels : un
/// tiers de volume en moins, et 25 ms de décodage en moins par ouverture — la
/// moitié du coût mesuré.
///
/// **Où.** `Directory.systemTemp`, comme `image_store_io.dart`, et pour la même
/// raison : obtenir le répertoire « documents » demanderait `path_provider`,
/// donc un greffon natif de plus, ce que ce projet refuse depuis longtemps.
/// Le prix est assumé et il est réel : le système peut vider ce répertoire sous
/// pression de stockage, et l'index se retéléchargera alors une fois. C'est un
/// cache, pas une archive.
///
/// **Le web garde les préférences** — `dart:io` n'y existe pas. C'est ce qui
/// avait fait abandonner les fichiers la première fois ; l'export conditionnel
/// permet cette fois d'avoir les deux, chacun là où il fonctionne.
///
/// Tout échoue en silence : un cache illisible se traite comme un cache absent,
/// l'index se retéléchargera. Une exception ici rendrait le scan définitivement
/// inaccessible.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Nom du répertoire, **versionné par l'algorithme d'empreinte**. Le changer
/// fait proprement ignorer l'ancien cache au lieu de le servir en silence : une
/// empreinte calculée autrement est inexploitable, et la leçon vient de
/// l'expérience — le redimensionnement a déjà changé une fois.
const String _dirName = 'deckhand_art_index_dhash64_v1';

Directory? _dir;

Future<Directory?> _directory() async {
  final known = _dir;
  if (known != null) return known;
  try {
    final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}$_dirName',
    );
    if (!dir.existsSync()) await dir.create(recursive: true);
    return _dir = dir;
  } on Object catch (error) {
    debugPrint('cache d\'index indisponible : $error');
    return null;
  }
}

File? _file(Directory dir, String gameId) {
  // Le jeu vient d'une énumération, jamais d'une saisie — mais un identifiant
  // qui se promènerait dans un chemin mérite quand même sa ceinture.
  final safe = gameId.replaceAll(RegExp(r'[^a-z0-9_-]'), '');
  if (safe.isEmpty) return null;
  return File('${dir.path}${Platform.pathSeparator}$safe.idx');
}

/// Les octets de l'index conservé pour ce jeu, ou `null` s'il n'y en a pas.
Future<Uint8List?> readIndexBytes(String gameId) async {
  try {
    final dir = await _directory();
    if (dir == null) return null;
    final file = _file(dir, gameId);
    if (file == null || !file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  } on Object catch (error) {
    debugPrint('index en cache illisible : $error');
    return null;
  }
}

/// Conserve [bytes] pour ce jeu. Sans effet en cas d'échec.
Future<void> writeIndexBytes(String gameId, Uint8List bytes) async {
  if (bytes.isEmpty) return;
  try {
    final dir = await _directory();
    if (dir == null) return;
    final file = _file(dir, gameId);
    if (file == null) return;
    await file.writeAsBytes(bytes, flush: false);
  } on Object catch (error) {
    debugPrint('index non mis en cache : $error');
  }
}

Future<void> deleteIndexBytes(String gameId) async {
  try {
    final dir = await _directory();
    if (dir == null) return;
    final file = _file(dir, gameId);
    if (file != null && file.existsSync()) await file.delete();
  } on Object {
    // Rien à faire de plus : le fichier sera écrasé au prochain enregistrement.
  }
}
