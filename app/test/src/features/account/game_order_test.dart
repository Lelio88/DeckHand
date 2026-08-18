/// L'ordre dans lequel le sélecteur présente les huit jeux.
///
/// **Ce que ces tests protègent.** La promesse tient en une phrase : « si je ne
/// joue qu'à Pokémon, Pokémon est en premier ». Tout le reste est du cas limite,
/// et c'est là que la fonction peut trahir sans bruit — une liste vide qui vide
/// l'écran, un doublon qui affiche deux fois la même tuile, un identifiant
/// inconnu venu d'une version plus récente de l'application.
///
/// **Deux absences qui ne veulent pas dire la même chose.** `null` signifie « on
/// n'a jamais posé la question », la liste vide « la question a été posée et
/// passée ». Les deux rendent le même écran — les huit jeux à plat —, mais c'est
/// une coïncidence d'affichage, pas une équivalence : ailleurs, l'une déclenche
/// l'étape de choix et l'autre non.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/account/domain/game_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('un seul jeu déclaré le place en premier', () {
    final ordre = orderedGames(const [Game.pokemon]);

    expect(ordre.played, [Game.pokemon]);
    expect(ordre.others, isNot(contains(Game.pokemon)));
    expect(ordre.others.length, Game.values.length - 1);
  });

  test('l\'ordre de déclaration est celui de la page', () {
    // C'est l'ordre du choix, pas celui de l'énumération : Wankul avant Magic
    // si c'est ainsi qu'on les a cochés.
    final ordre = orderedGames(const [Game.wankul, Game.magic, Game.lorcana]);

    expect(ordre.played, [Game.wankul, Game.magic, Game.lorcana]);
  });

  test('les autres jeux gardent l\'ordre de l\'application', () {
    final ordre = orderedGames(const [Game.lorcana]);

    expect(ordre.others, Game.values.where((g) => g != Game.lorcana).toList());
  });

  test('sans réponse enregistrée, les huit jeux restent à plat', () {
    // Le cas d'un compte qui n'a jamais vu l'étape de choix : surtout ne rien
    // replier, sinon la page s'ouvre sur une section vide.
    final ordre = orderedGames(null);

    expect(ordre.played, isEmpty);
    expect(ordre.others, Game.values);
  });

  test('une réponse vide se comporte comme une absence de réponse', () {
    // « Plus tard » a été choisi : la question ne sera plus posée, mais aucun
    // jeu n'a été déclaré et la page ne doit pas s'en trouver amputée.
    final ordre = orderedGames(const []);

    expect(ordre.played, isEmpty);
    expect(ordre.others, Game.values);
  });

  test('tous les jeux déclarés ne laissent rien à replier', () {
    final ordre = orderedGames(Game.values);

    expect(ordre.played, Game.values);
    expect(ordre.others, isEmpty);
  });

  test('un jeu déclaré deux fois n\'apparaît qu\'une', () {
    // La base ne déduplique pas — l'ordre y est l'information, pas l'ensemble
    // — et une tuile en double serait un défaut visible.
    final ordre = orderedGames(const [Game.magic, Game.pokemon, Game.magic]);

    expect(ordre.played, [Game.magic, Game.pokemon]);
    expect(ordre.others, isNot(contains(Game.magic)));
  });
}
