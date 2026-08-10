/// Doublures de test, écrites à la main plutôt que générées.
///
/// Un fake enregistre ce qu'on lui demande et rend ce qu'on lui a préparé. Cela
/// permet d'affirmer sur un **état final** — « le dépôt a bien reçu ces
/// filtres » — plutôt que sur une séquence d'appels, assertion fragile qui casse
/// au moindre remaniement.
library;

import 'package:deckhand/src/features/card_search/data/card_repository.dart';
import 'package:deckhand/src/features/scan/data/card_text_reader.dart';
import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:deckhand/src/features/decks/data/deck_repository.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Session Supabase minimale, pour les écrans qui exigent un utilisateur connecté.
Session fakeSession() => Session(
  accessToken: 'jeton-de-test',
  tokenType: 'bearer',
  user: User(
    id: '00000000-0000-0000-0000-000000000001',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
  ),
);

DeckSuggestion fakeDeck({
  String id = 'deck-1',
  String name = 'Deck de test',
  String tier = 'competitive',
  int total = 60,
  int owned = 50,
  double cost = 12.5,
}) => DeckSuggestion(
  deckId: id,
  deckName: name,
  tier: tier,
  sourceName: 'TopDeck.gg',
  attribution: 'Données de tournoi fournies par TopDeck.gg',
  totalCards: total,
  ownedCards: owned,
  missingCards: total - owned,
  completion: owned / total,
  missingCostEur: cost,
);

/// Enregistre les filtres reçus — c'est précisément ce qui n'était pas transmis
/// lorsque l'interface affichait « ≤ 10 € » sur une liste inchangée.
class FakeDeckRepository implements DeckRepository {
  DeckFormat? lastFormat;
  DeckFilters? lastFilters;
  List<DeckSuggestion> results = const [];
  List<MissingCard> missing = const [];

  @override
  Future<List<DeckSuggestion>> suggestions(
    DeckFormat format, {
    DeckFilters filters = const DeckFilters(),
    int maxResults = 30,
  }) async {
    lastFormat = format;
    lastFilters = filters;
    return results;
  }

  @override
  Future<List<MissingCard>> missingCards(String deckId) async => missing;
}

/// Faux lecteur de texte.
///
/// Sert à éprouver la fusion « nom lu + illustration » sans dépendre du service
/// natif de reconnaissance, indisponible en test.
class FakeCardTextReader implements CardTextReader {
  List<ReadLine> lines = const [];
  String? lastPath;

  @override
  ({double width, double height})? lastImageSize;

  @override
  Future<List<ReadLine>> readLines(String path) async {
    lastPath = path;
    return lines;
  }

  @override
  Future<void> dispose() async {}
}

/// Faux catalogue de cartes.
class FakeCardRepository implements CardRepository {
  List<CardHit> results = const [];
  String? lastQuery;

  /// Types demandes lors de la derniere recherche. Le filtrage est fait par le
  /// serveur : ce qui s'observe ici, c'est qu'il lui parvienne.
  List<String>? lastTypes;

  @override
  Future<List<CardHit>> search(
    String query, {
    int limit = 20,
    Game game = Game.magic,
    Iterable<String> types = const [],
  }) async {
    lastQuery = query;
    lastTypes = types.toList(growable: false);
    return query.trim().isEmpty ? const [] : results;
  }

  @override
  Future<List<CardHit>> byOracleIds(List<String> oracleIds) async => results;

  /// Noms cherchés lors du dernier appel groupé.
  List<String>? lastBulkQuery;

  /// Panne à simuler. Le scan d'étalement doit la laisser remonter et non la
  /// convertir en « aucune carte trouvée ».
  Object? searchError;

  @override
  Future<Map<String, CardHit>> searchMany(
    List<String> names, {
    Game game = Game.magic,
  }) async {
    lastBulkQuery = names;
    if (searchError != null) throw searchError!;
    // La correspondance se fait sur le nom demandé, comme côté serveur : le
    // faux catalogue rend un résultat pour toute ligne qui porte le nom d'une
    // carte connue.
    return {
      for (final name in names)
        for (final hit in results)
          if (name.toLowerCase() == hit.matchedName.toLowerCase() ||
              name.toLowerCase() == hit.name.toLowerCase())
            name: hit,
    };
  }
}

class FakeCollectionRepository implements CollectionRepository {
  /// Quantités par (carte, édition). L'édition nulle — « non précisée » — est une
  /// clé comme une autre : c'est exactement ce que fait la contrainte
  /// `UNIQUE NULLS NOT DISTINCT` côté base.
  final Map<(String, String?), int> quantities = {};

  /// Contenu servi par `page`, dans l'ordre où il a été posé.
  List<CollectionEntry> entries = const [];
  CollectionSummary totals = CollectionSummary.empty;

  /// Ce que la dernière consultation a demandé — c'est ce qui permet de vérifier
  /// que l'écran transmet bien la recherche et le tri, et pas seulement qu'il
  /// les affiche.
  String? lastQuery;
  CollectionSort? lastSort;
  int? lastOffset;
  bool? lastUnspecifiedOnly;

  /// Sens et filtres de la derniere consultation. Le serveur les applique :
  /// ce qui s'observe ici, c'est qu'ils lui parviennent.
  bool? lastDescending;
  FinishFilter? lastFinish;
  bool? lastFullArt;

  /// Dernier déplacement d'édition demandé.
  ({String oracleId, String? from, String? to, int? quantity})? lastPrintingMove;

  /// Ajouts recus, dans l'ordre et sans agregation.
  ///
  /// `quantities` ignore la finition : deux exemplaires normal et brillant y
  /// tombent dans la meme case. Cette liste la retient, faute de quoi un
  /// exemplaire enregistre dans la mauvaise finition serait indetectable —
  /// c'est pourtant un ecart de prix du simple au triple.
  final List<({String oracleId, String? printId, bool isFoil, int quantity})>
  added = [];

  @override
  Future<int> add(
    String oracleId, {
    int quantity = 1,
    String? printId,
    bool isFoil = false,
  }) async {
    added.add((
      oracleId: oracleId,
      printId: printId,
      isFoil: isFoil,
      quantity: quantity,
    ));
    final key = (oracleId, printId);
    quantities[key] = (quantities[key] ?? 0) + quantity;
    return quantities[key]!;
  }

  @override
  Future<int> remove(
    String oracleId, {
    int quantity = 1,
    String? printId,
    bool isFoil = false,
  }) async {
    final key = (oracleId, printId);
    final left = (quantities[key] ?? 0) - quantity;
    if (left <= 0) {
      quantities.remove(key);
      return 0;
    }
    quantities[key] = left;
    return left;
  }

  @override
  Future<int> setPrinting(
    String oracleId, {
    String? fromPrintId,
    String? toPrintId,
    int? quantity,
    bool fromFoil = false,
    bool toFoil = false,
  }) async {
    lastPrintingMove = (
      oracleId: oracleId,
      from: fromPrintId,
      to: toPrintId,
      quantity: quantity,
    );

    final source = (oracleId, fromPrintId);
    final available = quantities[source] ?? 0;
    if (available == 0) return 0;

    final moved = quantity == null ? available : (quantity.clamp(1, available));
    if (moved >= available) {
      quantities.remove(source);
    } else {
      quantities[source] = available - moved;
    }

    final target = (oracleId, toPrintId);
    quantities[target] = (quantities[target] ?? 0) + moved;
    return quantities[target]!;
  }

  @override
  Future<List<CollectionEntry>> page({
    String? query,
    CollectionSort sort = CollectionSort.name,
    int offset = 0,
    int limit = collectionPageSize,
    Game game = Game.magic,
    bool unspecifiedOnly = false,
    bool? descending,
    FinishFilter finish = FinishFilter.all,
    bool? fullArt,
  }) async {
    lastQuery = query;
    lastSort = sort;
    lastOffset = offset;
    lastUnspecifiedOnly = unspecifiedOnly;
    lastDescending = descending;
    lastFinish = finish;
    lastFullArt = fullArt;
    // Le filtre est appliqué par le serveur : le reproduire ici permet
    // d'observer une liste vide quand rien n'est a preciser, comme en vrai.
    final shown = unspecifiedOnly
        ? entries.where((e) => !e.hasPrinting).toList(growable: false)
        : entries;
    if (offset >= shown.length) return const [];
    return shown.sublist(offset, (offset + limit).clamp(0, shown.length));
  }

  @override
  Future<CollectionSummary> summary({Game game = Game.magic}) async => totals;
}

/// Faux dépôt d'éditions, pour les écrans qui ouvrent le sélecteur.
class FakePrintingRepository implements PrintingRepository {
  List<CardPrinting> printings = const [];
  String? lastQuery;

  /// Carte dont les editions ont ete demandees en dernier.
  ///
  /// Retenue parce qu'un apercu d'illustration qui ouvrirait la bonne fenetre
  /// sur la mauvaise carte serait indetectable a l'ecran : l'image est
  /// plausible dans les deux cas.
  String? lastOracleId;
  String? lastLang;

  @override
  Future<List<CardPrinting>> forCard(
    String oracleId, {
    String? query,
    int limit = 60,
    String? lang,
  }) async {
    lastQuery = query;
    lastOracleId = oracleId;
    lastLang = lang;
    if (query == null || query.isEmpty) return printings;
    final needle = query.toLowerCase();
    return printings
        .where(
          (p) =>
              (p.setName ?? '').toLowerCase().contains(needle) ||
              p.setCode.toLowerCase().startsWith(needle),
        )
        .toList(growable: false);
  }

  /// Editions uniques, par oracle. Ce que le catalogue repondrait pour les
  /// cartes qui n'en ont qu'une ; les autres sont simplement absentes.
  Map<String, CardPrinting> sole = const {};

  /// Cartes pour lesquelles l'edition unique a ete demandee, dans l'ordre.
  final List<String> soleAsked = [];

  /// Erreur a lever a la place de la reponse.
  Object? soleError;

  @override
  Future<Map<String, CardPrinting>> soleEditions(
    Iterable<String> oracleIds, {
    String? lang,
  }) async {
    soleAsked.addAll(oracleIds);
    lastLang = lang;
    if (soleError != null) throw soleError!;
    return {
      for (final id in oracleIds)
        if (sole[id] != null) id: sole[id]!,
    };
  }
}
