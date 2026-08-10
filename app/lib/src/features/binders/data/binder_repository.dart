/// Accès aux classeurs : l'étagère, puis les pages d'une édition.
///
/// **Tout est dérivé côté serveur**, rien n'est stocké : les deux fonctions
/// lisent `card_prints` et la collection, et n'écrivent jamais. Le classeur ne
/// peut donc pas se désynchroniser de ce qu'on possède.
///
/// La page est demandée **au serveur** plutôt que découpée ici : une édition
/// compte jusqu'à 866 cases, et rapatrier un classeur entier pour n'en montrer
/// neuf serait aussi lent qu'inutile.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/selected_game.dart';
import '../domain/binder.dart';

class BinderRepository {
  const BinderRepository(this._client);

  final SupabaseClient _client;

  /// Les éditions dont au moins une carte est possédée.
  ///
  /// Les 690 autres du catalogue seraient des classeurs vides : l'étagère ne
  /// montre que ce qui a quelque chose dedans.
  Future<List<BinderShelfEntry>> shelf({Game game = Game.magic}) async {
    final rows = await _client.rpc<List<dynamic>>(
      'my_binder_shelf',
      params: {'p_game': game.id},
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(BinderShelfEntry.fromJson)
        .toList(growable: false);
  }

  /// Une page de classeur : les cases dans l'ordre des numéros, vides comprises.
  ///
  /// [page] commence à 1, comme la première feuille d'un classeur.
  Future<List<BinderCell>> pageOf(
    String setCode, {
    int page = 1,
    int perPage = binderPageSize,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'my_binder_page',
      params: {
        'p_set_code': setCode,
        'p_page': page,
        'p_per_page': perPage,
      },
    );
    return rows
        .cast<Map<String, dynamic>>()
        .map(BinderCell.fromJson)
        .toList(growable: false);
  }
}

final binderRepositoryProvider = Provider<BinderRepository>(
  (ref) => BinderRepository(Supabase.instance.client),
);

/// L'étagère de l'utilisateur, pour le jeu sélectionné.
final binderShelfProvider = FutureProvider<List<BinderShelfEntry>>(
  (ref) => ref
      .watch(binderRepositoryProvider)
      .shelf(game: ref.watch(selectedGameProvider)),
);

/// Une page de classeur. La clé porte l'édition et le numéro de page : deux
/// pages voisines sont deux requêtes distinctes, et restent en cache tant que
/// l'écran les regarde.
final binderPageProvider =
    FutureProvider.family<List<BinderCell>, ({String setCode, int page})>(
      (ref, args) => ref
          .watch(binderRepositoryProvider)
          .pageOf(args.setCode, page: args.page),
    );
