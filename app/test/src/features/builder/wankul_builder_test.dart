/// Tests du constructeur sur les axes de Wankul.
///
/// **C'est le premier gabarit du projet qui ne vient pas d'un corpus.** Les six
/// autres sont mesurés sur des listes de tournoi, de 124 pour Lorcana à 17 295
/// pour Pokémon. Wankul n'en a aucune, et ce n'est pas un retard d'ingestion :
/// aucune source ne publie de decklists pour ce jeu, pas plus qu'aucun index ne
/// le cote carte par carte — huit pistes vérifiées, `docs/multi-game.md` § 9.
///
/// Ce qui existe, c'est le **règlement**, publié par le wiki communautaire : 50
/// cartes, 10 terrains, 40 personnages dont cinq scoreurs au maximum, et trois
/// exemplaires par carte.
///
/// La conséquence tient en une phrase, et ces tests la verrouillent : **les
/// écarts sont nuls, et c'est exact**. « Dix terrains » n'a pas de variance.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:flutter_test/flutter_test.dart';

BuildableCard wankul({
  required String name,
  String type = 'Personnage',
  int quantity = 3,
}) => BuildableCard(
  game: 'wankul',
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: 0,
  colorIdentity: const {},
  quantity: quantity,
);

void main() {
  group('les rôles sont lus sur le type imprimé', () {
    test('les deux familles se reconnaissent', () {
      expect(rolesOf(wankul(name: 'A', type: 'Personnage')), {
        CardRole.character,
      });
      expect(rolesOf(wankul(name: 'B', type: 'Terrain')), {CardRole.land});
    });

    test('elles partitionnent : le catalogue n_a que ces deux types', () {
      // 812 Personnages et 146 Terrains, soit les 958 cartes du jeu.
      expect(rolesFor('wankul'), {CardRole.character, CardRole.land});
    });

    test('les deux rôles sont partagés avec d_autres jeux, et non redéclarés', () {
      // `character` sert aussi à One Piece et Lorcana ; `land` à Magic. Un
      // Terrain Wankul joue le rôle d'un terrain de Magic — on ne le joue pas,
      // on le pose.
      expect(rolesFor('onepiece').contains(CardRole.character), isTrue);
      expect(rolesFor('magic').contains(CardRole.land), isTrue);
    });
  });

  group('le gabarit vient du règlement', () {
    final gabarit = DeckBlueprint.of(DeckFormat.tournament)!;

    test('il se déclare réglementaire, et non mesuré', () {
      // Les deux autres valeurs décrivent toutes deux un corpus — serré, ou
      // mêlant des archétypes. Celle-ci dit qu'il n'y a pas de corpus du tout.
      expect(gabarit.reliability, BlueprintReliability.regulatory);
    });

    test('cinquante cartes, comme le règlement l_impose', () {
      expect(gabarit.size, 50);
    });

    test('trois exemplaires par carte', () {
      expect(gabarit.maxCopies, 3);
    });

    test('dix terrains, et l_écart est NUL', () {
      // C'est le cœur de ce gabarit : un deck à neuf terrains n'est pas rare,
      // il est illégal. Un écart non nul se lirait « à peu près dix », ce que
      // le règlement ne dit pas.
      expect(gabarit.lands, isNotNull);
      expect(gabarit.lands!.countFor(gabarit.size), 10);
      expect(gabarit.lands!.spread, 0.0);
    });

    test('quarante personnages, et l_écart est nul aussi', () {
      final personnages = gabarit.roles[CardRole.character]!;
      expect(personnages.countFor(gabarit.size), 40);
      expect(personnages.spread, 0.0);
    });

    test('les deux quotas somment exactement le deck', () {
      // 10 + 40 = 50. Contrairement aux gabarits mesurés, où la somme approche
      // 100 % à l'arrondi près, ici elle tombe juste : ce sont des règles.
      final total =
          gabarit.lands!.countFor(gabarit.size) +
          gabarit.roles[CardRole.character]!.countFor(gabarit.size);
      expect(total, gabarit.size);
    });

    test('aucune courbe, et c_est une absence assumée', () {
      // Le catalogue ne porte aucun coût de mise en jeu pour ce jeu — les
      // personnages se posent, les terrains se défaussent. Une courbe vide dit
      // « ce jeu n'en a pas » ; une courbe inventée dirait n'importe quoi avec
      // assurance. Même décision que chez Pokémon, dont le `cmc` porte les
      // points de vie.
      expect(gabarit.curve, isEmpty);
    });

    test('aucune carte de commandement', () {
      expect(gabarit.needsCommander, isFalse);
    });
  });

  group('ce que ce gabarit distingue des six autres', () {
    test('il est le seul dont tous les écarts sont nuls', () {
      final reglementaire = DeckBlueprint.of(DeckFormat.tournament)!;
      final ecarts = [
        reglementaire.lands!.spread,
        ...reglementaire.roles.values.map((q) => q.spread),
      ];
      expect(ecarts.every((e) => e == 0.0), isTrue);

      // Un gabarit mesuré, lui, a nécessairement de l'écart : c'est la
      // diversité du méta qu'il décrit.
      final mesure = DeckBlueprint.of(DeckFormat.premier)!;
      expect(mesure.roles.values.any((q) => q.spread > 0), isTrue);
    });

    test('Wankul ne propose que ce format', () {
      expect(deckFormatsFor(Game.wankul), [DeckFormat.tournament]);
    });
  });
}
