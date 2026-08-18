/// L'ordre dans lequel le sélecteur présente les jeux.
///
/// **Le sélecteur alignait les huit jeux dans l'ordre du code**, le même pour
/// tout le monde. Quelqu'un qui ne joue qu'à Pokémon passait devant sept jeux
/// qui ne le concernent pas, à chaque fois qu'il ouvrait la page. Les jeux
/// déclarés à l'inscription remontent donc en tête, dans l'ordre où ils ont été
/// cochés, et les autres restent atteignables sous un repli.
///
/// **Relégués, jamais masqués.** Un jeu décoché garde une collection, des
/// classeurs et un journal ; le faire disparaître de l'écran qui sert à en
/// changer les rendrait introuvables. La page se raccourcit, elle ne se ferme
/// pas.
///
/// **Pur, et sans dépendance à Flutter ni à Supabase.** L'ordre est une
/// question de liste, pas d'affichage : le garder ici le rend mesurable sans
/// monter d'écran ni ouvrir de session — c'est ce qui permet aux cas limites
/// (aucune réponse, réponse vide, doublon) d'être éprouvés pour de bon.
library;

import '../../../config/selected_game.dart';

/// Les deux moitiés de la page : ce qu'on joue, puis le reste.
typedef GameOrder = ({List<Game> played, List<Game> others});

/// Range les jeux selon ce que le compte a déclaré jouer.
///
/// [declared] vaut `null` quand la question n'a jamais été posée, et la liste
/// vide quand elle l'a été et que l'utilisateur l'a passée. **Les deux rendent
/// le même écran** — les huit jeux à plat — et c'est voulu : replier une section
/// vide sous « Autres jeux » n'apprendrait rien à personne. La distinction sert
/// ailleurs, pour décider si l'étape de choix doit s'ouvrir.
///
/// Les doublons sont écartés en gardant la première place occupée : la base ne
/// déduplique pas la colonne — l'ordre y est l'information, pas l'ensemble —, et
/// deux tuiles identiques seraient un défaut visible.
///
/// ```dart
/// final ordre = orderedGames([Game.pokemon]);
/// // ordre.played → [Game.pokemon]
/// // ordre.others → les sept autres, dans l'ordre de l'application
/// ```
GameOrder orderedGames(List<Game>? declared) {
  final played = <Game>[];
  for (final game in declared ?? const <Game>[]) {
    if (!played.contains(game)) played.add(game);
  }

  final others = Game.values.where((g) => !played.contains(g)).toList();
  return (played: played, others: others);
}
