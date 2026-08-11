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

import '../../../config/request_timeout.dart';
import '../../../config/selected_game.dart';

import '../../auth/data/auth_repository.dart';
import '../domain/collection_entry.dart';
import '../domain/collection_movement.dart';

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
    return _client
        .rpc<int>(
          'add_to_collection',
          params: {
            'p_oracle_id': oracleId,
            'p_quantity': quantity,
            'p_print_id': printId,
            'p_is_foil': isFoil,
          },
        )
        .timedOut();
  }

  /// Retire des exemplaires et renvoie le nombre **effectivement retiré**.
  ///
  /// Zéro signifie que la ligne visée n'existait pas — cas courant depuis le
  /// classeur, où une case range ensemble le normal et le brillant et propose
  /// donc de retirer une finition qu'elle ne contient peut-être pas. C'est ce
  /// chiffre, et non un total, qui dit s'il y a un retrait à annoncer et
  /// quelque chose à annuler : rajouter un exemplaire jamais retiré
  /// inventerait une carte.
  Future<int> remove(
    String oracleId, {
    int quantity = 1,
    String? printId,
    bool isFoil = false,
  }) async {
    return _client
        .rpc<int>(
          'remove_from_collection',
          params: {
            'p_oracle_id': oracleId,
            'p_quantity': quantity,
            'p_print_id': printId,
            'p_is_foil': isFoil,
          },
        )
        .timedOut();
  }

  /// Déplace des exemplaires d'une édition vers une autre et renvoie le nombre
  /// **effectivement déplacé**.
  ///
  /// C'est le geste « ces quatre-là sont de cette édition » : [fromPrintId] nul
  /// désigne les exemplaires non précisés, [toPrintId] nul y ramène. Quantité
  /// omise : tout est déplacé. Les exemplaires fusionnent si la cible existe déjà.
  ///
  /// **C'est la fusion qui impose de rendre le nombre déplacé** plutôt que le
  /// total de la destination. On possède 2 Foudre MH2 et l'on y corrige 1
  /// Foudre non précisée : la ligne MH2 en porte 3, mais une seule en vient.
  /// Rejouer le mouvement en sens inverse sans quantité renverrait les trois —
  /// la collection resterait juste en nombre, et deux cartes bien rangées
  /// auraient quitté leur classeur sans que rien ne le dise. L'inverse exact
  /// s'écrit donc `setPrinting(cible → source, quantity: <ce nombre>)`.
  Future<int> setPrinting(
    String oracleId, {
    String? fromPrintId,
    String? toPrintId,
    int? quantity,
    bool fromFoil = false,
    bool toFoil = false,
  }) async {
    return _client
        .rpc<int>(
          'set_collection_print',
          params: {
            'p_oracle_id': oracleId,
            'p_from_print_id': fromPrintId,
            'p_to_print_id': toPrintId,
            'p_quantity': quantity,
            'p_from_foil': fromFoil,
            'p_to_foil': toFoil,
          },
        )
        .timedOut();
  }

  /// Totaux de la collection entière, indépendants de ce qu'on regarde.
  Future<CollectionSummary> summary({Game game = Game.magic}) async {
    final rows = await _client
        .rpc<List<dynamic>>(
          'my_collection_summary',
          params: {'p_game': game.id},
        )
        .timedOut();
    if (rows.isEmpty) return CollectionSummary.empty;
    return CollectionSummary.fromJson(rows.first as Map<String, dynamic>);
  }

  /// La collection du compte : son identifiant, et si elle est donnée à lire.
  ///
  /// **L'identifiant est celui de la collection, jamais celui du compte.** Il
  /// sert d'adresse publique — c'est lui qui figurera dans une URL de classeur
  /// ouvert — et il ne rattache la collection à personne : `owner_id` reste
  /// invisible à qui n'a pas de compte.
  Future<Publication> publication() async {
    final rows = await _client
        .from('collections')
        .select('id, is_public, slug, shared_sets')
        .limit(1)
        .timedOut();
    if (rows.isEmpty) return Publication.none;
    final row = rows.first;
    final sets = row['shared_sets'] as List<dynamic>?;
    return Publication(
      collectionId: row['id'] as String,
      isPublic: row['is_public'] as bool? ?? false,
      handle: row['slug'] as String?,
      // **Nul veut dire « tout », et ce n'est pas la même chose qu'une liste
      // vide** — celle-ci ne partagerait rien. La distinction traverse donc
      // toute la chaîne sans jamais être aplatie.
      sharedSets: sets?.cast<String>(),
    );
  }

  /// Donne la collection à lire, ou la retire.
  Future<void> publish(String collectionId, {required bool isPublic}) async {
    await _client
        .from('collections')
        .update({'is_public': isPublic})
        .eq('id', collectionId)
        .timedOut();
  }

  /// Choisit le nom lisible de l'adresse de partage. `null` le retire.
  ///
  /// Lève si le nom est déjà pris : deux collections derrière la même adresse
  /// n'auraient aucun sens, et la base l'interdit par un index unique.
  Future<void> setHandle(String collectionId, String? handle) async {
    await _client
        .from('collections')
        .update({'slug': handle})
        .eq('id', collectionId)
        .timedOut();
  }

  /// Choisit les extensions données à lire. `null` les partage toutes.
  Future<void> setSharedSets(String collectionId, List<String>? sets) async {
    await _client
        .from('collections')
        .update({'shared_sets': sets})
        .eq('id', collectionId)
        .timedOut();
  }

  /// Résout une adresse de partage — un nom ou un identifiant — en collection.
  ///
  /// Rend `null` pour une collection qui n'est pas publiée : une adresse
  /// essayée au hasard ne doit pas révéler qu'elle existe.
  Future<String?> collectionByHandle(String handle) async {
    final value = await _client
        .rpc<String?>('collection_by_handle', params: {'p_handle': handle})
        .timedOut();
    return value;
  }

  /// Le journal des mouvements, du plus récent au plus ancien.
  ///
  /// [oracleId] restreint à une carte — « quand ai-je acquis celle-ci ». Sans
  /// lui, c'est l'histoire de la collection entière.
  Future<List<CollectionMovement>> history({
    Game game = Game.magic,
    String? oracleId,
    int limit = 60,
    int offset = 0,
  }) async {
    final rows = await _client
        .rpc<List<dynamic>>(
          'my_collection_history',
          params: {
            'p_game': game.id,
            'p_oracle_id': oracleId,
            'p_limit': limit,
            'p_offset': offset,
          },
        )
        .timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(CollectionMovement.fromJson)
        .toList(growable: false);
  }
}

/// L'état de publication d'une collection.
class Publication {
  const Publication({
    required this.collectionId,
    required this.isPublic,
    this.handle,
    this.sharedSets,
  });

  final String? collectionId;
  final bool isPublic;

  /// Nom lisible de l'adresse, ou `null` : l'identifiant fait alors office.
  final String? handle;

  /// Extensions partagées, ou `null` pour toutes. Une liste **vide** ne
  /// partagerait rien — ce n'est pas la même chose, et la nuance est portée
  /// jusqu'à la base.
  final List<String>? sharedSets;

  /// Ce qu'il faut mettre dans une adresse : le nom s'il existe, l'identifiant
  /// sinon.
  String? get address => handle ?? collectionId;

  static const none = Publication(collectionId: null, isPublic: false);
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

/// Le journal de la collection, ou celui d'une seule carte.
///
/// La clé porte l'`oracleId` : consulter l'histoire d'une carte depuis sa case
/// ne rejette pas celle de la collection entière.
final collectionHistoryProvider =
    FutureProvider.family<List<CollectionMovement>, String?>((
      ref,
      oracleId,
    ) async {
      final session = ref.watch(sessionProvider).asData?.value;
      if (session == null) return const [];
      return ref
          .watch(collectionRepositoryProvider)
          .history(game: ref.watch(selectedGameProvider), oracleId: oracleId);
    });

/// Publication de la collection du compte.
///
/// `autoDispose` : l'information ne vaut que le temps où l'on regarde l'écran
/// de compte, et elle doit être relue après chaque bascule.
final publicationProvider = FutureProvider.autoDispose<Publication>((
  ref,
) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return Publication.none;
  return ref.watch(collectionRepositoryProvider).publication();
});
