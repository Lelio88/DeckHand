/// Tests de l'arbitrage entre cache et téléchargement de l'index.
///
/// **Ce que ces tests protègent est un écran vide.** L'index est le préalable au
/// scan ; s'il n'arrive pas, l'écran ne montre rien d'utilisable. Or il pèse une
/// cinquantaine de pages, et chaque page est une occasion de perdre le réseau.
/// La règle est donc qu'un index déjà présent l'emporte toujours sur un
/// téléchargement raté — à n'importe quelle étape, pas seulement à la première.
///
/// Le second point vérifié est l'avancement : il doit être publié pendant le
/// téléchargement, et **effacé après**, abouti ou non. Un avancement figé à
/// mi-course survivrait au provider et mentirait au chargement suivant.
library;

import 'package:deckhand/src/features/scan/data/art_index_cache.dart';
import 'package:deckhand/src/features/scan/data/art_index_repository.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ArtHashIndex indexOf(List<String> ids) => ArtHashIndex.fromEntries([
  for (final id in ids)
    (oracleId: id, hash: ArtHash.fromHex('0000000000000000')),
]);

/// Dépôt d'index qui n'appelle aucun réseau.
class FakeIndexRepository implements ArtIndexRepository {
  FakeIndexRepository({this.serverCount = 0, this.downloaded});

  int serverCount;
  ArtHashIndex? downloaded;

  /// Erreur à lever, respectivement au comptage et au téléchargement.
  Object? countError;
  Object? downloadError;

  /// Avancements publiés, dans l'ordre.
  final progress = <({int received, int total})>[];

  @override
  Future<int> count() async {
    if (countError != null) throw countError!;
    return serverCount;
  }

  @override
  Future<ArtHashIndex> download({
    void Function(int received, int total)? onProgress,
  }) async {
    onProgress?.call(1, serverCount);
    if (downloadError != null) throw downloadError!;
    onProgress?.call(serverCount, serverCount);
    return downloaded ?? indexOf(const []);
  }
}

/// Cache d'index en mémoire, sans `shared_preferences`.
class FakeIndexCache implements ArtIndexCache {
  FakeIndexCache([this.stored]);

  CachedIndex? stored;
  int writes = 0;

  @override
  Future<CachedIndex?> read() async => stored;

  @override
  Future<void> write(ArtHashIndex index) async {
    writes++;
    stored = (index: index, count: index.length);
  }

  @override
  Future<void> clear() async => stored = null;
}

ProviderContainer containerWith(
  FakeIndexRepository repository,
  FakeIndexCache cache,
) {
  final container = ProviderContainer(
    overrides: [
      artIndexRepositoryProvider.overrideWithValue(repository),
      artIndexCacheProvider.overrideWithValue(cache),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('un cache à jour évite le téléchargement', () async {
    final cache = FakeIndexCache((index: indexOf(['a', 'b']), count: 2));
    final repository = FakeIndexRepository(serverCount: 2);
    final container = containerWith(repository, cache);

    final index = await container.read(artHashIndexProvider.future);

    expect(index.length, 2);
    expect(cache.writes, 0, reason: 'rien de neuf à écrire');
  });

  test('un serveur plus fourni déclenche le téléchargement', () async {
    final cache = FakeIndexCache((index: indexOf(['a']), count: 1));
    final repository = FakeIndexRepository(
      serverCount: 3,
      downloaded: indexOf(['a', 'b', 'c']),
    );
    final container = containerWith(repository, cache);

    final index = await container.read(artHashIndexProvider.future);

    expect(index.length, 3);
    expect(cache.writes, 1);
  });

  test('un comptage impossible sert le cache', () async {
    final cache = FakeIndexCache((index: indexOf(['a', 'b']), count: 2));
    final repository = FakeIndexRepository()
      ..countError = Exception('hors ligne');
    final container = containerWith(repository, cache);

    expect((await container.read(artHashIndexProvider.future)).length, 2);
  });

  test(
    'un téléchargement interrompu sert le cache plutôt que d\'échouer',
    () async {
      // Le cas qui manquait : la coupure survient après le comptage, donc passé
      // le seul repli qui existait. L'écran annonçait « index indisponible »
      // alors qu'un index utilisable dormait sur l'appareil.
      final cache = FakeIndexCache((index: indexOf(['a', 'b']), count: 2));
      final repository = FakeIndexRepository(serverCount: 9)
        ..downloadError = Exception('réseau coupé en cours de route');
      final container = containerWith(repository, cache);

      final index = await container.read(artHashIndexProvider.future);

      expect(
        index.length,
        2,
        reason: 'un index d\'hier vaut mieux qu\'aucun scan',
      );
    },
  );

  test('sans cache, un téléchargement raté remonte l\'erreur', () async {
    // Rien à servir : mieux vaut le dire que rendre un index vide, qui ne
    // reconnaîtrait aucune carte sans qu'on sache pourquoi.
    final repository = FakeIndexRepository(serverCount: 9)
      ..downloadError = Exception('réseau coupé');
    final container = containerWith(repository, FakeIndexCache());

    // L'écoute est nécessaire : un `FutureProvider` en erreur sans abonné ne
    // complète pas son `.future`, et le test expirerait au lieu d'échouer.
    final states = <AsyncValue<ArtHashIndex>>[];
    container.listen(
      artHashIndexProvider,
      (_, next) => states.add(next),
      fireImmediately: true,
      onError: (_, _) {},
    );

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(states.last.hasError, isTrue);
  });

  test('l\'avancement est publié puis effacé', () async {
    final repository = FakeIndexRepository(
      serverCount: 2,
      downloaded: indexOf(['a', 'b']),
    );
    final container = containerWith(repository, FakeIndexCache());

    final seen = <({int received, int total})?>[];
    container.listen(
      artIndexProgressProvider,
      (_, next) => seen.add(next),
      fireImmediately: false,
    );

    await container.read(artHashIndexProvider.future);

    expect(seen.whereType<({int received, int total})>(), isNotEmpty);
    expect(
      container.read(artIndexProgressProvider),
      isNull,
      reason: 'un avancement figé mentirait au chargement suivant',
    );
  });

  test(
    'l\'avancement est effacé même quand le téléchargement échoue',
    () async {
      final repository = FakeIndexRepository(serverCount: 5)
        ..downloadError = Exception('coupure');
      final cache = FakeIndexCache((index: indexOf(['a']), count: 1));
      final container = containerWith(repository, cache);

      await container.read(artHashIndexProvider.future);

      expect(container.read(artIndexProgressProvider), isNull);
    },
  );
}
