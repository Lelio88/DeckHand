/// Fraîcheur des données affichée à l'utilisateur.
///
/// Les prix Scryfall sont republiés chaque jour. Savoir de quand datent ceux
/// qu'on lui montre permet à l'utilisateur de juger un total de collection ou un
/// coût de complétion — un écart de plusieurs semaines change l'interprétation.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef IngestionStatus = ({String source, DateTime? lastRun, int items});

class DataFreshnessRepository {
  const DataFreshnessRepository(this._client);

  final SupabaseClient _client;

  Future<List<IngestionStatus>> load() async {
    final rows = await _client
        .from('ingestion_state')
        .select('source, last_run_at, items_processed')
        .order('source');

    return rows
        .map<IngestionStatus>((row) {
          final ran = row['last_run_at'] as String?;
          return (
            source: row['source'] as String,
            lastRun: ran == null ? null : DateTime.tryParse(ran),
            items: (row['items_processed'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }
}

final dataFreshnessRepositoryProvider = Provider<DataFreshnessRepository>(
  (ref) => DataFreshnessRepository(Supabase.instance.client),
);

final dataFreshnessProvider = FutureProvider.autoDispose<List<IngestionStatus>>(
  (ref) => ref.watch(dataFreshnessRepositoryProvider).load(),
);
