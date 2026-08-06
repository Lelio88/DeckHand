/// Accès aux cartes du catalogue.
///
/// La recherche passe par la fonction Postgres `search_cards`, appelée en RPC.
/// Elle n'exige aucune authentification : le catalogue est en lecture publique,
/// seules les collections sont protégées.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/card_hit.dart';

class CardRepository {
  const CardRepository(this._client);

  final SupabaseClient _client;

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
