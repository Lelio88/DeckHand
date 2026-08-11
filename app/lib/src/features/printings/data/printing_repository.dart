/// Accès aux éditions d'une carte.
///
/// La liste est **toujours bornée et cherchable** : certaines cartes dépassent le
/// millier d'impressions, et tout rapatrier pour laisser l'utilisateur faire défiler
/// serait aussi lent qu'inutilisable. Le serveur remonte les éditions déjà possédées
/// en tête, puis les plus récentes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/request_timeout.dart';
import '../domain/card_printing.dart';

class PrintingRepository {
  const PrintingRepository(this._client);

  final SupabaseClient _client;

  /// Éditions d'une carte, une ligne par édition, [lang] servie en priorité.
  ///
  /// La langue est une **préférence, pas un filtre**. Elle supprime un doublon
  /// systématique — chaque édition figurait deux fois, en français et en
  /// anglais, alors qu'on tient la carte trouvée par son nom français — mais
  /// elle ne fait jamais disparaître une édition. Scryfall ne catalogue pas
  /// toutes les impressions dans toutes les langues : exclure les autres
  /// langues cachait à un joueur l'édition qu'il avait en main.
  Future<List<CardPrinting>> forCard(
    String oracleId, {
    String? query,
    int limit = 60,
    String? lang,
  }) async {
    final rows = await _client
        .rpc<List<dynamic>>(
          'card_printings',
          params: {
            'p_oracle_id': oracleId,
            'p_query': (query ?? '').trim().isEmpty ? null : query!.trim(),
            'p_limit': limit,
            'p_lang': lang,
          },
        )
        .timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(CardPrinting.fromJson)
        .toList(growable: false);
  }

  /// Pour chaque carte du lot n'ayant qu'une seule édition, cette édition.
  ///
  /// Les cartes qui en comptent plusieurs sont absentes du résultat : il n'y a
  /// rien à choisir à leur place. Quatre cartes du catalogue sur dix n'ont
  /// qu'une édition — autant de gestes qu'il est inutile de demander.
  ///
  /// **En un seul aller-retour**, comme la recherche par lot : une requête par
  /// carte coûterait ici les mêmes secondes qu'elle coûtait au scan.
  Future<Map<String, CardPrinting>> soleEditions(
    Iterable<String> oracleIds, {
    String? lang,
  }) async {
    final ids = oracleIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};

    final rows = await _client
        .rpc<List<dynamic>>(
          'sole_editions',
          params: {'p_oracle_ids': ids, 'p_lang': lang},
        )
        .timedOut();
    return {
      for (final row in rows.cast<Map<String, dynamic>>())
        row['oracle_id'] as String: CardPrinting.fromJson(row),
    };
  }
}

final printingRepositoryProvider = Provider<PrintingRepository>(
  (ref) => PrintingRepository(Supabase.instance.client),
);

/// Éditions d'une carte pour une recherche donnée.
///
/// `family` sur le couple (carte, recherche) : deux cartes distinctes ne partagent
/// pas de résultat, et frapper au clavier doit relancer la requête.
final printingsProvider =
    FutureProvider.family<
      List<CardPrinting>,
      ({String oracleId, String query, String? lang})
    >(
      (ref, args) => ref
          .watch(printingRepositoryProvider)
          .forCard(args.oracleId, query: args.query, lang: args.lang),
    );
