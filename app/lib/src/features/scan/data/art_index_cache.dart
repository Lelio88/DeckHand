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

import '../domain/art_hash_index.dart';

/// Index conservé localement, avec le nombre d'entrées qu'il contenait.
typedef CachedIndex = ({ArtHashIndex index, int count});

/// Clé de stockage, **versionnée par l'algorithme d'empreinte**.
///
/// Une empreinte calculée avec un autre algorithme est inexploitable. La leçon
/// vient de l'expérience : le redimensionnement a déjà changé une fois, rendant
/// caduques onze mille empreintes. Incrémenter ce suffixe fait proprement
/// ignorer l'ancien cache au lieu de le servir silencieusement.
const _cacheKey = 'art_hash_index_dhash64_v1';

class ArtIndexCache {
  const ArtIndexCache();

  /// Relit l'index conservé, ou `null` s'il est absent ou illisible.
  ///
  /// Un cache corrompu est traité comme un cache absent : le supprimer et
  /// retélécharger coûte quelques secondes, alors qu'une exception au démarrage
  /// rendrait le scan définitivement inaccessible.
  Future<CachedIndex?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(_cacheKey);
      if (encoded == null || encoded.isEmpty) return null;

      final index = ArtHashIndex.fromBytes(base64Decode(encoded));
      return (index: index, count: index.length);
    } on Object catch (error) {
      debugPrint('cache d\'empreintes illisible, purge : $error');
      await clear();
      return null;
    }
  }

  Future<void> write(ArtHashIndex index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, base64Encode(index.toBytes()));
    } on Object catch (error) {
      // Un cache qu'on n'arrive pas à écrire n'empêche pas de fonctionner :
      // l'index reste en mémoire pour la durée de la session.
      debugPrint('cache d\'empreintes non enregistré : $error');
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } on Object {
      // Rien à faire de plus : le cache sera écrasé au prochain enregistrement.
    }
  }
}

final artIndexCacheProvider = Provider<ArtIndexCache>(
  (ref) => const ArtIndexCache(),
);
