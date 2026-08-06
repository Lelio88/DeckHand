/// Accès à la collection de l'utilisateur connecté.
///
/// Toutes les opérations passent par des fonctions Postgres plutôt que par des
/// requêtes directes : ajouter une carte suppose de trouver ou créer la
/// collection puis d'incrémenter la quantité, ce qui doit rester atomique. La
/// lecture, elle, joint une vue de prix et l'index de noms — jointures que l'API
/// REST ne sait pas déduire seule.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/data/auth_repository.dart';
import '../domain/collection_entry.dart';

class CollectionRepository {
  const CollectionRepository(this._client);

  final SupabaseClient _client;

  /// Ajoute des exemplaires et renvoie la quantité totale désormais possédée.
  Future<int> add(String oracleId, {int quantity = 1}) async {
    final result = await _client.rpc<int>(
      'add_to_collection',
      params: {'p_oracle_id': oracleId, 'p_quantity': quantity},
    );
    return result;
  }

  /// Retire des exemplaires et renvoie la quantité restante, zéro si la carte a
  /// quitté la collection.
  Future<int> remove(String oracleId, {int quantity = 1}) async {
    final result = await _client.rpc<int>(
      'remove_from_collection',
      params: {'p_oracle_id': oracleId, 'p_quantity': quantity},
    );
    return result;
  }

  Future<CollectionSummary> load() async {
    final rows = await _client.rpc<List<dynamic>>('my_collection');
    final entries = rows
        .cast<Map<String, dynamic>>()
        .map(CollectionEntry.fromJson)
        .toList(growable: false);
    return CollectionSummary(entries: entries);
  }
}

final collectionRepositoryProvider = Provider<CollectionRepository>(
  (ref) => CollectionRepository(Supabase.instance.client),
);

/// Contenu de la collection.
///
/// Dépend de `sessionProvider` : à la déconnexion, la collection du compte
/// précédent est écartée au lieu de rester affichée.
final collectionProvider = FutureProvider<CollectionSummary>((ref) async {
  // `asData` plutôt que `value` : pendant le chargement ou en cas d'erreur
  // d'authentification, on rend une collection vide au lieu de propager.
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return const CollectionSummary(entries: []);
  return ref.watch(collectionRepositoryProvider).load();
});
