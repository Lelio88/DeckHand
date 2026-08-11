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

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/request_timeout.dart';
import '../../../config/selected_game.dart';
import '../../collection/domain/collection_entry.dart' show FinishFilter;
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
    ).timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(BinderShelfEntry.fromJson)
        .toList(growable: false);
  }

  /// Où sont rangées les cartes possédées dont le nom correspond.
  ///
  /// La seule chose qu'une liste faisait mieux qu'un classeur : « où est ma
  /// Foudre ? » n'a pas de réponse quand on n'a que l'ordre des numéros et 97
  /// feuilles à tourner.
  Future<List<BinderFind>> find(
    String query, {
    Game game = Game.magic,
    int limit = 20,
  }) async {
    final needle = query.trim();
    if (needle.isEmpty) return const [];

    final rows = await _client.rpc<List<dynamic>>(
      'my_binder_find',
      params: {
        'p_query': needle,
        'p_game': game.id,
        'p_per_page': binderPageSize,
        'p_limit': limit,
      },
    ).timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(BinderFind.fromJson)
        .toList(growable: false);
  }

  /// Les cartes possédées dont l'édition n'est pas précisée.
  ///
  /// Elles n'ont aucune case : sans impression désignée, il n'y a ni extension
  /// ni numéro. Sans cette pile, elles seraient invisibles dès qu'on regarde sa
  /// collection en classeur.
  Future<List<UnsortedCard>> unsorted({
    Game game = Game.magic,
    int page = 1,
    int perPage = binderPageSize,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'my_unsorted_pile',
      params: {'p_game': game.id, 'p_page': page, 'p_per_page': perPage},
    ).timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(UnsortedCard.fromJson)
        .toList(growable: false);
  }

  /// Une page de classeur.
  ///
  /// [page] commence à 1, comme la première feuille d'un classeur. Trié par
  /// numéro, les cases vides figurent ; trié par valeur ou par nom, elles
  /// disparaissent — voir [BinderSort].
  Future<List<BinderCell>> pageOf(
    String setCode, {
    int page = 1,
    int perPage = binderPageSize,
    BinderSort sort = BinderSort.number,
    FinishFilter finish = FinishFilter.all,
    bool descending = false,
  }) async {
    final rows = await _client.rpc<List<dynamic>>(
      'my_binder_page',
      params: {
        'p_set_code': setCode,
        'p_page': page,
        'p_per_page': perPage,
        'p_sort': sort.id,
        'p_finish': finish.id,
        'p_descending': descending,
      },
    ).timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(BinderCell.fromJson)
        .toList(growable: false);
  }

  /// La première feuille portant au moins une carte possédée.
  ///
  /// Un classeur de 97 feuilles dont on ne possède que douze cartes s'ouvrirait
  /// sinon sur du vide, et il faudrait tourner des pages au hasard.
  Future<int> firstPage(
    String setCode, {
    int perPage = binderPageSize,
    FinishFilter finish = FinishFilter.all,
  }) async {
    final value = await _client.rpc<int>(
      'my_binder_first_page',
      params: {
        'p_set_code': setCode,
        'p_per_page': perPage,
        'p_finish': finish.id,
      },
    ).timedOut();
    return value;
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

/// Comment le classeur ouvert est lu : l'ordre, et la finition retenue.
typedef BinderReading = ({
  BinderSort sort,
  FinishFilter finish,
  bool descending,
});

class BinderReadingNotifier extends Notifier<BinderReading> {
  @override
  BinderReading build() =>
      (sort: BinderSort.number, finish: FinishFilter.all, descending: false);

  /// Choisit un critère, ou **renverse** celui déjà choisi.
  ///
  /// Re-choisir le même critère retourne le classeur : c'est le geste de la
  /// liste de collection, perdu en passant aux menus et rendu ici. Un critère
  /// nouvellement choisi repart dans son sens naturel — première page, cartes
  /// les plus chères, noms de A à Z.
  void sortBy(BinderSort sort) => state = (
    sort: sort,
    finish: state.finish,
    descending: sort == state.sort ? !state.descending : false,
  );

  void filter(FinishFilter finish) =>
      state = (sort: state.sort, finish: finish, descending: state.descending);
}

final binderReadingProvider =
    NotifierProvider<BinderReadingNotifier, BinderReading>(
      BinderReadingNotifier.new,
    );

/// Montrer, en transparence, la carte que chaque case vide attend.
///
/// **Un numéro ne dit pas ce qui manque.** « #2 » nomme la case, pas la carte :
/// il fallait chercher ailleurs pour savoir laquelle aller acheter. Le
/// catalogue portant déjà l'illustration de toutes les cases — `my_binder_page`
/// part de lui et non de la collection —, la montrer en fantôme ne coûte
/// aucune requête de plus.
///
/// **Le réglage n'entre pas dans la clé des pages**, et c'est délibéré : il ne
/// change pas les données rendues par le serveur, seulement leur affichage. L'y
/// mettre ferait retélécharger tout le classeur à chaque bascule.
class ShowMissingArt extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}

final showMissingArtProvider = NotifierProvider<ShowMissingArt, bool>(
  ShowMissingArt.new,
);

/// Une page de classeur. La clé porte l'édition, la page et la lecture : deux
/// pages voisines sont deux requêtes distinctes, et changer de tri ne réutilise
/// pas la page précédente.
final binderPageProvider =
    FutureProvider.family<
      List<BinderCell>,
      ({
        String setCode,
        int page,
        BinderSort sort,
        FinishFilter finish,
        bool descending,
      })
    >((ref, args) {
      // **La page survit à sa disparition de l'écran.** Riverpod dispose un
      // provider dès que plus personne ne l'écoute, et annule la requête en
      // cours avec lui. Or une feuille est construite puis détruite plusieurs
      // fois pendant un retournement — la face qui passe, celle qu'on découvre,
      // celle qui revient — si bien que la requête était annulée puis relancée
      // sans jamais aboutir : la page restait en chargement pour toujours.
      //
      // La garder en vie quelques minutes résout le blocage et évite au passage
      // de retélécharger une feuille qu'on vient de quitter. Le cache n'est pas
      // éternel pour autant : un classeur de 97 feuilles ne doit pas rester
      // entier en mémoire une fois refermé.
      final link = ref.keepAlive();
      final timer = Timer(const Duration(minutes: 3), link.close);
      ref.onDispose(timer.cancel);

      return ref
          .watch(binderRepositoryProvider)
          .pageOf(
            args.setCode,
            page: args.page,
            sort: args.sort,
            finish: args.finish,
            descending: args.descending,
          );
    });

/// La première feuille non vide, pour ne pas ouvrir un classeur sur du creux.
final binderFirstPageProvider =
    FutureProvider.family<int, ({String setCode, FinishFilter finish})>(
      (ref, args) => ref
          .watch(binderRepositoryProvider)
          .firstPage(args.setCode, finish: args.finish),
    );

/// Ce qui est cherché dans les classeurs, ou une chaîne vide.
class BinderQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query.trim();
}

final binderQueryProvider = NotifierProvider<BinderQuery, String>(
  BinderQuery.new,
);

/// Où sont les cartes correspondant à la recherche en cours.
final binderFindProvider = FutureProvider<List<BinderFind>>((ref) {
  final query = ref.watch(binderQueryProvider);
  if (query.isEmpty) return const <BinderFind>[];
  return ref
      .watch(binderRepositoryProvider)
      .find(query, game: ref.watch(selectedGameProvider));
});

/// Une page de la pile à trier.
final unsortedPileProvider = FutureProvider.family<List<UnsortedCard>, int>(
  (ref, page) => ref
      .watch(binderRepositoryProvider)
      .unsorted(game: ref.watch(selectedGameProvider), page: page),
);
