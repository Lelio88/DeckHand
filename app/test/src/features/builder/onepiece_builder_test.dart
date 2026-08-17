/// Tests du constructeur sur les axes de One Piece.
///
/// **Ce jeu rend le chiffre de contrainte de couleur le plus net du projet.**
/// SWU tient à 79,1 %, Yu-Gi-Oh à zéro — son Attribut ressemblait à une
/// identité de couleur sans rien imposer. Ici, **100 % des 2 033 decks tiennent
/// entièrement dans l'identité de leur leader**, médiane et maximum à 0 % hors
/// identité. C'est une règle dure, et le corpus ne la viole jamais.
///
/// Ce 100 % a d'abord valu 36,5 %, et c'est ainsi qu'un défaut d'ingestion est
/// apparu : la source sépare ses couleurs par un espace, le connecteur découpait
/// sur une barre oblique, et 66 cartes bicolores entraient sous une couleur
/// unique nommée « Blue Green ». Le test `un deck bicolore accepte ses deux
/// couleurs` verrouille le point.
///
/// Les proportions viennent de `app.measure.deck_anatomy --game onepiece`,
/// mesurées sur **1 490 listes** : personnages 84,0 %, événements 14,0 %,
/// décors 0,0 %, pour un deck principal de 50 cartes à écart interquartile nul.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:flutter_test/flutter_test.dart';

BuildableCard op({
  required String name,
  String type = 'Character — Straw Hat Crew',
  double cost = 4,
  Set<String> colors = const {'Red'},
  int quantity = 4,
}) => BuildableCard(
  game: 'onepiece',
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: cost,
  colorIdentity: colors,
  quantity: quantity,
);

void main() {
  group('les rôles sont lus sur le type imprimé', () {
    test('les trois familles du deck principal se reconnaissent', () {
      expect(rolesOf(op(name: 'A', type: 'Character — Navy')), {
        CardRole.character,
      });
      expect(rolesOf(op(name: 'B', type: 'Event')), {CardRole.event});
      expect(rolesOf(op(name: 'C', type: 'Stage — Blackbeard Pirates')), {
        CardRole.stage,
      });
    });

    test('elles partitionnent : une carte ne tient jamais deux rôles', () {
      for (final type in ['Character — X', 'Event', 'Stage — Y']) {
        expect(rolesOf(op(name: type, type: type)).length, 1);
      }
    });

    test('le leader n_est pas dosé', () {
      // Exactement un par deck, hors du compte des cinquante cartes : il occupe
      // `commander_oracle_id`, comme celui de SWU et la Légende de Riftbound.
      // Lui donner un rôle le ferait entrer dans les quotas et fausserait la
      // part des personnages.
      expect(rolesOf(op(name: 'L', type: 'Leader — Whitebeard Pirates')), isEmpty);
    });

    test('les rôles affichés sont ceux de ce jeu, et eux seuls', () {
      expect(rolesFor('onepiece'), {
        CardRole.character,
        CardRole.event,
        CardRole.stage,
      });
    });

    test('l_événement est partagé avec SWU, et c_est voulu', () {
      // Les deux jeux nomment ainsi une carte à effet unique qu'on joue puis
      // défausse. Deux membres pour la même notion n'apporteraient rien.
      expect(rolesFor('swu').contains(CardRole.event), isTrue);
      expect(rolesFor('onepiece').contains(CardRole.event), isTrue);
    });
  });

  group('le gabarit', () {
    final gabarit = DeckBlueprint.of(DeckFormat.opStandard)!;

    test('la taille est un contrat, pas une médiane', () {
      // 50 cartes, écart interquartile 0 sur 1 490 listes — la même figure
      // exacte que Pokémon à 60.
      expect(gabarit.size, 50);
    });

    test('le plafond est celui de la règle', () {
      expect(gabarit.maxCopies, 4);
    });

    test('un leader est requis', () {
      expect(gabarit.needsCommander, isTrue);
    });

    test('aucun terrain — et null, pas zéro', () {
      // La ressource est le DON!!, distribué automatiquement chaque tour. Il
      // n'y a rien à manquer : `Quota(0, 0)` ferait annoncer « il manque 0
      // terrain » sur un écran où le mot n'a aucun sens.
      expect(gabarit.lands, isNull);
    });

    test('les couleurs contraignent réellement', () {
      // Le chiffre le plus net du projet sur ce point : 100 % des decks.
      expect(gabarit.usesColorIdentity, isTrue);
    });

    test('les trois familles sont dosées, décors compris', () {
      // La médiane des décors est nulle — la moitié des decks n'en joue
      // aucun — mais le quota reste déclaré : l'autre moitié en joue jusqu'à
      // 6 %, et un rôle absent du gabarit ne serait jamais proposé.
      expect(gabarit.roles.keys, containsAll([
        CardRole.character,
        CardRole.event,
        CardRole.stage,
      ]));
      expect(gabarit.roles[CardRole.character]!.share, 84.0);
      expect(gabarit.roles[CardRole.stage]!.share, 0.0);
      expect(gabarit.roles[CardRole.stage]!.spread, greaterThan(0));
    });

    test('la courbe garde son creux à trois', () {
      // 3,5 % du corpus contre 9,5 % à 2 et 19,2 % à 4. Le creux est
      // authentique — vérifié en regardant les cartes, les coûts 1 étant les
      // personnages de recherche et les coûts 4 les finisseurs. Le lisser
      // rendrait le gabarit plus joli et moins vrai.
      final trois = gabarit.curve.firstWhere((s) => s.min == 3);
      final quatre = gabarit.curve.firstWhere((s) => s.min == 4);
      expect(trois.quota.share, lessThan(quatre.quota.share));
      expect(trois.quota.share, 0.0);
    });

    test('la courbe est étiquetée dans le vocabulaire du jeu', () {
      // « ressources » chez SWU, « DON!! » ici. Un écran qui dirait « mana »
      // parlerait d'un autre jeu.
      expect(gabarit.curveLabel, 'DON!!');
    });
  });

  group('les formats', () {
    test('One Piece n_en propose qu_un', () {
      expect(deckFormatsFor(Game.onepiece), [DeckFormat.opStandard]);
    });

    test('son identifiant est distinct de celui de Pokémon', () {
      // `DeckBlueprint.of` ne reçoit que le format, jamais le jeu : partager
      // `standard` ferait construire un deck One Piece sur les proportions
      // d'un deck Pokémon sans que rien ne l'annonce.
      expect(DeckFormat.opStandard.id, 'op_standard');
      expect(
        DeckBlueprint.of(DeckFormat.opStandard),
        isNot(DeckBlueprint.of(DeckFormat.standard)),
      );
    });
  });

  group('les proportions de la carte', () {
    test('One Piece imprime au format de Magic', () {
      // 63 × 88 mm. Les deux tailles de rendu publiées — 600 × 838 et
      // 868 × 1213 — encadrent le carton à un dix-millième.
      expect(Game.onepiece.aspect, closeTo(63 / 88, 0.0001));
    });

    test('aucune carte n_est imprimée en travers', () {
      // Contrairement à Riftbound, Wankul et SWU. Le cadre unique du jeu ne
      // déclare donc pas `landscape`, et la détection n'a pas à ouvrir
      // l'orientation couchée — ce qui reviendrait à accepter n'importe quel
      // rectangle.
      final cadres = CardFrame.values.where((f) => f.game == 'onepiece');
      expect(cadres, isNotEmpty);
      expect(cadres.every((f) => !f.landscape), isTrue);
    });
  });
}
