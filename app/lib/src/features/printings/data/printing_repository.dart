/// Accès aux éditions d'une carte.
///
/// La liste est **toujours bornée et cherchable** : certaines cartes dépassent le
/// millier d'impressions, et tout rapatrier pour laisser l'utilisateur faire défiler
/// serait aussi lent qu'inutilisable. Le serveur remonte les éditions déjà possédées
/// en tête, puis les plus récentes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/card_printing.dart';

class PrintingRepository {
  const PrintingRepository(this._client);

  final SupabaseClient _client;

  /// Éditions d'une carte, restreintes à [lang] quand elle est connue.
  ///
  /// Le filtre de langue supprime un doublon systématique : chaque édition
  /// existait en français et en anglais dans la liste, alors que la langue est
  /// déjà déterminée — on a trouvé la carte par son nom français, donc c'est la
  /// version française qu'on tient.
  Future<List<CardPrinting>> forCard(
    String oracleId, {
    String? query,
    int limit = 60,
    String? lang,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'card_printings',
      params: {
        'p_oracle_id': oracleId,
        'p_query': (query ?? '').trim().isEmpty ? null : query!.trim(),
        'p_limit': limit,
        'p_lang': lang,
      },
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(CardPrinting.fromJson)
        .toList(growable: false);
  }
}

final printingRepositoryProvider = Provider<PrintingRepository>(
  (ref) => PrintingRepository(Supabase.instance.client),
);

/// Éditions d'une carte pour une recherche donnée.
///
/// `family` sur le couple (carte, recherche) : deux cartes distinctes ne partagent
/// pas de résultat, et frapper au clavier doit relancer la requête.
final printingsProvider = FutureProvider.family<
  List<CardPrinting>,
  ({String oracleId, String query, String? lang})
>(
  (ref, args) => ref
      .watch(printingRepositoryProvider)
      .forCard(args.oracleId, query: args.query, lang: args.lang),
);
