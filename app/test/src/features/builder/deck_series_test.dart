/// Tests de la série de decks — plusieurs decks, une seule collection.
///
/// **Ce que la série promet, et qui n'est pas ce que promet un deck seul.** Un
/// deck seul promet d'être légal, cohérent et entièrement à vous. Une série
/// promet en plus que les decks sont **disjoints** : un exemplaire employé par
/// le premier ne peut pas resservir au second. C'est la seule promesse qui
/// compte ici, parce que c'est celle qu'un joueur vérifie en posant ses decks
/// côte à côte sur la table.
///
/// Elle promet aussi de **s'arrêter en disant pourquoi**. Rendre trois decks
/// quand on en demandait quatre n'est un résultat utilisable que si le quatrième
/// manque explique ce qui lui manquait.
library;

import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/builder/domain/deck_builder.dart';
import 'package:deckhand/src/features/builder/domain/deck_series.dart';
import 'package:flutter_test/flutter_test.dart';

BuildableCard card({
  required String name,
  String type = 'Creature — Human',
  double cmc = 3,
  Set<String> colors = const {'B'},
  String text = '',
  int quantity = 1,
}) => BuildableCard(
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: cmc,
  colorIdentity: colors,
  oracleText: text,
  quantity: quantity,
);

/// Une collection dont les rôles suivent les cibles du corpus Commander.
///
/// **Une collection de cartes neutres ne servirait à rien ici** : le premier
/// deck serait déjà refusé pour manque de pioche et de rampe, et l'on ne verrait
/// jamais si le second est disjoint du premier. Les proportions sont donc celles
/// que le gabarit attend, à la louche mais du bon côté.
List<BuildableCard> richCollection(int count) {
  final cards = <BuildableCard>[];
  for (var i = 0; i < count; i++) {
    final n = i.toString().padLeft(3, '0');
    final (type, text) = switch (i % 10) {
      0 || 1 => ('Instant', 'Draw a card.'),
      2 => ('Sorcery', 'Search your library for a basic land card.'),
      3 => ('Instant', 'Destroy target creature.'),
      _ => ('Creature — Human', ''),
    };
    // La courbe est étalée : un deck n'est cohérent que si tous ses paliers
    // trouvent de quoi se remplir.
    cards.add(
      card(
        name: 'Carte $n',
        type: type,
        text: text,
        cmc: (i % 6) + 1,
      ),
    );
  }
  return cards;
}

/// Tous les exemplaires qu'un deck a pris à la collection, commandant compris.
///
/// Les terrains de base n'y figurent pas : ils ne viennent pas de la collection.
List<String> consumed(BuiltDeck deck) => [
  if (deck.commander != null) deck.commander!.oracleId,
  ...deck.spells.map((c) => c.oracleId),
  ...deck.lands.map((c) => c.oracleId),
  ...deck.extra.map((c) => c.oracleId),
];

void main() {
  const series = DeckSeriesBuilder();

  BuildableCard general(String name) => card(
    name: name,
    type: 'Legendary Creature — Human Noble',
  );

  group('des decks disjoints', () {
    test('deux decks ne partagent aucun exemplaire', () {
      final result = series.build([
        general('Général A'),
        general('Général B'),
        ...richCollection(200),
      ], limit: 2);

      expect(result.decks.length, 2);
      final premier = consumed(result.decks[0]).toSet();
      final second = consumed(result.decks[1]).toSet();
      expect(premier.intersection(second), isEmpty);
    });

    test('une carte possédée en un seul exemplaire ne sert qu_une fois', () {
      final result = series.build([
        general('Général A'),
        general('Général B'),
        ...richCollection(200),
      ], limit: 3);

      final tous = result.decks.expand(consumed).toList();
      expect(tous.length, tous.toSet().length, reason: 'un doublon a servi deux fois');
    });

    test('chaque deck a son propre général', () {
      final result = series.build([
        general('Général A'),
        general('Général B'),
        ...richCollection(200),
      ], limit: 2);

      final generaux = result.decks.map((d) => d.commander?.oracleId).toList();
      expect(generaux.length, 2);
      expect(generaux.toSet().length, 2);
    });
  });

  group('savoir s_arrêter, et dire pourquoi', () {
    test('la série s_arrête au nombre demandé', () {
      final result = series.build([
        general('Général A'),
        general('Général B'),
        ...richCollection(400),
      ], limit: 2);

      expect(result.decks.length, 2);
      expect(result.stop, SeriesStop.limitReached);
      expect(result.refused, isNull);
    });

    test('une collection épuisée arrête la série sur un deck incomplet', () {
      // De quoi remplir un deck largement, deux tout juste pas.
      final result = series.build([
        general('Général A'),
        general('Général B'),
        ...richCollection(80),
      ], limit: 4);

      expect(result.decks.length, 1);
      expect(result.stop, SeriesStop.incomplete);
      // Le deck refusé est rendu : sans lui, impossible de dire à
      // l'utilisateur *ce qui* manquait au suivant.
      expect(result.refused, isNotNull);
      expect(result.refused!.diagnosis.short, greaterThan(0));
    });

    test('faute de général, la série s_arrête sans rien inventer', () {
      final result = series.build([
        general('Seul général'),
        ...richCollection(300),
      ], limit: 2);

      expect(result.decks.length, 1);
      expect(result.stop, SeriesStop.noCommander);
    });

    test('un deck trop éloigné du corpus est refusé, pas rendu', () {
      // Aucune pioche, aucune rampe, aucun retrait : le deck se remplit — les
      // terrains de base y pourvoient — mais il s'écarte du corpus bien au-delà
      // de ce que les decks réels s'autorisent.
      final result = series.build([
        general('Général A'),
        for (var i = 0; i < 200; i++)
          card(name: 'Fade $i', type: 'Artifact', cmc: (i % 6) + 1),
      ], limit: 2);

      expect(result.decks, isEmpty, reason: 'ce deck-là ne vaut pas la peine');
      expect(result.stop, SeriesStop.offBlueprint);
      expect(result.refused, isNotNull);
    });
  });

  group('les terrains de base', () {
    test('ne sont jamais décomptés de la collection', () {
      final result = series.build([
        general('Général A'),
        general('Général B'),
        ...richCollection(200),
      ], limit: 2);

      // Les deux decks ont leur base de mana : elle ne vient pas de la
      // collection, on la prend dans la boîte.
      for (final deck in result.decks) {
        expect(deck.basicCount, greaterThan(0));
      }
    });
  });

  group('la tolérance au gabarit', () {
    test('un manque dans la marge du corpus est accepté', () {
      // Créatures visées à 29 %, marge de 7 points : un deck à 25 créatures est
      // dans la bande que la moitié des decks réels occupent.
      const blueprint = DeckBlueprint.commander;
      final deck = BuiltDeck(
        spells: const [],
        lands: const [],
        basicLands: const {},
        diagnosis: DeckDiagnosis(
          roleGaps: {CardRole.creature: 4},
          short: 0,
        ),
      );
      expect(
        const DeckSeriesBuilder(
          builder: DeckBuilder(blueprint: blueprint),
        ).meetsBlueprint(deck),
        isTrue,
      );
    });

    test('un manque au-delà de la marge est refusé', () {
      const blueprint = DeckBlueprint.commander;
      final deck = BuiltDeck(
        spells: const [],
        lands: const [],
        basicLands: const {},
        diagnosis: DeckDiagnosis(
          roleGaps: {CardRole.creature: 20},
          short: 0,
        ),
      );
      expect(
        const DeckSeriesBuilder(
          builder: DeckBuilder(blueprint: blueprint),
        ).meetsBlueprint(deck),
        isFalse,
      );
    });

    test('un surplus n_est jamais un défaut', () {
      // Un deck qui a plus de créatures que la cible reste un deck cohérent :
      // le manque seul se reproche.
      final deck = BuiltDeck(
        spells: const [],
        lands: const [],
        basicLands: const {},
        diagnosis: DeckDiagnosis(
          roleGaps: {CardRole.creature: -30},
          short: 0,
        ),
      );
      expect(const DeckSeriesBuilder().meetsBlueprint(deck), isTrue);
    });
  });
}
