/// Conservation locale de l'index d'empreintes.
///
/// Sans cache, l'application retélécharge six mégaoctets à chaque démarrage —
/// mesuré, 9,4 s sur une liaison filaire — ce qui viderait de son sens
/// l'argument de la reconnaissance embarquée.
///
/// **Fraîcheur et hors ligne se contredisent**, et l'arbitrage est explicite :
/// le cache est **toujours** servi s'il existe, et sa péremption est vérifiée
/// séparément, quand le réseau répond (voir `artHashIndexProvider`). Un index
/// légèrement daté reconnaît parfaitement les cartes anciennes ; refuser de
/// scanner faute de réseau serait une régression bien pire que d'ignorer la
/// dernière extension.
///
/// **Le support dépend de la plateforme**, et c'est `art_index_store.dart` qui
/// tranche : un fichier là où `dart:io` existe, `localStorage` sur le web. La
/// raison tient en un chiffre — l'index Magic pèse 5 239 Kio en base64, et
/// `shared_preferences` charge toutes ses clés en mémoire Dart dès le premier
/// accès, qui a lieu au démarrage pour lire le jeu courant.
///
/// **Le décodage ne se fait pas sur l'isolat principal.** Reconstruire l'index
/// depuis ses octets coûte 22 ms sur un poste, donc trois à cinq fois plus sur
/// un téléphone : autant de gel de l'interface au moment précis où l'écran de
/// scan s'ouvre. `compute` l'éloigne.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/selected_game.dart';
import '../domain/art_hash_index.dart';
import 'art_index_store.dart';

/// Index conservé localement, avec le nombre d'entrées qu'il contenait.
typedef CachedIndex = ({ArtHashIndex index, int count});

/// Clés de l'ancien rangement dans les préférences.
///
/// **Elles sont reprises une fois, puis effacées.** Retélécharger six
/// mégaoctets pour cause de déménagement serait une punition gratuite : les
/// octets sont déjà là, il suffit de les recopier au bon endroit. Une fois
/// recopiés, la clé part — c'est tout l'objet de l'opération que de ne plus
/// avoir cela dans les préférences.
const String _oldPrefix = 'art_hash_index_dhash64_v1';

/// Clé de l'unique index d'avant le cloisonnement par jeu.
///
/// **Elle est purgée, jamais relue.** Elle contient plusieurs catalogues mêlés,
/// donc une donnée fausse pour chacun : servir ce blob en Riftbound proposerait
/// des cartes Magic.
const String _legacyKey = _oldPrefix;

String _oldKeyFor(Game game) => '${_oldPrefix}_${game.id}';

/// Reconstruit l'index depuis ses octets. Hors de l'isolat principal.
///
/// Fonction de premier niveau : `compute` ne sait pas transporter une fermeture.
ArtHashIndex _decode(Uint8List bytes) => ArtHashIndex.fromBytes(bytes);

class ArtIndexCache {
  const ArtIndexCache();

  /// Relit l'index conservé pour ce jeu, ou `null` s'il est absent ou illisible.
  ///
  /// Un cache corrompu est traité comme un cache absent : le supprimer et
  /// retélécharger coûte quelques secondes, alors qu'une exception au démarrage
  /// rendrait le scan définitivement inaccessible.
  Future<CachedIndex?> read(Game game) async {
    try {
      var bytes = await readIndexBytes(game.id);
      bytes ??= await _adoptFromPreferences(game);
      if (bytes == null || bytes.isEmpty) return null;

      final index = await compute(_decode, bytes);
      return (index: index, count: index.length);
    } on Object catch (error) {
      debugPrint('cache d\'empreintes illisible, purge : $error');
      await clear(game);
      return null;
    }
  }

  Future<void> write(Game game, ArtHashIndex index) async {
    // Un cache qu'on n'arrive pas à écrire n'empêche pas de fonctionner :
    // l'index reste en mémoire pour la durée de la session. Le magasin avale
    // déjà ses propres erreurs.
    await writeIndexBytes(game.id, index.toBytes());
  }

  Future<void> clear(Game game) => deleteIndexBytes(game.id);

  /// Récupère l'index de l'ancien rangement, puis libère les préférences.
  ///
  /// Rend les octets repris, ou `null` s'il n'y avait rien. L'écriture au
  /// nouvel emplacement a lieu ici : sans elle, la reprise recommencerait à
  /// chaque ouverture, base64 compris.
  Future<Uint8List?> _adoptFromPreferences(Game game) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _dropLegacy(prefs);

      final key = _oldKeyFor(game);
      final encoded = prefs.getString(key);
      if (encoded == null || encoded.isEmpty) return null;

      final bytes = base64Decode(encoded);
      await writeIndexBytes(game.id, bytes);
      await prefs.remove(key);
      return bytes;
    } on Object catch (error) {
      debugPrint('ancien cache d\'empreintes ignoré : $error');
      return null;
    }
  }

  /// Efface l'index d'avant le cloisonnement, une fois pour toutes.
  Future<void> _dropLegacy(SharedPreferences prefs) async {
    if (!prefs.containsKey(_legacyKey)) return;
    await prefs.remove(_legacyKey);
  }
}

final artIndexCacheProvider = Provider<ArtIndexCache>(
  (ref) => const ArtIndexCache(),
);
