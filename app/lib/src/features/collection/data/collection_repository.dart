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

import '../../../config/selected_game.dart';

import '../../auth/data/auth_repository.dart';
import '../domain/collection_entry.dart';

/// Taille de page. Assez grande pour remplir un écran sans à-coups, assez
/// petite pour que le premier affichage soit immédiat.
const int collectionPageSize = 50;

class CollectionRepository {
  const CollectionRepository(this._client);

  final SupabaseClient _client;

  /// Ajoute des exemplaires et renvoie la quantité totale de cette édition.
  ///
  /// [printId] nul enregistre la carte sans préciser l'édition — le cas courant
  /// d'une saisie rapide, à compléter plus tard.
  Future<int> add(
    String oracleId, {
    int quantity = 1,
    String? printId,
    bool isFoil = false,
  }) async {
    return _client.rpc<int>(
      'add_to_collection',
      params: {
        'p_oracle_id': oracleId,
        'p_quantity': quantity,
        'p_print_id': printId,
        'p_is_foil': isFoil,
      },
    );
  }

  /// Retire des exemplaires et renvoie la quantité restante, zéro si la ligne a
  /// quitté la collection.
  Future<int> remove(
    String oracleId, {
    int quantity = 1,
    String? printId,
    bool isFoil = false,
  }) async {
    return _client.rpc<int>(
      'remove_from_collection',
      params: {
        'p_oracle_id': oracleId,
        'p_quantity': quantity,
        'p_print_id': printId,
        'p_is_foil': isFoil,
      },
    );
  }

  /// Déplace des exemplaires d'une édition vers une autre.
  ///
  /// C'est le geste « ces quatre-là sont de cette édition » : [fromPrintId] nul
  /// désigne les exemplaires non précisés, [toPrintId] nul y ramène. Quantité
  /// omise : tout est déplacé. Les exemplaires fusionnent si la cible existe déjà.
  Future<int> setPrinting(
    String oracleId, {
    String? fromPrintId,
    String? toPrintId,
    int? quantity,
    bool fromFoil = false,
    bool toFoil = false,
  }) async {
    return _client.rpc<int>(
      'set_collection_print',
      params: {
        'p_oracle_id': oracleId,
        'p_from_print_id': fromPrintId,
        'p_to_print_id': toPrintId,
        'p_quantity': quantity,
        'p_from_foil': fromFoil,
        'p_to_foil': toFoil,
      },
    );
  }

  /// Totaux de la collection entière, indépendants de ce qu'on regarde.
  Future<CollectionSummary> summary({Game game = Game.magic}) async {
    final rows = await _client.rpc<List<dynamic>>(
      'my_collection_summary',
      params: {'p_game': game.id},
    );
    if (rows.isEmpty) return CollectionSummary.empty;
    return CollectionSummary.fromJson(rows.first as Map<String, dynamic>);
  }
}

final collectionRepositoryProvider = Provider<CollectionRepository>(
  (ref) => CollectionRepository(Supabase.instance.client),
);

/// Totaux de la collection.
///
/// Séparé de la page pour que filtrer ou trier ne modifie pas les totaux
/// affichés : le bandeau annonce toujours la collection entière.
final collectionProvider = FutureProvider<CollectionSummary>((ref) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return CollectionSummary.empty;
  final game = ref.watch(selectedGameProvider);
  return ref.watch(collectionRepositoryProvider).summary(game: game);
});
