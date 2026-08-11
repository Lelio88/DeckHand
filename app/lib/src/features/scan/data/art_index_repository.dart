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

import '../../../config/request_timeout.dart';
import '../domain/art_hash.dart';
import '../domain/art_hash_index.dart';
import 'art_index_cache.dart';

/// Taille de page.
///
/// **Mille, parce que c'est ce que PostgREST rend.** La fonction SQL accepte
/// jusqu'à 5 000 lignes, et cette constante en demandait 2 000 — mais l'API REST
/// plafonne ses réponses à 1 000 (`db-max-rows`). La boucle avançait donc de
/// moitié moins que ce qu'elle croyait : 51 allers-retours pour 50 209
/// empreintes, au lieu des 26 attendus. Demander ce qu'on obtient réellement ne
/// change pas le nombre de pages, mais cesse de rendre le calcul mensonger.
const int indexPageSize = 1000;

/// Délai au-delà duquel une page d'index est tenue pour perdue.
///
/// Le pourquoi est écrit une fois pour toutes dans [requestTimeout] ; ce qui
/// est propre à l'index, c'est la mesure : depuis un poste filaire, l'index
/// complet arrive en 6,6 s, soit environ 130 ms par page. Quinze secondes
/// laissent donc une marge de cent fois sur une page.
const Duration indexPageTimeout = Duration(seconds: 15);

class ArtIndexRepository {
  const ArtIndexRepository(this._client);

  final SupabaseClient _client;

  /// Nombre d'empreintes disponibles côté serveur.
  Future<int> count() async {
    final value = await _client
        .rpc<int>('art_hash_count')
        .timedOut(indexPageTimeout);
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
      final rows = await _client
          .rpc<List<dynamic>>(
            'art_hash_page',
            params: {'p_offset': offset, 'p_limit': indexPageSize},
          )
          .timedOut(indexPageTimeout);
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

/// Où en est le téléchargement de l'index.
typedef IndexProgress = ({int received, int total});

/// Avancement du téléchargement, ou `null` tant qu'aucun n'est en cours.
///
/// **Un indicateur qui tourne sans chiffre ne dit pas s'il avance.** L'index
/// demande une cinquantaine d'allers-retours ; sur un réseau lent, l'attente se
/// compte en minutes et rien ne la distinguait d'un blocage. Le dépôt savait
/// pourtant compter — `download` expose `onProgress` depuis toujours — mais
/// personne n'écoutait.
class ArtIndexProgress extends Notifier<IndexProgress?> {
  @override
  IndexProgress? build() => null;

  void report(int received, int total) =>
      state = (received: received, total: total);

  /// Remise à zéro en fin de téléchargement, abouti ou non : un avancement figé
  /// à mi-course survivrait à l'écran et mentirait au chargement suivant.
  void clear() => state = null;
}

final artIndexProgressProvider =
    NotifierProvider<ArtIndexProgress, IndexProgress?>(ArtIndexProgress.new);

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
/// **Un téléchargement qui échoue ne doit pas emporter le cache avec lui.** Le
/// repli n'existait que pour l'appel de comptage : passé ce point, une page
/// perdue en cours de route levait, et l'écran affichait « index indisponible »
/// alors qu'un index parfaitement utilisable dormait sur l'appareil. Un index
/// d'hier vaut infiniment mieux qu'un scan impossible — c'est vrai à toutes les
/// étapes, pas seulement à la première.
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
      // Hors ligne : le cache fait foi.
      return cached.index;
    }
    if (serverCount <= cached.count) return cached.index;
  }

  final progress = ref.read(artIndexProgressProvider.notifier);
  try {
    final downloaded = await repository.download(onProgress: progress.report);
    await cache.write(downloaded);
    progress.clear();
    return downloaded;
  } on Object {
    progress.clear();
    // Coupure en cours de téléchargement : servir ce qu'on a déjà plutôt que
    // rien. Sans cache, l'erreur remonte — l'écran de scan n'a alors vraiment
    // rien à proposer, et un index vide ne reconnaîtrait aucune carte sans
    // qu'on sache pourquoi.
    if (cached != null) return cached.index;
    rethrow;
  }
});
