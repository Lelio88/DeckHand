/// Accès à la collection, telle que le constructeur de decks la voit.
///
/// **En un seul aller-retour, et c'est nécessaire.** Le constructeur ne peut pas
/// décider quelles cartes retenir en n'en voyant qu'une page : il lui faut la
/// collection entière. Une collection de deux mille cartes fait deux mille
/// lignes, soit quelques centaines de kilo-octets — le prix d'une requête, à
/// comparer aux quarante que coûterait la pagination.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/selected_game.dart';
import '../../auth/data/auth_repository.dart';
import '../../decks/domain/deck_suggestion.dart';
import '../domain/buildable_card.dart';

class BuildableRepository {
  const BuildableRepository(this._client);

  final SupabaseClient _client;

  Future<List<BuildableCard>> collection({
    DeckFormat format = DeckFormat.commander,
    Game game = Game.magic,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'my_buildable_cards',
      params: {'p_format': format.id, 'p_game': game.id},
    );

    return rows.cast<Map<String, dynamic>>().map(_fromJson).toList(growable: false);
  }

  BuildableCard _fromJson(Map<String, dynamic> json) => BuildableCard(
    oracleId: json['oracle_id'] as String,
    name: json['name'] as String,
    printedName: json['printed_name'] as String?,
    typeLine: json['type_line'] as String? ?? '',
    cmc: (json['cmc'] as num?)?.toDouble() ?? 0,
    manaCost: json['mana_cost'] as String? ?? '',
    colorIdentity:
        (json['color_identity'] as List<dynamic>?)?.cast<String>().toSet() ??
        <String>{},
    oracleText: json['oracle_text'] as String? ?? '',
    quantity: (json['quantity'] as num?)?.toInt() ?? 1,
    priceEur: (json['price_eur'] as num?)?.toDouble(),
  );
}

final buildableRepositoryProvider = Provider<BuildableRepository>(
  (ref) => BuildableRepository(Supabase.instance.client),
);

/// Collection jouable dans le format demandé.
///
/// `autoDispose` : elle est rapatriée pour construire un deck, pas pour être
/// gardée en mémoire une fois l'écran refermé.
final buildableCollectionProvider = FutureProvider.autoDispose
    .family<List<BuildableCard>, DeckFormat>((ref, format) async {
      final session = ref.watch(sessionProvider).asData?.value;
      if (session == null) return const [];
      final game = ref.watch(selectedGameProvider);
      return ref
          .watch(buildableRepositoryProvider)
          .collection(format: format, game: game);
    });
