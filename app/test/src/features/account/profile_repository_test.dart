/// La lecture de la colonne `games` du profil.
///
/// **Ce que ces tests protègent.** La colonne est un `text[]` sans contrainte :
/// la base accepte n'importe quel identifiant, délibérément — une liste figée
/// en SQL devrait être réécrite à chaque jeu ajouté, et une migration jouée ne
/// se modifie pas. La tolérance est donc côté application, et c'est ici qu'elle
/// se vérifie.
///
/// **Le piège est `Game.fromId`**, qui retombe sur Magic pour tout identifiant
/// inconnu. C'est le bon comportement pour la préférence de jeu courant, et le
/// mauvais ici : un jeu écrit par une version plus récente deviendrait
/// silencieusement Magic, et le compte se retrouverait à déclarer un jeu qu'il
/// n'a jamais coché.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/account/data/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rend les jeux dans l\'ordre de la colonne', () {
    // L'ordre est l'information : le premier de la liste est le jeu que
    // l'application ouvrira.
    expect(gamesFromColumn(['pokemon', 'magic']), [Game.pokemon, Game.magic]);
  });

  test('écarte un identifiant inconnu au lieu de le replier sur Magic', () {
    expect(gamesFromColumn(['pokemon', 'gwent']), [Game.pokemon]);
  });

  test('écarte ce qui n\'est pas une chaîne', () {
    expect(gamesFromColumn(['magic', 42, null]), [Game.magic]);
  });

  test('une colonne vide ne déclare aucun jeu', () {
    expect(gamesFromColumn(const []), isEmpty);
  });

  test('une colonne absente ne fait pas échouer la lecture', () {
    // Le cas ne devrait pas se produire — la colonne est NOT NULL — mais une
    // requête qui ne la sélectionne pas donnerait exactement cela, et l'écran
    // de compte ne doit pas tomber pour un réglage de confort.
    expect(gamesFromColumn(null), isEmpty);
    expect(gamesFromColumn('magic'), isEmpty);
  });
}
