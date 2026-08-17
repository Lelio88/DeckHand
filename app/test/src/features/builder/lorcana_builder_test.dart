/// Tests du constructeur sur les axes de Disney Lorcana.
///
/// **Ce jeu apporte deux choses qu'aucun des sept autres n'avait.**
///
/// La première est une contrainte de couleur exprimée en **cardinal** : les 124
/// decks du corpus jouent *exactement* deux encres, ni plus ni moins. One Piece
/// tient à 100 % sur une inclusion — toute carte dans l'identité du leader —,
/// ici c'est un compte, et le corpus ne s'en écarte jamais.
///
/// La seconde est un rôle qui **recouvre** un autre au lieu de le découper : la
/// Chanson est une Action, sa ligne de type valant « Action Song », et elle
/// compte dans les deux familles. C'est l'inverse du partitionnement strict de
/// SWU et One Piece, et le même recouvrement volontaire que chez Magic.
///
/// Les proportions viennent de `app.measure.deck_anatomy --game lorcana`,
/// mesurées sur **124 listes** — le plus petit corpus du projet, ce que les
/// écarts interquartiles traduisent fidèlement.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:flutter_test/flutter_test.dart';

BuildableCard lorcana({
  required String name,
  String type = 'Character — Storyborn, Hero',
  double cost = 4,
  Set<String> inks = const {'Amber'},
  int quantity = 4,
}) => BuildableCard(
  game: 'lorcana',
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: cost,
  colorIdentity: inks,
  quantity: quantity,
);

void main() {
  group('les rôles sont lus sur le type imprimé', () {
    test('les quatre familles se reconnaissent', () {
      expect(rolesOf(lorcana(name: 'A', type: 'Character — Hero')), {
        CardRole.character,
      });
      expect(rolesOf(lorcana(name: 'B', type: 'Action')), {CardRole.action});
      expect(rolesOf(lorcana(name: 'C', type: 'Item')), {CardRole.item});
      expect(rolesOf(lorcana(name: 'D', type: 'Location')), {CardRole.location});
    });

    test('la Chanson compte comme Action ET comme Chanson', () {
      // Sa ligne de type vaut « Action Song ». La compter uniquement comme
      // Chanson découperait les Actions en deux et ferait annoncer un manque
      // d'Actions à qui joue des Chansons.
      expect(rolesOf(lorcana(name: 'E', type: 'Action Song')), {
        CardRole.action,
        CardRole.song,
      });
    });

    test('une Action ordinaire n_est pas une Chanson', () {
      expect(rolesOf(lorcana(name: 'F', type: 'Action')), isNot(contains(CardRole.song)));
    });

    test('les rôles affichés sont ceux de ce jeu, et eux seuls', () {
      expect(rolesFor('lorcana'), {
        CardRole.character,
        CardRole.action,
        CardRole.item,
        CardRole.song,
        CardRole.location,
      });
    });

    test('deux rôles sont partagés avec d_autres jeux, et non redéclarés', () {
      // « Character » chez One Piece, « Objet » chez Pokémon. Deux membres pour
      // la même notion feraient deux quotas là où le jeu en dose un.
      expect(rolesFor('onepiece').contains(CardRole.character), isTrue);
      expect(rolesFor('pokemon').contains(CardRole.item), isTrue);
    });
  });

  group('le gabarit', () {
    final gabarit = DeckBlueprint.of(DeckFormat.lorcanaCore)!;

    test('la taille est un contrat, pas une médiane', () {
      // 60 cartes, écart interquartile 0 — la même figure que Pokémon.
      expect(gabarit.size, 60);
    });

    test('le plafond est celui de la règle, et le corpus ne le dépasse jamais', () {
      // Maximum observé 4 sur 124 listes : le seul corpus du projet sans une
      // seule saisie fautive au-dessus du plafond.
      expect(gabarit.maxCopies, 4);
    });

    test('aucune carte de commandement', () {
      // Contrairement à SWU, One Piece et Commander. Un deck Lorcana n'a ni
      // leader ni général : soixante cartes et deux encres.
      expect(gabarit.needsCommander, isFalse);
    });

    test('aucun terrain — et null, pas zéro', () {
      expect(gabarit.lands, isNull);
    });

    test('les encres contraignent réellement', () {
      // 124 decks sur 124 jouent exactement deux encres.
      expect(gabarit.usesColorIdentity, isTrue);
    });

    test('les cinq rôles sont dosés, Chanson comprise', () {
      expect(gabarit.roles.keys, containsAll([
        CardRole.character,
        CardRole.action,
        CardRole.song,
        CardRole.item,
        CardRole.location,
      ]));
    });

    test('la somme des parts dépasse cent, et c_est correct', () {
      // La Chanson recouvre l'Action au lieu de la découper. Une somme à 100
      // signalerait au contraire que le recouvrement a été perdu.
      final somme = gabarit.roles.values.fold<double>(0, (a, q) => a + q.share);
      expect(somme, greaterThan(100));
    });

    test('la courbe est plate, et c_est le jeu qui l_est', () {
      // De 13,3 % à 20,0 % sur les cinq premiers paliers : on joue une carte
      // par tour du début à la fin. Aucun palier ne domine.
      final cinq = gabarit.curve.take(5).map((s) => s.quota.share).toList();
      expect(cinq.reduce((a, b) => a > b ? a : b), lessThan(21));
      expect(cinq.reduce((a, b) => a < b ? a : b), greaterThan(12));
    });

    test('la courbe est étiquetée dans le vocabulaire du jeu', () {
      expect(gabarit.curveLabel, 'encre');
    });
  });

  group('les formats', () {
    test('Lorcana n_en propose qu_un', () {
      expect(deckFormatsFor(Game.lorcana), [DeckFormat.lorcanaCore]);
    });

    test('son identifiant lui est propre', () {
      expect(DeckFormat.lorcanaCore.id, 'lorcana_core');
    });
  });

  group('les cadres de carte', () {
    test('deux cadres, et un seul est couché', () {
      final cadres = CardFrame.values.where((f) => f.game == 'lorcana').toList();
      expect(cadres.length, 2);
      expect(cadres.where((f) => f.landscape).length, 1);
    });

    test('Lorcana imprime au format de Magic', () {
      expect(Game.lorcana.aspect, closeTo(63 / 88, 0.0001));
    });

    test('le cadre couché est celui des Lieux', () {
      // 106 cartes, exactement celles que la source déclare `landscape` —
      // vérifié carte par carte au banc de taxonomie.
      final couche = CardFrame.values.firstWhere(
        (f) => f.game == 'lorcana' && f.landscape,
      );
      expect(couche, CardFrame.lorcanaLocation);
    });

    test('la fenêtre couchée est plus large que haute', () {
      // Elle s'exprime dans le repère redressé — la carte telle qu'elle est
      // posée sur la table, après le quart de tour horaire que l'index
      // applique. Une fenêtre plus haute que large signalerait qu'on a mesuré
      // sur le rendu portrait publié par la source, sans le redresser : c'est
      // précisément le défaut qui a rendu une paire à 1 bit.
      final box = CardFrame.lorcanaLocation.box;
      expect(box.right - box.left, greaterThan(box.bottom - box.top));
    });
  });
}
