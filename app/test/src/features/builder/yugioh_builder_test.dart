/// Tests du constructeur sur les axes de Yu-Gi-Oh.
///
/// **Ce qui est vérifié est ce qui a failli être faux.** Le gabarit de ce jeu a
/// longtemps été `null`, non faute de mesure mais parce que le constructeur
/// était bâti sur des notions que Yu-Gi-Oh n'a pas : ni terrain, ni créature, ni
/// contrainte de couleur, ni coût de mana. Chaque cas ci-dessous ferme l'une de
/// ces portes, et les proportions attendues viennent de
/// `api/app/measure/deck_anatomy.py --game yugioh`, mesurées sur 3 935 decks.
library;

import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/builder/domain/deck_builder.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:flutter_test/flutter_test.dart';

/// Une carte Yu-Gi-Oh. `cmc` y porte le **Niveau** et `colorIdentity`
/// l'**Attribut**, comme l'ingestion les range.
BuildableCard ygo({
  required String name,
  String type = 'Effect Monster — Warrior Effect',
  double level = 4,
  Set<String> attribute = const {'DARK'},
  int quantity = 3,
}) => BuildableCard(
  game: 'yugioh',
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: level,
  colorIdentity: attribute,
  quantity: quantity,
);

List<BuildableCard> monsters(int count, {Set<String> attribute = const {'DARK'}}) => [
  for (var i = 0; i < count; i++)
    ygo(name: 'Monstre ${i.toString().padLeft(2, '0')}', attribute: attribute),
];

void main() {
  const builder = DeckBuilder(blueprint: DeckBlueprint.edison);

  group('les axes du jeu', () {
    test('les quatre formats ont un gabarit, le format Riftbound non', () {
      for (final format in [
        DeckFormat.edison,
        DeckFormat.goat,
        DeckFormat.redu,
        DeckFormat.hat,
      ]) {
        expect(DeckBlueprint.of(format), isNotNull, reason: format.name);
      }
      expect(DeckBlueprint.of(DeckFormat.constructed), isNull);
    });

    test('un deck fait 40 cartes, et l\'Extra Deck 15', () {
      expect(DeckBlueprint.edison.size, 40);
      expect(DeckBlueprint.edison.extraSize, 15);
      // Mesuré : l'Extra Deck de l'ère Goat en compte 11, et 187 decks sur 484
      // n'en ont aucun.
      expect(DeckBlueprint.goat.extraSize, 11);
    });

    test('trois exemplaires, pas quatre', () {
      expect(DeckBlueprint.edison.maxCopies, 3);
    });

    test('aucun quota de terrain, parce qu\'il n\'y a pas de terrain', () {
      // Un quota de zéro se lirait comme un manque ; `null` dit qu'il n'y a
      // rien à manquer.
      expect(DeckBlueprint.edison.lands, isNull);
      expect(DeckBlueprint.commander.lands, isNotNull);
    });
  });

  group('lire une carte', () {
    test('un monstre est un monstre, pas une créature', () {
      final roles = rolesOf(ygo(name: 'Gobelin'));
      expect(roles, contains(CardRole.monster));
      expect(roles, isNot(contains(CardRole.creature)));
    });

    test('les trois familles se partagent le deck, sans se recouvrir', () {
      expect(
        rolesOf(ygo(name: 'Pot', type: 'Normal Spell — Spell Card')),
        {CardRole.spell},
      );
      expect(
        rolesOf(ygo(name: 'Miroir', type: 'Normal Trap — Trap Card')),
        {CardRole.trap},
      );
    });

    test('les sous-familles sont imprimées, pas devinées', () {
      // Là où Magic doit chercher « Destroy target » dans le texte oracle,
      // Yu-Gi-Oh imprime le rôle dans le type.
      expect(
        rolesOf(ygo(name: 'Éclair', type: 'Quick-Play Spell — Spell Card')),
        {CardRole.spell, CardRole.quickSpell},
      );
      expect(
        rolesOf(ygo(name: 'Mur', type: 'Continuous Trap — Trap Card')),
        {CardRole.trap, CardRole.continuousTrap},
      );
    });

    test('une carte d\'Extra Deck ne compte pas dans les quotas du principal', () {
      final fusion = ygo(name: 'Dragon', type: 'Fusion Monster — Dragon Fusion');
      expect(fusion.isExtraDeck, isTrue);
      // Sinon la part des monstres du deck principal serait fausse de moitié.
      expect(rolesOf(fusion), isNot(contains(CardRole.monster)));
    });

    test('les rôles affichés sont ceux du jeu', () {
      expect(rolesFor('yugioh'), contains(CardRole.monster));
      expect(rolesFor('yugioh'), isNot(contains(CardRole.creature)));
      expect(rolesFor('magic'), contains(CardRole.creature));
    });
  });

  group('construire', () {
    test('le deck principal fait la taille du format', () {
      final deck = builder.build(monsters(60));
      expect(deck.size, 40);
      expect(deck.diagnosis.isComplete, isTrue);
    });

    test('aucun terrain de base n\'est ajouté', () {
      // Ils n'existent pas dans ce jeu ; en inventer remplirait le deck de
      // cartes que personne ne possède.
      final deck = builder.build(monsters(60));
      expect(deck.basicLands, isEmpty);
      expect(deck.lands, isEmpty);
    });

    test('l\'attribut ne restreint rien', () {
      // **Le cas qui condamnait le gabarit.** Retenir les deux attributs les
      // mieux fournis écarterait un tiers du catalogue au nom d'une règle que
      // le jeu n'a pas. Six attributs, dix cartes chacun : les soixante doivent
      // rester éligibles.
      final collection = [
        for (final a in ['DARK', 'LIGHT', 'WATER', 'FIRE', 'EARTH', 'WIND'])
          ...monsters(10, attribute: {a}).map(
            (c) => ygo(name: '${c.name} $a', attribute: {a}),
          ),
      ];
      final deck = builder.build(collection);
      final attributes = {
        for (final card in deck.spells) ...card.colorIdentity,
      };
      expect(deck.size, 40);
      expect(attributes.length, greaterThan(2));
    });

    test('l\'Extra Deck se remplit dans un pool disjoint', () {
      final collection = [
        ...monsters(40),
        for (var i = 0; i < 20; i++)
          ygo(
            name: 'Fusion ${i.toString().padLeft(2, '0')}',
            type: 'Fusion Monster — Dragon Fusion',
            quantity: 1,
          ),
      ];
      final deck = builder.build(collection);
      expect(deck.extra, hasLength(15));
      expect(deck.extra.every((c) => c.isExtraDeck), isTrue);
      // Et elles ne prennent aucune place dans le deck principal.
      expect(deck.spells.any((c) => c.isExtraDeck), isFalse);
      expect(deck.size, 40);
    });

    test('un Extra Deck incomplet le dit', () {
      final collection = [
        ...monsters(40),
        ygo(name: 'Fusion', type: 'Fusion Monster — Dragon Fusion', quantity: 2),
      ];
      final deck = builder.build(collection);
      expect(deck.extra, hasLength(2));
      expect(deck.diagnosis.extraShort, 13);
    });

    test('un format sans seconde zone n\'en rend pas', () {
      const magic = DeckBuilder();
      final deck = magic.build([
        for (var i = 0; i < 200; i++)
          BuildableCard(
            oracleId: 'c$i',
            name: 'Carte $i',
            typeLine: 'Creature — Human',
            cmc: 3,
            colorIdentity: const {'B'},
          ),
      ]);
      expect(deck.extra, isEmpty);
      expect(deck.diagnosis.extraShort, 0);
    });

    test('les proportions mesurées sont visées', () {
      // Une collection qui n'offre que des monstres ne peut pas atteindre les
      // 21 % de magies du corpus : le manque doit être annoncé, pas dissimulé.
      final deck = builder.build(monsters(60));
      expect(deck.diagnosis.roleGaps[CardRole.spell], greaterThan(0));
      expect(deck.diagnosis.roleGaps[CardRole.monster], lessThanOrEqualTo(0));
    });

    test('trois exemplaires au plus d\'une même carte', () {
      final deck = builder.build([
        ygo(name: 'Unique', quantity: 40),
        ...monsters(50),
      ]);
      final copies = deck.spells.where((c) => c.name == 'Unique').length;
      expect(copies, lessThanOrEqualTo(3));
    });
  });
}
