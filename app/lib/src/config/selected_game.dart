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

import '../features/scan/domain/card_geometry.dart';

/// Jeux couverts.
///
/// L'identifiant est celui de la colonne `cards.game` : il part tel quel dans
/// les appels au serveur, sans table de correspondance à maintenir.
enum Game {
  magic('magic', 'Magic: The Gathering', bilingue),
  riftbound('riftbound', 'Riftbound', anglaisSeul),
  yugioh('yugioh', 'Yu-Gi-Oh!', bilingue),
  pokemon('pokemon', 'Pokémon', bilingue),
  wankul('wankul', 'Wankul', bilingue),
  swu('swu', 'Star Wars Unlimited', anglaisSeul),
  onepiece('onepiece', 'One Piece Card Game', anglaisSeul),
  lorcana('lorcana', 'Disney Lorcana', anglaisSeul);

  const Game(this.id, this.label, this.catalogueLanguages);

  /// Les deux jeux de langues que portent les catalogues, nommés une fois.
  static const anglaisSeul = <String>['en'];
  static const bilingue = <String>['en', 'fr'];

  final String id;
  final String label;

  /// Langues dans lesquelles le catalogue connaît le **nom** des cartes.
  ///
  /// **Ce n'est pas une préférence, c'est un fait mesuré** sur
  /// `card_search_names` : quatre jeux y sont bilingues (magic, pokemon,
  /// yugioh, wankul), quatre n'ont que l'anglais (riftbound, swu, onepiece,
  /// lorcana). Les connecteurs le décident — `KEEP_LANGS` chez Scryfall — et
  /// rien ne le disait côté application.
  ///
  /// **Pourquoi l'écran en a besoin.** Une carte photographiée dans une langue
  /// absente d'ici voit son nom lu correctement, puis ne rencontrer aucune
  /// entrée. L'écran annonçait alors « vérifiez le jeu sélectionné », ce qui
  /// envoie corriger ce qui n'est pas en cause. La liste permet de nommer la
  /// vraie raison, et de ne pas coder Riftbound en dur pour les quatre jeux
  /// qui sont dans son cas.
  final List<String> catalogueLanguages;

  /// Ces langues, dites à un humain : « l'anglais » ou « l'anglais et le
  /// français ».
  String get catalogueLanguagesLabel => catalogueLanguages.length == 1
      ? 'l\'anglais'
      : 'l\'anglais et le français';

  /// Rapport largeur sur hauteur d'une carte de ce jeu.
  ///
  /// **Rendu ici pour que les vues n'aient pas à connaître le domaine du
  /// scan.** La valeur y est définie — c'est là qu'elle décide de quelque
  /// chose —, mais le classeur et l'aperçu d'une impression en ont besoin
  /// aussi : leurs cases ont les proportions d'une carte du jeu affiché, et
  /// elles écrivaient jusqu'ici `0.716` en clair, une décision que même une
  /// recherche ne retrouvait pas.
  double get aspect => cardAspectFor(id);

  static Game fromId(String? id) =>
      Game.values.firstWhere((g) => g.id == id, orElse: () => Game.magic);

  /// Le jeu portant cet identifiant, ou `null` s'il n'en existe aucun.
  ///
  /// **Le jumeau strict de [fromId], et il ne fait pas double emploi.** Le repli
  /// sur Magic est le bon comportement pour la préférence de jeu courant : une
  /// valeur illisible ne doit pas empêcher l'application de s'ouvrir. Il est le
  /// mauvais dès qu'on lit une *liste* venue de la base — un identifiant inconnu
  /// y deviendrait silencieusement Magic, et le compte se retrouverait à
  /// déclarer un jeu qu'il n'a jamais coché. Là, il faut pouvoir l'écarter.
  /// Jeux retirés du produit, **temporairement** (#48).
  ///
  /// **Ce n'est pas un choix de produit, c'est une contrainte d'hébergement.**
  /// Supabase a signalé le 2026-09-17 que la base occupait 855 Mo pour 500
  /// autorisés sur le plan gratuit, et annonce le passage en lecture seule
  /// au-delà — ce qui arrêterait toute écriture, collection comprise. Le corpus
  /// de decks pesait 53 % de la base, dont ~262 Mo pour les 23 574 decks
  /// Pokémon, contre ~18 Mo pour les 1 395 decks Magic.
  ///
  /// **Les cinq retirés sont ceux dont personne n'a les cartes.** La promesse
  /// « que puis-je construire ? » suppose une collection en face ; la collection
  /// réelle est à 100 % Magic. Magic, Riftbound et Wankul restent — les deux
  /// premiers portent la promesse du produit, le troisième est ingéré sous
  /// autorisation nominative et pèse moins d'un mégaoctet.
  ///
  /// **Vider ce `Set` remet tout**, c'est la seule ligne à toucher côté
  /// application ; les catalogues se réingèrent par leurs connecteurs, rien
  /// n'est perdu. Son jumeau côté serveur est `JEUX_RETIRES`
  /// (`api/app/ingestion/jeux_actifs.py`), qui empêche une ingestion de les
  /// faire revenir sans qu'on l'ait décidé.
  ///
  /// [values] reste entier à dessein : une préférence enregistrée sur un jeu
  /// retiré doit continuer à se lire, faute de quoi un compte qui avait coché
  /// Pokémon verrait sa liste se corrompre en silence.
  static const retires = <Game>{
    Game.yugioh,
    Game.pokemon,
    Game.swu,
    Game.onepiece,
    Game.lorcana,
  };

  /// Les jeux qu'on propose à l'utilisateur, dans l'ordre de [values].
  ///
  /// C'est cette liste que lisent les écrans, jamais [values] : un jeu sans
  /// catalogue en base n'a rien à faire dans un sélecteur, il n'y produirait
  /// qu'une recherche vide sans expliquer pourquoi.
  static List<Game> get actifs =>
      values.where((g) => !retires.contains(g)).toList();

  static Game? tryFromId(String? id) {
    for (final game in Game.values) {
      if (game.id == id) return game;
    }
    return null;
  }
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
