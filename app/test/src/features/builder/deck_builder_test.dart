/// Tests du constructeur de decks.
///
/// **Ce qu'ils vérifient est ce que le constructeur promet.** Il ne promet pas
/// un deck optimal — cela ne se démontre pas — mais un deck légal, cohérent avec
/// les proportions des decks réels, et bâti sur la seule collection. Ces trois
/// promesses-là se vérifient, et c'est tout l'objet de ce fichier.
///
/// Les proportions attendues viennent de `api/app/measure/deck_anatomy.py`,
/// mesurées sur les 190 précons Commander du corpus : 38 terrains, 29 créatures,
/// 12 cartes de pioche, 6 de rampe, 6 de retrait.
library;

import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/builder/domain/deck_builder.dart';
import 'package:flutter_test/flutter_test.dart';

BuildableCard card({
  required String name,
  String type = 'Creature — Human',
  double cmc = 3,
  Set<String> colors = const {'B'},
  String text = '',
}) => BuildableCard(
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: cmc,
  colorIdentity: colors,
  oracleText: text,
);

/// Une collection assez fournie pour remplir un deck, faite de cartes neutres.
///
/// Les rôles y sont volontairement rares : c'est ainsi qu'on voit si le
/// constructeur va les chercher plutôt que de remplir au hasard.
List<BuildableCard> plainCollection(
  int count, {
  Set<String> colors = const {'B'},
}) => [
  for (var i = 0; i < count; i++)
    card(name: 'Carte ${i.toString().padLeft(3, '0')}', colors: colors),
];

void main() {
  const builder = DeckBuilder();
  final general = card(
    name: 'Général',
    type: 'Legendary Creature — Human Noble',
    colors: {'B'},
  );

  group('choisir un général', () {
    test('seules les créatures légendaires sont candidates', () {
      final commanders = builder.commanders([
        general,
        card(name: 'Ordinaire'),
        card(name: 'Terrain', type: 'Land'),
      ]);

      expect(commanders.map((c) => c.name), ['Général']);
    });

    test('celui qui ouvre le plus de cartes vient en tête', () {
      // La seule mesure objective sans comprendre les synergies : un général
      // bicolore donne accès à plus de cartes qu'un mono-couleur.
      final mono = card(
        name: 'Mono',
        type: 'Legendary Creature — Human',
        colors: {'B'},
      );
      final dual = card(
        name: 'Bicolore',
        type: 'Legendary Creature — Human',
        colors: {'B', 'R'},
      );

      final commanders = builder.commanders([
        mono,
        dual,
        ...plainCollection(5, colors: {'B'}),
        ...plainCollection(5, colors: {'R'}),
      ]);

      expect(commanders.first.name, 'Bicolore');
    });
  });

  group('construire', () {
    test('le deck fait cent cartes, général compris', () {
      final deck = builder.build([general, ...plainCollection(80)], general);

      expect(deck.size, 100);
      expect(deck.diagnosis.isComplete, isTrue);
    });

    test('les terrains suivent la proportion mesurée du corpus', () {
      // 38 %, le trait le plus régulier des 190 précons — écart interquartile
      // de deux points seulement.
      final deck = builder.build([general, ...plainCollection(80)], general);

      expect(deck.lands.length + deck.basicCount, 38);
    });

    test('le général ne se retrouve pas dans son propre deck', () {
      final deck = builder.build([general, ...plainCollection(80)], general);

      expect(
        deck.spells.map((c) => c.oracleId),
        isNot(contains(general.oracleId)),
      );
    });

    test("aucune carte hors de l'identité du général", () {
      // La règle du Commander, et la seule que le constructeur ne peut pas
      // assouplir : un deck illégal n'est pas un deck.
      final deck = builder.build([
        general,
        ...plainCollection(60, colors: {'B'}),
        ...plainCollection(20, colors: {'R'}),
      ], general);

      for (final spell in deck.spells) {
        expect(spell.colorIdentity, isNot(contains('R')), reason: spell.name);
      }
    });

    test('les cartes incolores entrent dans tous les decks', () {
      final deck = builder.build([
        general,
        ...plainCollection(30, colors: {'B'}),
        ...plainCollection(40, colors: const {}),
      ], general);

      expect(deck.spells.where((c) => c.colorIdentity.isEmpty), isNotEmpty);
    });

    test('deux constructions identiques rendent le même deck', () {
      // Sans départage stable, deux appels sur la même collection donneraient
      // deux decks différents — et l'utilisateur ne saurait plus lequel il a
      // noté.
      final collection = [general, ...plainCollection(80)];
      final first = builder.build(collection, general);
      final second = builder.build(collection, general);

      expect(first.spells.map((c) => c.name), second.spells.map((c) => c.name));
    });
  });

  group('remplir les rôles', () {
    test(
      'le constructeur va chercher le retrait plutôt que du remplissage',
      () {
        // Six cartes de retrait sont visées ; la collection en contient
        // exactement six, noyées dans du neutre. Les rater signerait un
        // remplissage aveugle.
        final removals = [
          for (var i = 0; i < 6; i++)
            card(name: 'Retrait $i', text: 'Destroy target creature.'),
        ];
        final deck = builder.build([
          general,
          ...plainCollection(80),
          ...removals,
        ], general);

        final chosen = deck.spells
            .where((c) => rolesOf(c).contains(CardRole.removal))
            .length;
        expect(chosen, 6);
      },
    );

    test('la pioche et la rampe sont cherchées aussi', () {
      final draws = [
        for (var i = 0; i < 12; i++)
          card(name: 'Pioche $i', text: 'Draw a card.'),
      ];
      final ramps = [
        for (var i = 0; i < 6; i++) card(name: 'Rampe $i', text: 'Add {B}{B}.'),
      ];
      final deck = builder.build([
        general,
        ...plainCollection(80),
        ...draws,
        ...ramps,
      ], general);

      final roles = deck.spells.map(rolesOf).toList();
      expect(roles.where((r) => r.contains(CardRole.draw)).length, 12);
      expect(roles.where((r) => r.contains(CardRole.ramp)).length, 6);
    });

    test('un manque est annoncé, pas dissimulé', () {
      // C'est ce qui distingue un outil d'un oracle : une collection sans
      // retrait produit un deck sans retrait, et le dit.
      final deck = builder.build([general, ...plainCollection(80)], general);

      expect(deck.diagnosis.roleGaps[CardRole.removal], 6);
      expect(
        deck.diagnosis.notable.map((e) => e.key),
        contains(CardRole.removal),
      );
    });
  });

  group('les terrains de base', () {
    test('ils complètent ce que la collection ne fournit pas', () {
      // On ne les achète pas, on les prend dans la boîte : c'est leur seule
      // vertu ici, et elle suffit à combler trente-huit places.
      final deck = builder.build([general, ...plainCollection(80)], general);

      expect(deck.basicLands, {'Swamp': 38});
    });

    test('ils suivent les couleurs réellement jouées', () {
      final dual = card(
        name: 'Général bicolore',
        type: 'Legendary Creature — Human',
        colors: {'B', 'R'},
      );
      final deck = builder.build([
        dual,
        ...plainCollection(70, colors: {'B'}),
        ...plainCollection(10, colors: {'R'}),
      ], dual);

      expect(
        deck.basicLands['Swamp']!,
        greaterThan(deck.basicLands['Mountain']!),
      );
      expect(deck.basicCount, 38);
    });

    test('une couleur du général garde un terrain même sans carte', () {
      // Le général la réclame, quand bien même aucun sort ne l'emploie.
      final dual = card(
        name: 'Général bicolore',
        type: 'Legendary Creature — Human',
        colors: {'B', 'R'},
      );
      final deck = builder.build([
        dual,
        ...plainCollection(80, colors: {'B'}),
      ], dual);

      expect(deck.basicLands['Mountain'], greaterThan(0));
    });

    test('les terrains spéciaux de la collection passent avant', () {
      final specials = [
        for (var i = 0; i < 5; i++)
          card(name: 'Terrain $i', type: 'Land', cmc: 0, colors: const {}),
      ];
      final deck = builder.build([
        general,
        ...plainCollection(80),
        ...specials,
      ], general);

      expect(deck.lands.length, 5);
      expect(deck.basicCount, 33);
    });
  });

  group('les formats sans général', () {
    // Pauper et Modern se jouent à soixante cartes, jusqu'à quatre exemplaires
    // de chacune, et sans général pour imposer les couleurs.
    const pauper = DeckBuilder(blueprint: DeckBlueprint.pauper);

    test('le deck fait soixante cartes', () {
      final deck = pauper.build(plainCollection(60));

      expect(deck.size, 60);
      expect(deck.commander, isNull);
    });

    test('les couleurs se déduisent de la collection', () {
      // Sans général, personne ne les impose : les deux mieux fournies
      // l'emportent, parce qu'un deck qui touche à tout ne produit jamais le
      // mana qu'il lui faut.
      final colors = pauper.dominantColors([
        ...plainCollection(30, colors: {'B'}),
        ...plainCollection(20, colors: {'R'}),
        ...plainCollection(5, colors: {'G'}),
      ]);

      expect(colors, {'B', 'R'});
    });

    test("les exemplaires possédés sont joués jusqu'à quatre", () {
      // Jouer quatre exemplaires d'une bonne carte rend un deck régulier d'une
      // partie à l'autre : c'est souhaitable, pas un pis-aller.
      final deck = pauper.build([
        BuildableCard(
          oracleId: 'unique',
          name: 'Foudre',
          typeLine: 'Instant',
          cmc: 1,
          colorIdentity: const {'B'},
          quantity: 9,
        ),
      ]);

      expect(deck.spells.length, 4);
    });

    test('le gabarit de Commander reste singleton', () {
      const commander = DeckBuilder();
      final deck = commander.build([
        card(name: 'Général', type: 'Legendary Creature — Human'),
        BuildableCard(
          oracleId: 'unique',
          name: 'Foudre',
          typeLine: 'Instant',
          cmc: 1,
          colorIdentity: const {'B'},
          quantity: 9,
        ),
      ], card(name: 'Général', type: 'Legendary Creature — Human'));

      expect(deck.spells.length, 1);
    });

    test('les gabarits moyennés se signalent comme tels', () {
      // 725 decks Pauper mêlent aggro, contrôle et combo : leur médiane décrit
      // un deck qui n'existe nulle part, et l'interface doit pouvoir le dire.
      expect(DeckBlueprint.commander.reliability, BlueprintReliability.tight);
      expect(DeckBlueprint.pauper.reliability, BlueprintReliability.averaged);
      expect(DeckBlueprint.modern.reliability, BlueprintReliability.averaged);
    });
  });

  group('une collection trop maigre', () {
    test('rend un deck incomplet qui le dit', () {
      // Trois cartes ne font pas un deck. Le constructeur ne doit ni inventer
      // ni échouer : il rend ce qu'il peut et annonce ce qui manque.
      final deck = builder.build([general, ...plainCollection(3)], general);

      expect(deck.size, lessThan(100));
      expect(deck.diagnosis.isComplete, isFalse);
      expect(deck.diagnosis.short, 100 - deck.size);
    });

    test('un général sans aucune autre carte ne fait pas planter', () {
      final deck = builder.build([general], general);

      expect(deck.spells, isEmpty);
      expect(deck.commander?.name, 'Général');
    });
  });
}
