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
    );

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
  Future<List<CardHit>> search(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final rows = await _client.rpc<List<dynamic>>(
      'search_cards',
      params: {'q': trimmed, 'max_results': limit},
    );

    return rows
        .cast<Map<String, dynamic>>()
        .map(CardHit.fromJson)
        .toList(growable: false);
  }
}

final cardRepositoryProvider = Provider<CardRepository>(
  (ref) => CardRepository(Supabase.instance.client),
);

/// Résultats pour une saisie donnée.
///
/// `autoDispose` associé à `family` fait qu'une recherche abandonnée libère sa
/// place : en frappant « lightning », l'utilisateur produit neuf requêtes dont
/// une seule compte.
final cardSearchProvider = FutureProvider.autoDispose
    .family<List<CardHit>, String>((ref, query) {
      return ref.watch(cardRepositoryProvider).search(query);
    });
