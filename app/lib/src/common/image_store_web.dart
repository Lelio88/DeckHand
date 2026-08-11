/// Cache d'images sur le web : il n'y en a pas, et c'est le bon choix.
///
/// Le navigateur conserve déjà les images dans son propre cache HTTP, avec ses
/// règles de péremption et son éviction — en redoubler un dans `localStorage`
/// coûterait de la place pour ne rien gagner. `dart:io` n'existe d'ailleurs pas
/// ici : c'est cette implémentation qui est compilée par défaut, l'autre ne
/// prenant la main que si `dart:library.io` est disponible.
library;

import 'dart:typed_data';

/// Rend toujours `null` : chaque image part au réseau, où le navigateur la
/// sert depuis son cache le cas échéant.
Future<Uint8List?> readCachedImage(String url) async => null;

/// Ne conserve rien.
Future<void> writeCachedImage(String url, Uint8List bytes) async {}

/// Rien à vider.
Future<void> clearImageCache() async {}
