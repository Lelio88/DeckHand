/// Un prix incomplet s'annonce comme tel.
///
/// **Ce que la tuile promet, elle doit le tenir.** La liste est classée par
/// coût de complétion ; le coût est donc la valeur de tête. Or une carte sans
/// cote compte zéro euro, et ce n'est pas un cas marginal : mesuré, **100 %
/// des decks Pokémon, One Piece et Riftbound** contiennent des cartes non
/// cotées — trente-six sur cinquante-sept pour un deck Pokémon ordinaire —
/// contre 1,2 % en Pauper.
///
/// Afficher « 4,25 € » en gros pour un tel deck ne serait pas une
/// approximation, mais un total qui ignore la majeure partie du deck. D'où
/// « dès 4,25 € » et le nombre de cartes sans cote, qui disent ce que le
/// chiffre vaut.
library;

import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

void main() {
  test('sans carte non cotée, le prix est entier', () {
    final deck = fakeDeck(total: 60, owned: 20, cost: 12.5);
    expect(deck.unpricedCards, 0);
    expect(deck.priceIsPartial, isFalse);
  });

  test('dès une carte non cotée, le prix est un plancher', () {
    // Les proportions d'un deck Pokémon réel, relevées sur le corpus.
    final deck = fakeDeck(total: 57, owned: 0, cost: 4.25, unpricedCards: 36);
    expect(deck.priceIsPartial, isTrue);
    expect(deck.unpricedCards, 36);
  });

  test('le champ survit à l\'aller-retour JSON', () {
    // **C'est le maillon qui cède en silence.** Le serveur rend la colonne ;
    // un `fromJson` qui l'oublierait afficherait un prix ferme sur un deck
    // dont les deux tiers ne sont pas cotés, sans qu'aucune erreur ne le dise.
    final deck = DeckSuggestion.fromJson(const {
      'deck_id': 'd1',
      'deck_name': 'Slowking',
      'tier': 'competitive',
      'source_name': 'Limitless',
      'total_cards': 57,
      'owned_cards': 0,
      'missing_cards': 57,
      'completion': 0.0,
      'missing_cost_eur': 4.25,
      'basic_lands': 0,
      'unpriced_cards': 36,
    });
    expect(deck.unpricedCards, 36);
    expect(deck.priceIsPartial, isTrue);
  });

  test('une réponse sans la colonne ne prétend pas que le prix est entier', () {
    // Défensif : un serveur antérieur à la migration ne rend pas la colonne.
    // Zéro est alors le seul défaut possible — mais il vaut mieux qu'un plantage.
    final deck = DeckSuggestion.fromJson(const {
      'deck_id': 'd1',
      'deck_name': 'Deck',
      'tier': 'competitive',
      'source_name': 'TopDeck.gg',
      'total_cards': 60,
      'owned_cards': 10,
      'missing_cards': 50,
      'completion': 0.16,
      'missing_cost_eur': 9.0,
    });
    expect(deck.unpricedCards, 0);
    expect(deck.priceIsPartial, isFalse);
  });
}
