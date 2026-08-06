/// Conservation locale de l'index d'empreintes.
///
/// Sans cache, l'application retélécharge près d'un mégaoctet à chaque
/// démarrage — une trentaine de secondes avant de pouvoir scanner, ce qui vide
/// de son sens l'argument de la reconnaissance embarquée.
///
/// **Fraîcheur et hors ligne se contredisent**, et l'arbitrage est explicite :
/// le cache est **toujours** servi s'il existe, et sa péremption est vérifiée
/// séparément, quand le réseau répond. Un index légèrement daté reconnaît
/// parfaitement les cartes anciennes ; refuser de scanner faute de réseau serait
/// une régression bien pire que d'ignorer la dernière extension.
///
/// La péremption se mesure au **nombre d'entrées** côté serveur : l'index ne
/// grossit qu'aux sorties d'extensions, et une simple comparaison de compte
/// suffit à détecter qu'il a bougé, pour le prix d'une requête triviale.
///
/// **Le web n'a pas de cache.** `path_provider` n'y est pas implémenté, et le
/// scan y est de toute façon marginal — la caméra d'un navigateur de bureau ne
/// photographie pas des cartes. Plutôt que d'introduire un second mécanisme de
/// stockage pour une plateforme secondaire, l'absence de cache y est assumée et
/// signalée par `isSupported`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/art_hash_index.dart';

/// Index conservé localement, avec le nombre d'entrées qu'il contenait.
typedef CachedIndex = ({ArtHashIndex index, int count});

class ArtIndexCache {
  const ArtIndexCache();

  static const _fileName = 'art_hash_index.bin';

  /// Faux sur les plateformes dépourvues de système de fichiers.
  bool get isSupported => !kIsWeb;

  Future<File?> _file() async {
    if (!isSupported) return null;
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/$_fileName');
  }

  /// Relit l'index conservé, ou `null` s'il est absent ou illisible.
  ///
  /// Un cache corrompu est traité comme un cache absent : le supprimer et
  /// retélécharger coûte quelques secondes, alors qu'une exception au démarrage
  /// rendrait le scan définitivement inaccessible.
  Future<CachedIndex?> read() async {
    try {
      final file = await _file();
      if (file == null || !file.existsSync()) return null;

      final index = ArtHashIndex.fromBytes(await file.readAsBytes());
      return (index: index, count: index.length);
    } on Object {
      await clear();
      return null;
    }
  }

  Future<void> write(ArtHashIndex index) async {
    try {
      final file = await _file();
      if (file == null) return;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(Uint8List.fromList(index.toBytes()), flush: true);
    } on Object {
      // Un cache qu'on n'arrive pas à écrire n'empêche pas de fonctionner :
      // l'index reste en mémoire pour la session.
    }
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (file != null && file.existsSync()) await file.delete();
    } on Object {
      // Rien à faire de plus : le cache sera écrasé au prochain enregistrement.
    }
  }
}

final artIndexCacheProvider = Provider<ArtIndexCache>(
  (ref) => const ArtIndexCache(),
);
