/// Doublures de test, écrites à la main plutôt que générées.
///
/// Un fake enregistre ce qu'on lui demande et rend ce qu'on lui a préparé. Cela
/// permet d'affirmer sur un **état final** — « le dépôt a bien reçu ces
/// filtres » — plutôt que sur une séquence d'appels, assertion fragile qui casse
/// au moindre remaniement.
library;

import 'package:deckhand/src/features/collection/data/collection_repository.dart';
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

class FakeCollectionRepository implements CollectionRepository {
  final Map<String, int> quantities = {};
  CollectionSummary summary = const CollectionSummary(entries: []);

  @override
  Future<int> add(String oracleId, {int quantity = 1}) async {
    quantities[oracleId] = (quantities[oracleId] ?? 0) + quantity;
    return quantities[oracleId]!;
  }

  @override
  Future<int> remove(String oracleId, {int quantity = 1}) async {
    final left = (quantities[oracleId] ?? 0) - quantity;
    if (left <= 0) {
      quantities.remove(oracleId);
      return 0;
    }
    quantities[oracleId] = left;
    return left;
  }

  @override
  Future<CollectionSummary> load() async => summary;
}
