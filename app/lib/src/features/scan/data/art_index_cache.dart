/// Conservation locale de l'index d'empreintes.
///
/// Sans cache, l'application retélécharge près d'un mégaoctet à chaque
/// démarrage — une trentaine de secondes avant de pouvoir scanner, ce qui vide
/// de son sens l'argument de la reconnaissance embarquée.
///
/// **Fraîcheur et hors ligne se contredisent**, et l'arbitrage est explicite :
/// le cache est **toujours** servi s'il existe, et sa péremption est vérifiée
/// séparément, quand le réseau répond (voir `artHashIndexProvider`). Un index
/// légèrement daté reconnaît parfaitement les cartes anciennes ; refuser de
/// scanner faute de réseau serait une régression bien pire que d'ignorer la
/// dernière extension.
///
/// **Un seul mécanisme pour toutes les plateformes.** `shared_preferences`
/// s'appuie sur `localStorage` en web et sur le stockage natif ailleurs, ce qui
/// évite d'entretenir deux implémentations. Une version antérieure écrivait un
/// fichier via `path_provider`, absent du web : le scan depuis un navigateur
/// mobile — cas parfaitement réel, la caméra y est accessible — retéléchargeait
/// alors l'index à chaque visite.
///
/// L'index est encodé en base64 : cela gonfle d'un tiers, mais la donnée n'est
/// lue qu'une fois au démarrage et le surcoût reste sans conséquence face à un
/// téléchargement complet.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../config/selected_game.dart';
import '../domain/art_hash_index.dart';

/// Index conservé localement, avec le nombre d'entrées qu'il contenait.
typedef CachedIndex = ({ArtHashIndex index, int count});

/// Préfixe des clés de stockage, **versionné par l'algorithme d'empreinte**.
///
/// Une empreinte calculée avec un autre algorithme est inexploitable. La leçon
/// vient de l'expérience : le redimensionnement a déjà changé une fois, rendant
/// caduques onze mille empreintes. Incrémenter ce suffixe fait proprement
/// ignorer l'ancien cache au lieu de le servir silencieusement.
const _cachePrefix = 'art_hash_index_dhash64_v1';

/// Clé de l'unique index d'avant le cloisonnement par jeu.
///
/// **Elle est purgée, jamais relue.** Elle contient les deux catalogues mêlés,
/// donc une donnée fausse pour l'un comme pour l'autre : servir ce blob en
/// Riftbound proposerait des cartes Magic, et le garder en Magic laisserait
/// dormir 1,6 Mo de base64 sur l'appareil.
const _legacyKey = _cachePrefix;

/// Une clé par jeu : basculer de catalogue ne doit pas écraser l'autre index,
/// sinon chaque aller-retour coûterait un téléchargement complet.
String _keyFor(Game game) => '${_cachePrefix}_${game.id}';

class ArtIndexCache {
  const ArtIndexCache();

  /// Relit l'index conservé pour ce jeu, ou `null` s'il est absent ou illisible.
  ///
  /// Un cache corrompu est traité comme un cache absent : le supprimer et
  /// retélécharger coûte quelques secondes, alors qu'une exception au démarrage
  /// rendrait le scan définitivement inaccessible.
  Future<CachedIndex?> read(Game game) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _dropLegacy(prefs);

      final encoded = prefs.getString(_keyFor(game));
      if (encoded == null || encoded.isEmpty) return null;

      final index = ArtHashIndex.fromBytes(base64Decode(encoded));
      return (index: index, count: index.length);
    } on Object catch (error) {
      debugPrint('cache d\'empreintes illisible, purge : $error');
      await clear(game);
      return null;
    }
  }

  Future<void> write(Game game, ArtHashIndex index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyFor(game), base64Encode(index.toBytes()));
    } on Object catch (error) {
      // Un cache qu'on n'arrive pas à écrire n'empêche pas de fonctionner :
      // l'index reste en mémoire pour la durée de la session.
      debugPrint('cache d\'empreintes non enregistré : $error');
    }
  }

  Future<void> clear(Game game) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyFor(game));
    } on Object {
      // Rien à faire de plus : le cache sera écrasé au prochain enregistrement.
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
