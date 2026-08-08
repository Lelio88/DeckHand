/// Jeu de cartes couramment saisi.
///
/// **Un seul jeu à la fois, et c'est délibéré.** Une collection Magic et une
/// collection Riftbound n'ont rien à faire ensemble : leurs cartes ne se jouent
/// pas dans les mêmes decks, ne se comparent pas en prix, et mêler les deux
/// catalogues dans une recherche produirait des résultats que l'utilisateur
/// devrait trier lui-même à chaque frappe. Le choix est donc global, et il
/// traverse la recherche, la collection et les suggestions.
///
/// **Il survit au redémarrage.** On ne rechoisit pas son jeu à chaque
/// ouverture : c'est une propriété de l'utilisateur, pas de la session.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Jeux couverts.
///
/// L'identifiant est celui de la colonne `cards.game` : il part tel quel dans
/// les appels au serveur, sans table de correspondance à maintenir.
enum Game {
  magic('magic', 'Magic: The Gathering'),
  riftbound('riftbound', 'Riftbound');

  const Game(this.id, this.label);

  final String id;
  final String label;

  static Game fromId(String? id) =>
      Game.values.firstWhere((g) => g.id == id, orElse: () => Game.magic);
}

const _preferenceKey = 'selected_game';

/// Jeu sélectionné, restauré depuis les préférences.
///
/// L'état part sur [Game.magic] puis se corrige dès que la préférence est lue.
/// Attendre la lecture pour afficher quoi que ce soit ferait clignoter
/// l'application au démarrage, pour une préférence qui ne change presque
/// jamais — et le cas majoritaire est justement Magic.
class SelectedGame extends Notifier<Game> {
  @override
  Game build() {
    _restore();
    return Game.magic;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = Game.fromId(prefs.getString(_preferenceKey));
    if (saved != state) state = saved;
  }

  /// Change de jeu et retient le choix.
  Future<void> select(Game game) async {
    if (game == state) return;
    state = game;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_preferenceKey, game.id);
  }
}

final selectedGameProvider = NotifierProvider<SelectedGame, Game>(
  SelectedGame.new,
);
