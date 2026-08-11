/// Cache d'images sur disque, sans aucune dépendance ajoutée.
///
/// **Où.** `Directory.systemTemp`, que l'embarqueur Flutter fait pointer sur le
/// répertoire de cache privé de l'application (`getCacheDir()` sur Android,
/// `NSTemporaryDirectory()` sur iOS). Le système peut le vider sous pression de
/// stockage : c'est la sémantique d'un cache, pas une faiblesse. Obtenir le
/// répertoire « documents » à la place exigerait `path_provider`, donc deux
/// greffons natifs de plus — l'inverse du but poursuivi.
///
/// **Sous quel nom.** Un condensé FNV-1a 64 bits de l'URL, en hexadécimal :
/// seize caractères, là où l'URL elle-même en fait cent trente et frôlerait la
/// limite de chemin de Windows. Un condensé peut entrer en collision ; **l'URL
/// est donc réécrite en tête du fichier et vérifiée à la lecture**. Une
/// collision produit alors un défaut de cache, jamais la mauvaise carte — c'est
/// la seule erreur qu'un cache d'images n'a pas le droit de commettre.
///
/// Format d'un fichier : `[4 octets : longueur de l'URL][URL en UTF-8][image]`.
///
/// **Éviction.** Le répertoire est plafonné à [_maxBytes] ; au-delà, les
/// fichiers les moins récemment modifiés partent en premier. Le balayage ne
/// tourne qu'une écriture sur [_sweepEvery] : parcourir le répertoire à chaque
/// image coûterait plus cher que le téléchargement évité.
///
/// **Tout échoue en silence.** Disque plein, répertoire interdit, fichier
/// tronqué : on rend `null` et l'appelant télécharge. Une image est un
/// ornement ; elle ne doit pas pouvoir faire tomber l'écran qui la porte.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Plafond du répertoire. Une carte pèse ~95 Ko en taille `normal` : 60 Mo
/// tiennent environ six cents cartes, soit largement les classeurs qu'on
/// consulte réellement.
const int _maxBytes = 60 * 1024 * 1024;

/// Une écriture sur cinquante déclenche le balayage d'éviction.
const int _sweepEvery = 50;

/// Nom du répertoire, **versionné par le format de fichier**. Le changer fait
/// proprement ignorer l'ancien cache plutôt que de lire des en-têtes d'un autre
/// format — la leçon vient de `art_index_cache.dart`.
const String _dirName = 'deckhand_card_images_v1';

int _writesSinceSweep = 0;
Directory? _dir;

/// Condensé FNV-1a 64 bits, en hexadécimal.
///
/// Choisi pour être court, stable d'une exécution à l'autre et calculable sans
/// paquet de cryptographie — `dart:convert` n'offre aucun condensé. Sa qualité
/// importe peu : l'URL réécrite dans le fichier tranche les collisions.
String _digest(String url) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(url)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

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
    debugPrint('cache d\'images indisponible : $error');
    return null;
  }
}

/// Relit l'image conservée pour [url], ou `null` s'il n'y en a pas.
Future<Uint8List?> readCachedImage(String url) async {
  try {
    final dir = await _directory();
    if (dir == null) return null;

    final file = File('${dir.path}${Platform.pathSeparator}${_digest(url)}');
    if (!file.existsSync()) return null;

    final bytes = await file.readAsBytes();
    if (bytes.length < 4) return null;

    final urlLength = ByteData.sublistView(bytes, 0, 4).getUint32(0);
    if (urlLength == 0 || 4 + urlLength > bytes.length) return null;

    // La vérification qui rend le condensé sûr : ce fichier décrit-il bien
    // l'image qu'on demande ?
    final stored = utf8.decode(
      bytes.sublist(4, 4 + urlLength),
      allowMalformed: true,
    );
    if (stored != url) return null;

    final image = Uint8List.sublistView(bytes, 4 + urlLength);
    // Toucher la date de dernier accès : l'éviction retire les plus anciennes,
    // et une carte qu'on regarde tous les jours ne doit pas en faire partie.
    unawaited(file.setLastModified(DateTime.now()));
    return image.isEmpty ? null : image;
  } on Object catch (error) {
    debugPrint('image en cache illisible : $error');
    return null;
  }
}

/// Conserve [bytes] pour [url]. Sans effet en cas d'échec.
Future<void> writeCachedImage(String url, Uint8List bytes) async {
  if (bytes.isEmpty) return;
  try {
    final dir = await _directory();
    if (dir == null) return;

    final urlBytes = utf8.encode(url);
    final header = ByteData(4)..setUint32(0, urlBytes.length);
    final file = File('${dir.path}${Platform.pathSeparator}${_digest(url)}');

    await file.writeAsBytes([
      ...header.buffer.asUint8List(),
      ...urlBytes,
      ...bytes,
    ], flush: false);

    if (++_writesSinceSweep >= _sweepEvery) {
      _writesSinceSweep = 0;
      unawaited(_sweep(dir));
    }
  } on Object catch (error) {
    debugPrint('image non mise en cache : $error');
  }
}

/// Ramène le répertoire sous [_maxBytes] en retirant les fichiers les moins
/// récemment touchés.
Future<void> _sweep(Directory dir) async {
  try {
    final files = dir.listSync().whereType<File>().toList();
    final stats = <(File, FileStat)>[
      for (final file in files) (file, file.statSync()),
    ];
    var total = stats.fold<int>(0, (sum, entry) => sum + entry.$2.size);
    if (total <= _maxBytes) return;

    stats.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in stats) {
      if (total <= _maxBytes) return;
      try {
        file.deleteSync();
        total -= stat.size;
      } on Object {
        // Un fichier verrouillé n'empêche pas d'évincer les suivants.
      }
    }
  } on Object catch (error) {
    debugPrint('éviction du cache d\'images impossible : $error');
  }
}

/// Vide le cache. Utilisé par les tests, et disponible pour un futur réglage.
Future<void> clearImageCache() async {
  try {
    final dir = await _directory();
    if (dir != null && dir.existsSync()) await dir.delete(recursive: true);
    _dir = null;
    _writesSinceSweep = 0;
  } on Object catch (error) {
    debugPrint('cache d\'images non vidé : $error');
  }
}
