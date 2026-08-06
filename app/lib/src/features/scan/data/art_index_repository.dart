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

/// Index chargé en mémoire.
///
/// `keepAlive` implicite : le provider n'est pas `autoDispose`, l'index survit
/// donc à la fermeture de l'écran de scan. Le retélécharger à chaque ouverture
/// serait absurde pour une donnée qui ne change qu'au rythme des sorties
/// d'extensions.
final artHashIndexProvider = FutureProvider<ArtHashIndex>((ref) {
  return ref.watch(artIndexRepositoryProvider).download();
});
