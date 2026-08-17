/// Tests du constructeur sur les axes de Star Wars Unlimited.
///
/// **Ce jeu est le premier à avoir tout ce qu'il faut du premier coup**, et
/// c'est ce que ces tests vérifient. Riftbound n'a toujours pas de gabarit
/// faute d'avoir mesuré ses notions ; Yu-Gi-Oh a demandé de refaire le
/// constructeur sur ses axes ; Wankul connaît ses règles et manque des champs
/// pour les vérifier. Ici les trois familles sont **imprimées dans le type**,
/// la taille est un plancher réglementaire, et le coût est un vrai coût de mise
/// en jeu.
///
/// Les proportions viennent de `app.measure.swu_decks`, mesurées sur **220
/// listes de tournoi** : unités 81,0 %, événements 12,0 %, améliorations 5,0 %,
/// pour un deck principal dont le mode est 50 cartes.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:flutter_test/flutter_test.dart';

BuildableCard swu({
  required String name,
  String type = 'Unit — REBEL TROOPER',
  double cost = 3,
  Set<String> aspects = const {'Vigilance'},
  int quantity = 3,
}) => BuildableCard(
  game: 'swu',
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: cost,
  colorIdentity: aspects,
  quantity: quantity,
);

void main() {
  group('les rôles sont lus sur le type imprimé', () {
    test('les trois familles du deck principal se reconnaissent', () {
      expect(rolesOf(swu(name: 'A', type: 'Unit — REBEL')), {CardRole.unit});
      expect(rolesOf(swu(name: 'B', type: 'Event')), {CardRole.event});
      expect(rolesOf(swu(name: 'C', type: 'Upgrade — MODIFICATION')), {
        CardRole.upgrade,
      });
    });

    test('elles partitionnent : une carte ne tient jamais deux rôles', () {
      // Contrairement aux rôles Magic, qui se recouvrent volontairement — une
      // créature qui produit du mana est créature *et* rampe.
      for (final type in ['Unit — X', 'Event', 'Upgrade — Y']) {
        expect(rolesOf(swu(name: type, type: type)).length, 1);
      }
    });

    test('le leader et la base ne sont pas dosés', () {
      // Un exemplaire chacun dans 220 listes sur 220 : c'est une règle, pas une
      // proportion à viser. Leur donner un rôle les ferait entrer dans les
      // quotas et fausserait la part des unités.
      expect(rolesOf(swu(name: 'L', type: 'Leader — UNDERWORLD')), isEmpty);
      expect(rolesOf(swu(name: 'B', type: 'Base')), isEmpty);
    });

    test('les rôles affichés sont ceux de ce jeu, et eux seuls', () {
      // Montrer un quota de créatures sur un deck SWU dirait « il en manque
      // quarante » d'une carte qui n'existe pas.
      expect(rolesFor('swu'), {
        CardRole.unit,
        CardRole.event,
        CardRole.upgrade,
      });
      expect(rolesFor('swu').contains(CardRole.creature), isFalse);
      expect(rolesFor('swu').contains(CardRole.land), isFalse);
    });
  });

  group('le gabarit', () {
    final gabarit = DeckBlueprint.of(DeckFormat.premier)!;

    test('vise le plancher réglementaire, et non la médiane', () {
      // 50 est à la fois le mode du corpus — 100 listes sur 220 — et le minimum
      // légal. Viser la médiane de 51 produirait un deck une carte au-dessus du
      // plancher, là où viser le plancher produit le deck le plus accessible.
      expect(gabarit.size, 50);
    });

    test('retient trois exemplaires, la règle que le corpus confirme', () {
      // Une seule liste sur 4 722 entrées en déclare 15 : une saisie fautive,
      // pas une infraction — même figure que le deck HAT à six exemplaires.
      expect(gabarit.maxCopies, 3);
    });

    test('demande un leader, qui tient la place du commandant', () {
      expect(gabarit.needsCommander, isTrue);
    });

    test('ne dose aucun terrain, ce jeu n_en ayant pas', () {
      // `null` et non zéro : il n'y a rien à manquer. On ne joue pas de
      // carte-ressource, on défausse une carte de sa main pour en faire une.
      expect(gabarit.lands, isNull);
    });

    test('filtre par aspect, et c_est mesuré et non supposé', () {
      // **L'inverse exact de Yu-Gi-Oh**, dont l'Attribut ressemble à une
      // identité de couleur sans imposer aucune contrainte — y filtrer écartait
      // 32 % du catalogue. Ici 79,1 % des decks tiennent entièrement dans les
      // aspects de leur leader et de leur base.
      expect(gabarit.usesColorIdentity, isTrue);
    });

    test('les trois familles somment à peu près le deck entier', () {
      final total = gabarit.roles.values
          .map((q) => q.share)
          .reduce((a, b) => a + b);
      // 98 % : les 2 % manquants sont l'arrondi de la mesure, les trois
      // familles partitionnant réellement le deck principal.
      expect(total, closeTo(98, 2));
    });

    test('la courbe part du coût 1 : le coût 0 n_existe pas', () {
      // Mesuré : 0,0 % avec un écart interquartile nul.
      expect(gabarit.curve.first.min, 1);
      expect(gabarit.curve.any((s) => s.contains(0)), isFalse);
    });

    test('le haut de courbe est le palier le plus dispersé', () {
      // 17,4 points d'écart contre 4,4 à 7,2 ailleurs : c'est là que les
      // archétypes divergent.
      final haut = gabarit.curve.last;
      for (final autre in gabarit.curve.take(gabarit.curve.length - 1)) {
        expect(haut.quota.spread, greaterThan(autre.quota.spread));
      }
    });

    test('se dit moyenné, tous les archétypes du méta y étant mêlés', () {
      // La médiane décrit un deck plausible, pas un deck existant.
      expect(gabarit.reliability, BlueprintReliability.averaged);
    });
  });

  test('le format proposé pour ce jeu est le seul qui porte le corpus', () {
    // `premier` couvre 19 tournois sur 20, tous officiels. Yu-Gi-Oh a payé la
    // déduction inverse — `Advanced` déclaré sur la foi de son nom, pour trois
    // decklists sur 168 tournois.
    expect(deckFormatsFor(Game.swu), [DeckFormat.premier]);
  });
}
