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
///
/// **Un index par jeu, et pas seulement pour économiser du réseau.** L'index
/// portait les 50 209 empreintes des deux catalogues, quel que soit le jeu
/// choisi. En Riftbound, cinquante allers-retours pour 1 193 empreintes utiles ;
/// en Magic, 1 193 empreintes qui ne pouvaient rien faire de bon. **379 d'entre
/// elles tombent à moins de 12 bits d'une empreinte Magic** — sous le seuil de
/// confiance —, si bien qu'une carte Magic photographiée pouvait se voir
/// répondre une carte de l'autre jeu, ou perdre la marge de 4 bits qui autorise
/// à trancher. Le cloisonnement n'était donc pas qu'une question de volume.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/request_timeout.dart';
import '../../../config/selected_game.dart';
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

/// Pages demandées en même temps.
///
/// **Quatre, parce que c'est là que le gain s'arrête** — voir la mesure dans
/// [ArtIndexRepository.download]. Le chiffre borne aussi ce qu'on demande au
/// serveur d'un coup : un index n'est pas une urgence, et rien ne justifie de
/// lui ouvrir douze connexions pour un gain nul.
const int indexConcurrency = 4;

/// Les décalages à demander, groupés par lots de [indexConcurrency].
///
/// Isolé du dépôt pour être éprouvé sans réseau : c'est ici que se trouvent les
/// seuls cas tordus du découpage — un total nul, un total plus petit qu'une
/// page, un dernier lot incomplet. Une erreur d'un rang y perdrait mille
/// empreintes en silence, l'index restant parfaitement fonctionnel pour toutes
/// les autres.
List<List<int>> indexBatches(int total) {
  if (total <= 0) return const [];
  final offsets = [
    for (var offset = 0; offset < total; offset += indexPageSize) offset,
  ];
  return [
    for (var start = 0; start < offsets.length; start += indexConcurrency)
      offsets.skip(start).take(indexConcurrency).toList(growable: false),
  ];
}

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

  /// Nombre d'empreintes disponibles côté serveur, pour ce jeu.
  Future<int> count(Game game) async {
    final value = await _client
        .rpc<int>('art_hash_count', params: {'p_game': game.id})
        .timedOut(indexPageTimeout);
    return value;
  }

  /// Télécharge l'index complet d'un jeu.
  ///
  /// [onProgress] est appelé après chaque lot avec le nombre d'entrées reçues
  /// et le total attendu — un index de plusieurs dizaines de milliers d'entrées
  /// met plusieurs secondes à arriver, l'utilisateur doit le voir.
  ///
  /// **Les pages partent par lots, et le nombre est mesuré.** La boucle était
  /// strictement séquentielle : chaque page attendait la précédente, si bien que
  /// cinquante allers-retours se payaient bout à bout. Mesuré sur l'index Magic
  /// depuis une liaison filaire :
  ///
  /// | En parallèle | Durée |
  /// |---|---|
  /// | 1 (l'ancien) | 25,10 s |
  /// | 2 | 10,35 s |
  /// | **4** | **9,44 s** |
  /// | 6 / 8 / 12 | 10,16 / 9,98 / 9,62 s |
  ///
  /// Le plateau est net à quatre : au-delà, ce n'est plus la latence qui borne
  /// mais la bande passante — 6,4 Mio à rapatrier. En demander douze ne gagnerait
  /// rien et solliciterait le serveur pour rien.
  Future<ArtHashIndex> download(
    Game game, {
    void Function(int received, int total)? onProgress,
  }) async {
    final total = await count(game);
    final lots = indexBatches(total);
    if (lots.isEmpty) return ArtHashIndex.fromEntries(const []);

    // Les pages sont rangées à leur place et non ajoutées à la file d'arrivée :
    // un lot ne revient pas forcément dans l'ordre où il est parti, et l'index
    // doit être reproductible d'un téléchargement à l'autre.
    final pages = <List<IndexEntry>>[];
    var received = 0;

    for (final lot in lots) {
      final arrivees = await Future.wait([
        for (final offset in lot) _page(game, offset),
      ]);
      for (final page in arrivees) {
        pages.add(page);
        received += page.length;
      }
      onProgress?.call(received, total);
    }

    return ArtHashIndex.fromEntries([for (final page in pages) ...page]);
  }

  Future<List<IndexEntry>> _page(Game game, int offset) async {
    final rows = await _client
        .rpc<List<dynamic>>(
          'art_hash_page',
          params: {
            'p_offset': offset,
            'p_limit': indexPageSize,
            'p_game': game.id,
          },
        )
        .timedOut(indexPageTimeout);

    return [
      for (final row in rows.cast<Map<String, dynamic>>())
        (
          oracleId: row['oracle_id'] as String,
          // L'impression, et non seulement la carte : une carte Magic sur
          // quatre porte plusieurs illustrations, et c'est celle qui a été
          // reconnue qu'il faut montrer avant que l'utilisateur confirme.
          printId: row['print_id'] as String,
          hash: ArtHash.fromHex(row['hash_hex'] as String),
        ),
    ];
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

/// Index du jeu choisi, chargé en mémoire, servi depuis le cache quand il est à
/// jour.
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
/// **Changer de jeu recharge l'index, sans le retélécharger.** Le provider suit
/// [selectedGameProvider] : la mémoire ne porte donc que le jeu courant, alors
/// que le cache local garde les deux. Une bascule aller-retour ne coûte qu'une
/// relecture disque et un appel de comptage.
///
/// `keepAlive` implicite : le provider n'est pas `autoDispose`, l'index survit
/// donc à la fermeture de l'écran de scan.
final artHashIndexProvider = FutureProvider<ArtHashIndex>((ref) async {
  final repository = ref.watch(artIndexRepositoryProvider);
  final cache = ref.watch(artIndexCacheProvider);
  final game = ref.watch(selectedGameProvider);

  final cached = await cache.read(game);

  if (cached != null) {
    int? serverCount;
    try {
      serverCount = await repository.count(game);
    } on Object {
      // Hors ligne : le cache fait foi.
      return cached.index;
    }
    if (serverCount <= cached.count) return cached.index;
  }

  final progress = ref.read(artIndexProgressProvider.notifier);
  try {
    final downloaded = await repository.download(
      game,
      onProgress: progress.report,
    );
    await cache.write(game, downloaded);
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
