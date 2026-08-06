/// Accès à la collection de l'utilisateur connecté.
///
/// Toutes les opérations passent par des fonctions Postgres plutôt que par des
/// requêtes directes : ajouter une carte suppose de trouver ou créer la
/// collection puis d'incrémenter la quantité, ce qui doit rester atomique. La
/// lecture, elle, joint une vue de prix et l'index de noms — jointures que l'API
/// REST ne sait pas déduire d'elle-même faute de clé étrangère.
///
/// **La lecture est paginée**, parce que le produit vise deux mille cartes :
/// tout rapatrier à chaque ouverture serait aussi lent qu'inutile, et une carte
/// y serait introuvable. Les agrégats font l'objet d'un appel distinct, sur la
/// collection entière — une page ne peut pas les porter.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/data/auth_repository.dart';
import '../domain/collection_entry.dart';

/// Taille de page. Assez grande pour remplir un écran sans à-coups, assez
/// petite pour que le premier affichage soit immédiat.
const int collectionPageSize = 50;

class CollectionRepository {
  const CollectionRepository(this._client);

  final SupabaseClient _client;

  /// Ajoute des exemplaires et renvoie la quantité totale désormais possédée.
  Future<int> add(String oracleId, {int quantity = 1}) async {
    return _client.rpc<int>(
      'add_to_collection',
      params: {'p_oracle_id': oracleId, 'p_quantity': quantity},
    );
  }

  /// Retire des exemplaires et renvoie la quantité restante, zéro si la carte a
  /// quitté la collection.
  Future<int> remove(String oracleId, {int quantity = 1}) async {
    return _client.rpc<int>(
      'remove_from_collection',
      params: {'p_oracle_id': oracleId, 'p_quantity': quantity},
    );
  }

  /// Une page de collection, filtrée et ordonnée.
  Future<List<CollectionEntry>> page({
    String? query,
    CollectionSort sort = CollectionSort.name,
    int offset = 0,
    int limit = collectionPageSize,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'my_collection',
      params: {
        'p_query': (query ?? '').trim().isEmpty ? null : query!.trim(),
        'p_sort': sort.id,
        'p_limit': limit,
        'p_offset': offset,
      },
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(CollectionEntry.fromJson)
        .toList(growable: false);
  }

  /// Totaux de la collection entière, indépendants de la page affichée.
  Future<CollectionSummary> summary() async {
    final rows = await _client.rpc<List<dynamic>>('my_collection_summary');
    if (rows.isEmpty) return CollectionSummary.empty;
    return CollectionSummary.fromJson(rows.first as Map<String, dynamic>);
  }
}

final collectionRepositoryProvider = Provider<CollectionRepository>(
  (ref) => CollectionRepository(Supabase.instance.client),
);

/// Critères de consultation, partagés entre le champ de recherche et le tri.
typedef CollectionView = ({String query, CollectionSort sort});

class CollectionViewNotifier extends Notifier<CollectionView> {
  @override
  CollectionView build() => (query: '', sort: CollectionSort.name);

  void search(String value) => state = (query: value, sort: state.sort);

  void sortBy(CollectionSort sort) => state = (query: state.query, sort: sort);
}

final collectionViewProvider =
    NotifierProvider<CollectionViewNotifier, CollectionView>(
      CollectionViewNotifier.new,
    );

/// Totaux de la collection.
///
/// Séparé de la page pour que filtrer ou trier ne modifie pas les totaux
/// affichés : le bandeau annonce toujours la collection entière.
final collectionProvider = FutureProvider<CollectionSummary>((ref) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return CollectionSummary.empty;
  return ref.watch(collectionRepositoryProvider).summary();
});

/// Première page de la collection selon les critères courants.
///
/// Les pages suivantes sont chargées par l'écran au défilement ; ce provider ne
/// porte que l'amorce, dont dépend l'affichage initial.
final collectionPageProvider = FutureProvider<List<CollectionEntry>>((
  ref,
) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return const [];

  final view = ref.watch(collectionViewProvider);
  return ref
      .watch(collectionRepositoryProvider)
      .page(query: view.query, sort: view.sort);
});
