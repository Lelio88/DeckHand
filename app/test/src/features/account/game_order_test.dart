/// L'ordre dans lequel le sélecteur présente les huit jeux.
///
/// **Ce que ces tests protègent.** La promesse tient en une phrase : « si je ne
/// joue qu'à un jeu, ce jeu est en premier ». Tout le reste est du cas limite,
/// et c'est là que la fonction peut trahir sans bruit — une liste vide qui vide
/// l'écran, un doublon qui affiche deux fois la même tuile, un identifiant
/// inconnu venu d'une version plus récente de l'application.
///
/// **Deux absences qui ne veulent pas dire la même chose.** `null` signifie « on
/// n'a jamais posé la question », la liste vide « la question a été posée et
/// passée ». Les deux rendent le même écran — tous les jeux servis à plat —,
/// mais c'est
/// une coïncidence d'affichage, pas une équivalence : ailleurs, l'une déclenche
/// l'étape de choix et l'autre non.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/account/domain/game_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('un seul jeu déclaré le place en premier', () {
    final ordre = orderedGames(const [Game.riftbound]);

    expect(ordre.played, [Game.riftbound]);
    expect(ordre.others, isNot(contains(Game.riftbound)));
    expect(ordre.others.length, Game.actifs.length - 1);
  });

  test('l\'ordre de déclaration est celui de la page', () {
    // C'est l'ordre du choix, pas celui de l'énumération : Wankul avant Magic
    // si c'est ainsi qu'on les a cochés.
    final ordre = orderedGames(const [Game.wankul, Game.magic, Game.riftbound]);

    expect(ordre.played, [Game.wankul, Game.magic, Game.riftbound]);
  });

  test('les autres jeux gardent l\'ordre de l\'application', () {
    final ordre = orderedGames(const [Game.wankul]);

    expect(ordre.others, Game.actifs.where((g) => g != Game.wankul).toList());
  });

  test('un jeu retiré du produit ne paraît nulle part', () {
    // **Le piège du retrait temporaire** (#48) : un compte qui avait coché
    // Pokémon avant qu'il soit déchargé le verrait remonter *en tête* de sa
    // page — la place la plus visible pour le seul jeu dont le catalogue est
    // vide. Il ne doit reparaître ni parmi les joués, ni sous le repli.
    final ordre = orderedGames(const [Game.pokemon, Game.magic]);

    expect(ordre.played, [Game.magic]);
    expect(ordre.others, isNot(contains(Game.pokemon)));
  });

  test('ne déclarer que des jeux retirés rouvre la page à plat', () {
    // Sa liste devient vide : la page s'ouvre à plat sur les jeux servis,
    // plutôt que sur une section « vos jeux » déserte.
    final ordre = orderedGames(const [Game.pokemon, Game.yugioh]);

    expect(ordre.played, isEmpty);
    expect(ordre.others, Game.actifs);
  });

  test('sans réponse enregistrée, tous les jeux servis restent à plat', () {
    // Le cas d'un compte qui n'a jamais vu l'étape de choix : surtout ne rien
    // replier, sinon la page s'ouvre sur une section vide.
    final ordre = orderedGames(null);

    expect(ordre.played, isEmpty);
    expect(ordre.others, Game.actifs);
  });

  test('une réponse vide se comporte comme une absence de réponse', () {
    // « Plus tard » a été choisi : la question ne sera plus posée, mais aucun
    // jeu n'a été déclaré et la page ne doit pas s'en trouver amputée.
    final ordre = orderedGames(const []);

    expect(ordre.played, isEmpty);
    expect(ordre.others, Game.actifs);
  });

  test('tous les jeux déclarés ne laissent rien à replier', () {
    final ordre = orderedGames(Game.actifs);

    expect(ordre.played, Game.actifs);
    expect(ordre.others, isEmpty);
  });

  test('un jeu déclaré deux fois n\'apparaît qu\'une', () {
    // La base ne déduplique pas — l'ordre y est l'information, pas l'ensemble
    // — et une tuile en double serait un défaut visible.
    final ordre = orderedGames(const [Game.magic, Game.wankul, Game.magic]);

    expect(ordre.played, [Game.magic, Game.wankul]);
    expect(ordre.others, isNot(contains(Game.magic)));
  });
}
