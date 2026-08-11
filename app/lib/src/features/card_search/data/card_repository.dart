/// Accès aux cartes du catalogue.
///
/// La recherche passe par la fonction Postgres `search_cards`, appelée en RPC.
///
/// **Elle exige une session ouverte**, bien que le catalogue soit en lecture
/// publique : depuis qu'elle rend aussi le nombre d'exemplaires déjà possédés,
/// elle lit `collection_items`, table protégée. Appelée avec la seule clé
/// publique, elle échoue en 401. Sans conséquence dans l'application, où l'on
/// est toujours connecté, mais tout outil qui l'interroge doit d'abord
/// s'authentifier — voir `tool/sweep_spread_threshold.dart`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/request_timeout.dart';
import '../../../config/selected_game.dart';

import '../domain/card_hit.dart';

class CardRepository {
  const CardRepository(this._client);

  final SupabaseClient _client;

  /// Récupère les cartes correspondant à des identifiants, dans l'ordre demandé.
  ///
  /// Utilisé après une reconnaissance : celle-ci rend des identifiants classés
  /// par pertinence, et cet ordre doit survivre à la récupération des détails.
  Future<List<CardHit>> byOracleIds(List<String> oracleIds) async {
    if (oracleIds.isEmpty) return const [];

    final rows = await _client.rpc<List<dynamic>>(
      'cards_by_oracle_ids',
      params: {'p_ids': oracleIds},
    ).timedOut();

    return rows
        .cast<Map<String, dynamic>>()
        .map((row) {
          final printed = row['printed_name'] as String?;
          return CardHit.fromJson({
            ...row,
            'matched_name': printed ?? row['name'],
            'matched_lang': printed == null ? 'en' : 'fr',
          });
        })
        .toList(growable: false);
  }

  /// Recherche des cartes par nom, en français comme en anglais, avec tolérance
  /// aux fautes de frappe.
  ///
  /// Une saisie vide renvoie une liste vide sans solliciter le réseau — inutile
  /// d'interroger la base à chaque effacement du champ.
  /// [types] restreint aux cartes portant l'un de ces types. Vide, il ne filtre
  /// rien — le filtrage vit côté serveur, faute de quoi restreindre à
  /// « Terrain » ne garderait que les terrains des vingt premiers résultats.
  Future<List<CardHit>> search(
    String query, {
    int limit = 20,
    Game game = Game.magic,
    Iterable<String> types = const [],
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final rows = await _client.rpc<List<dynamic>>(
      'search_cards',
      params: {
        'q': trimmed,
        'max_results': limit,
        'p_game': game.id,
        'p_types': types.toList(growable: false),
      },
    ).timedOut();

    return rows
        .cast<Map<String, dynamic>>()
        .map(CardHit.fromJson)
        .toList(growable: false);
  }

  /// Meilleure correspondance pour chacun des noms donnés, en **un seul**
  /// aller-retour.
  ///
  /// **Pourquoi cette méthode existe plutôt qu'une boucle sur [search].** Le
  /// scan d'étalement cherchait un nom par appel. Mesuré sur une photo de
  /// dix-sept cartes — 112 lignes candidates —, cela prenait **77 secondes**,
  /// et les grouper par vagues de 25 n'y changeait rien : chaque vague durait
  /// 15 secondes, soit exactement 25 × 600 ms. Le serveur traite les requêtes
  /// l'une après l'autre ; la concurrence côté client n'achète rien et le total
  /// vaut mécaniquement « nombre de lignes × 600 ms ».
  ///
  /// Pire, la connexion lâchait en route : 18 requêtes sur 112 mouraient depuis
  /// un poste filaire, et toutes depuis un téléphone tenant vingt-cinq
  /// connexions ouvertes un quart de minute. L'écran ne montrait alors aucune
  /// carte — sans dire pourquoi.
  ///
  /// En un appel, les mêmes 112 lignes reviennent en **3,3 secondes**.
  ///
  /// Le résultat est indexé par le nom demandé : un même nom lu deux fois sur
  /// la photo ne compte qu'une entrée, et l'appelant retrouve sa ligne sans
  /// dépendre de l'ordre des lignes rendues.
  Future<Map<String, CardHit>> searchMany(
    List<String> names, {
    Game game = Game.magic,
  }) async {
    final wanted = names
        .map((n) => n.trim())
        .where((n) => n.isNotEmpty)
        .toList(growable: false);
    if (wanted.isEmpty) return const {};

    final rows = await _client.rpc<List<dynamic>>(
      'search_cards_bulk',
      params: {'p_names': wanted, 'p_game': game.id},
    ).timedOut();

    return {
      for (final row in rows.cast<Map<String, dynamic>>())
        row['query'] as String: CardHit.fromJson(row),
    };
  }
}

final cardRepositoryProvider = Provider<CardRepository>(
  (ref) => CardRepository(Supabase.instance.client),
);

/// Ce que l'écran de recherche demande : une saisie et des types retenus.
///
/// **Les types voyagent en chaîne, pas en liste.** Un `record` compare ses
/// champs par `==`, et deux `List` de même contenu ne sont jamais égales en
/// Dart : la clé de `family` aurait changé à chaque reconstruction de l'écran,
/// relançant la requête, qui reconstruisait l'écran — l'écran de recherche
/// tournait en boucle jusqu'à expiration.
///
/// Les types sont triés à la construction pour que deux sélections identiques
/// faites dans un ordre différent partagent le même cache.
typedef CardQuery = ({String text, String types});

CardQuery cardQuery(String text, Iterable<String> types) =>
    (text: text, types: (types.toList(growable: false)..sort()).join(','));

/// Résultats pour une saisie donnée.
///
/// `autoDispose` associé à `family` fait qu'une recherche abandonnée libère sa
/// place : en frappant « lightning », l'utilisateur produit neuf requêtes dont
/// une seule compte.
final cardSearchProvider = FutureProvider.autoDispose
    .family<List<CardHit>, CardQuery>((ref, query) {
      // `watch` et non `read` : changer de jeu doit relancer la recherche
      // en cours, sinon l'écran garde les résultats de l'autre catalogue.
      final game = ref.watch(selectedGameProvider);
      return ref
          .watch(cardRepositoryProvider)
          .search(
            query.text,
            game: game,
            types: query.types.isEmpty ? const [] : query.types.split(','),
          );
    });
