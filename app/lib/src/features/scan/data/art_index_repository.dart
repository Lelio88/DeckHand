/// Récupération de l'index d'empreintes depuis le serveur.
///
/// L'index est téléchargé page par page puis conservé en mémoire. À l'échelle du
/// catalogue — quelques dizaines de milliers d'entrées, soit moins d'un
/// mégaoctet — le garder entièrement chargé est plus simple et plus rapide que
/// d'interroger le réseau à chaque reconnaissance, laquelle doit rester
/// instantanée et fonctionner hors ligne.
///
/// **L'empreinte transite en hexadécimal**, jamais en nombre : sur Flutter web,
/// `int` est un double IEEE-754 et perdrait des bits au-delà de 2^53,
/// silencieusement. La fonction serveur `art_hash_page` renvoie donc une chaîne.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/art_hash.dart';
import '../domain/art_hash_index.dart';
import 'art_index_cache.dart';

/// Taille de page. Un compromis : assez grande pour limiter le nombre
/// d'allers-retours, assez petite pour que la progression reste lisible et
/// qu'une réponse tienne confortablement en mémoire.
const int indexPageSize = 2000;

class ArtIndexRepository {
  const ArtIndexRepository(this._client);

  final SupabaseClient _client;

  /// Nombre d'empreintes disponibles côté serveur.
  Future<int> count() async {
    final value = await _client.rpc<int>('art_hash_count');
    return value;
  }

  /// Télécharge l'index complet.
  ///
  /// [onProgress] est appelé après chaque page avec le nombre d'entrées reçues
  /// et le total attendu — un index de plusieurs dizaines de milliers d'entrées
  /// met plusieurs secondes à arriver, l'utilisateur doit le voir.
  Future<ArtHashIndex> download({
    void Function(int received, int total)? onProgress,
  }) async {
    final total = await count();
    final entries = <IndexEntry>[];

    var offset = 0;
    while (offset < total) {
      final rows = await _client.rpc<List<dynamic>>(
        'art_hash_page',
        params: {'p_offset': offset, 'p_limit': indexPageSize},
      );
      if (rows.isEmpty) break;

      for (final row in rows.cast<Map<String, dynamic>>()) {
        entries.add((
          oracleId: row['oracle_id'] as String,
          hash: ArtHash.fromHex(row['hash_hex'] as String),
        ));
      }

      offset += rows.length;
      onProgress?.call(entries.length, total);
    }

    return ArtHashIndex.fromEntries(entries);
  }
}

final artIndexRepositoryProvider = Provider<ArtIndexRepository>(
  (ref) => ArtIndexRepository(Supabase.instance.client),
);

/// Index chargé en mémoire, servi depuis le cache quand il est à jour.
///
/// L'ordre des opérations porte tout l'arbitrage entre fraîcheur et
/// disponibilité :
///
/// 1. le cache local est lu en premier — s'il existe, il est utilisable
///    immédiatement, même sans réseau ;
/// 2. le nombre d'entrées côté serveur est demandé ; en cas d'échec, le cache
///    est servi tel quel plutôt que d'empêcher le scan ;
/// 3. il n'est retéléchargé que si le serveur en annonce davantage.
///
/// `keepAlive` implicite : le provider n'est pas `autoDispose`, l'index survit
/// donc à la fermeture de l'écran de scan.
final artHashIndexProvider = FutureProvider<ArtHashIndex>((ref) async {
  final repository = ref.watch(artIndexRepositoryProvider);
  final cache = ref.watch(artIndexCacheProvider);

  final cached = await cache.read();

  if (cached != null) {
    int? serverCount;
    try {
      serverCount = await repository.count();
    } on Object {
      // Hors ligne : le cache fait foi. Un index d'hier vaut infiniment mieux
      // qu'un écran de scan inutilisable.
      return cached.index;
    }
    if (serverCount <= cached.count) return cached.index;
  }

  final downloaded = await repository.download();
  await cache.write(downloaded);
  return downloaded;
});
