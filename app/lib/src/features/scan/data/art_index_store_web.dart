/// L'index d'empreintes sur le web, où il n'y a pas de fichiers.
///
/// `dart:io` n'existe pas dans un navigateur : `shared_preferences` — donc
/// `localStorage` — reste le seul stockage disponible sans dépendance
/// supplémentaire. Les reproches faits à ce support côté mobile (voir
/// `art_index_store_io.dart`) ne portent pas ici : le navigateur ne charge pas
/// tout `localStorage` en mémoire Dart au démarrage, et il n'y a pas de fichier
/// de préférences à réécrire.
///
/// **Le base64 subsiste**, parce que `localStorage` ne stocke que des chaînes.
/// C'est un tiers de volume en trop et un décodage de plus, payés sur la seule
/// plateforme qui n'a pas le choix.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Même versionnage que côté fichier : l'un et l'autre doivent devenir caducs
/// ensemble le jour où l'algorithme d'empreinte change.
const String _prefix = 'art_hash_index_dhash64_v1';

String _keyFor(String gameId) => '${_prefix}_$gameId';

Future<Uint8List?> readIndexBytes(String gameId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_keyFor(gameId));
    if (encoded == null || encoded.isEmpty) return null;
    return base64Decode(encoded);
  } on Object catch (error) {
    debugPrint('index en cache illisible : $error');
    return null;
  }
}

Future<void> writeIndexBytes(String gameId, Uint8List bytes) async {
  if (bytes.isEmpty) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFor(gameId), base64Encode(bytes));
  } on Object catch (error) {
    debugPrint('index non mis en cache : $error');
  }
}

Future<void> deleteIndexBytes(String gameId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFor(gameId));
  } on Object {
    // Rien à faire de plus.
  }
}
