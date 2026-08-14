/// Tests du constructeur sur les axes de Pokémon.
///
/// **Ce qui est vérifié est ce qui a failli être faux.** Comme Yu-Gi-Oh avant
/// lui, ce jeu n'a aucune des notions sur lesquelles le constructeur a été bâti :
/// ni terrain, ni créature, ni contrainte de couleur, ni coût de mana. Il en a
/// une de plus qui trompe — `cmc` y porte les **points de vie**, mesuré : 70, 60
/// et 80 sont les valeurs les plus fréquentes du catalogue. Lire une courbe
/// dessus décrirait la robustesse des créatures, pas une contrainte.
///
/// Les proportions attendues viennent de `deck_anatomy --game pokemon`, mesurées
/// sur **17 295 decks Standard** : 60 cartes exactement (écart interquartile
/// 0,0), Dresseurs 51,7 %, Pokémon 33,3 %, Énergies 15,0 %.
library;

import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/builder/domain/deck_builder.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:flutter_test/flutter_test.dart';

/// Une carte Pokémon. `cmc` y porte les **points de vie**, comme l'ingestion les
/// range faute d'un champ dédié.
BuildableCard pkmn({
  required String name,
  String type = 'Pokemon — Basic Water',
  double hp = 70,
  int quantity = 4,
}) => BuildableCard(
  game: 'pokemon',
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: hp,
  colorIdentity: const {'Water'},
  quantity: quantity,
);

/// Une collection assez fournie pour bâtir, aux proportions du corpus.
List<BuildableCard> collection({int count = 60}) => [
  for (var i = 0; i < count; i++)
    pkmn(
      name: 'Carte ${i.toString().padLeft(3, '0')}',
      type: switch (i % 6) {
        0 || 1 => 'Trainer — Item',
        2 => 'Trainer — Supporter',
        3 => 'Trainer — Stadium',
        4 => 'Energy — Basic',
        _ => 'Pokemon — Basic Water',
      },
    ),
];

void main() {
  final blueprint = DeckBlueprint.of(DeckFormat.standard)!;
  final builder = DeckBuilder(blueprint: blueprint);

  group('le gabarit décrit ce jeu et pas un autre', () {
    test('le format Standard a un gabarit, il n_est plus nul', () {
      expect(DeckBlueprint.of(DeckFormat.standard), isNotNull);
    });

    test('un deck fait soixante cartes, sans exception mesurée', () {
      // L'écart interquartile est de 0,0 sur les 17 295 decks : c'est le chiffre
      // le plus net du corpus, tous jeux confondus.
      expect(blueprint.size, 60);
    });

    test('quatre exemplaires, la règle du jeu et le maximum observé', () {
      expect(blueprint.maxCopies, 4);
    });

    test('aucune notion de terrain, et ce n_est pas un quota à zéro', () {
      // `null` dit « cette notion n'existe pas » ; un zéro se lirait comme un
      // manque, et l'écran annoncerait qu'il manque des terrains à un jeu qui
      // n'en a jamais eu.
      expect(blueprint.lands, isNull);
    });

    test('aucune contrainte de couleur', () {
      // Les types (Feu, Eau…) n'interdisent aucun mélange. Filtrer dessus
      // écarterait le catalogue sur une règle qui n'existe pas — la faute
      // exacte que Yu-Gi-Oh avait payée à 32 % du sien.
      expect(blueprint.usesColorIdentity, isFalse);
    });

    test('aucune courbe, parce que cmc porte les points de vie', () {
      expect(blueprint.curve, isEmpty);
    });

    test('aucun général : ce jeu n_en a pas', () {
      expect(blueprint.needsCommander, isFalse);
    });
  });

  group('les rôles sont ceux du jeu', () {
    test('les trois familles se lisent dans le type imprimé', () {
      expect(
        rolesOf(pkmn(name: 'A', type: 'Pokemon — Basic Water')),
        contains(CardRole.pokemon),
      );
      expect(
        rolesOf(pkmn(name: 'B', type: 'Trainer — Supporter')),
        contains(CardRole.trainer),
      );
      expect(
        rolesOf(pkmn(name: 'C', type: 'Energy — Basic')),
        contains(CardRole.energy),
      );
    });

    test('une sous-famille Dresseur reste un Dresseur', () {
      // Le recouvrement est volontaire, comme la créature Magic qui produit du
      // mana : un Supporter compte dans les deux quotas.
      final roles = rolesOf(pkmn(name: 'D', type: 'Trainer — Supporter'));
      expect(roles, containsAll([CardRole.trainer, CardRole.supporter]));
    });

    test('les rôles de Magic et de Yu-Gi-Oh ne s_y invitent pas', () {
      final roles = rolesOf(pkmn(name: 'E', type: 'Pokemon — Basic Water'));
      expect(roles, isNot(contains(CardRole.creature)));
      expect(roles, isNot(contains(CardRole.land)));
      expect(roles, isNot(contains(CardRole.monster)));
    });

    test('l_écran ne propose que les rôles de ce jeu', () {
      final affiches = rolesFor('pokemon');
      expect(affiches, contains(CardRole.pokemon));
      expect(affiches, isNot(contains(CardRole.creature)));
      expect(affiches, isNot(contains(CardRole.land)));
    });
  });

  group('le constructeur bâtit', () {
    test('un deck complet de soixante cartes', () {
      final deck = builder.build(collection(count: 80));

      expect(deck.size, 60);
      expect(deck.diagnosis.isComplete, isTrue);
    });

    test('aucun terrain de base n_est ajouté', () {
      // Le complément par terrains de base est propre à Magic ; ici, les 60
      // cartes viennent toutes de la collection.
      final deck = builder.build(collection(count: 80));

      expect(deck.basicLands, isEmpty);
      expect(deck.lands, isEmpty);
    });

    test('une collection trop maigre le dit au lieu de compléter', () {
      final deck = builder.build(collection(count: 5));

      expect(deck.diagnosis.isComplete, isFalse);
      expect(deck.diagnosis.short, greaterThan(0));
    });

    test('la seconde zone reste vide : ce jeu n_en a pas', () {
      // L'Extra Deck est propre à Yu-Gi-Oh. Une zone vide affichée ici se
      // lirait comme un manque.
      expect(blueprint.extraSize, isNull);
      expect(builder.build(collection(count: 80)).extra, isEmpty);
    });
  });
}
