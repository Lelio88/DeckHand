/// Les préférences du compte : aujourd'hui, les jeux auxquels il joue.
///
/// **Portées par le compte, pas par l'appareil.** Le jeu *courant* vit dans les
/// préférences locales (`selected_game.dart`) parce qu'il change plusieurs fois
/// par séance et n'a aucune raison de voyager. Les jeux *joués*, eux, sont une
/// propriété de la personne : ils suivent du téléphone au web et survivent à une
/// réinstallation, comme la collection qu'ils décrivent.
///
/// **Trois états, pas deux.** `null` veut dire « on n'a jamais posé la
/// question », la liste vide « la question a été posée et passée », une liste
/// pleine « voici mes jeux, dans cet ordre ». Sans le premier, l'étape de choix
/// reviendrait à chaque lancement pour qui a répondu « plus tard » ; c'est la
/// **présence de la ligne** en base qui fait foi, et non son contenu.
///
/// **Un identifiant inconnu est écarté, jamais traduit.** Une version plus
/// récente de l'application peut avoir écrit un jeu que celle-ci ignore ;
/// `Game.tryFromId` le laisse tomber plutôt que de le replier sur Magic. La
/// ligne reste intacte en base — c'est une lecture tolérante, pas une
/// réécriture.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/selected_game.dart';
import '../../auth/data/auth_repository.dart';

class ProfileRepository {
  const ProfileRepository(this._client);

  final SupabaseClient _client;

  /// Les jeux déclarés par le compte, ou `null` si la question est encore
  /// ouverte.
  ///
  /// La politique borne déjà la lecture à sa propre ligne : pas de filtre sur
  /// `user_id` ici, il ferait doublon avec la RLS et pourrait diverger d'elle.
  Future<List<Game>?> playedGames() async {
    final rows = await _client.from('profiles').select('games').limit(1);
    if (rows.isEmpty) return null;

    return gamesFromColumn(rows.first['games']);
  }

  /// Enregistre les jeux déclarés, dans l'ordre reçu.
  ///
  /// L'ordre **est** l'information : `games.first` est le jeu que
  /// l'application ouvrira. Rien n'est trié ni dédupliqué ici — ce que
  /// l'utilisateur a coché est ce qui est écrit.
  Future<void> save(List<Game> games) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    await _client.from('profiles').upsert({
      'user_id': userId,
      'games': [for (final game in games) game.id],
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}

/// Traduit la colonne `games` en jeux que cette version connaît.
///
/// Isolée du dépôt pour être éprouvée sans base : c'est ici que se trouvent les
/// seuls cas tordus de la lecture — une colonne absente, un identifiant écrit
/// par une version plus récente, une valeur qui n'est pas une chaîne. Tous se
/// résolvent en écartant, jamais en devinant.
List<Game> gamesFromColumn(Object? raw) {
  if (raw is! List) return const <Game>[];
  return [for (final id in raw) ?Game.tryFromId(id is String ? id : null)];
}

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(Supabase.instance.client),
);

/// Les jeux déclarés par le compte connecté.
///
/// **`null` recouvre ici deux situations** — pas de session, et session sans
/// réponse enregistrée — et c'est sans conséquence : les deux seuls lecteurs
/// sont l'aiguillage de démarrage, qui n'observe ce provider qu'une session
/// ouverte, et le sélecteur, pour qui « aucune préférence » et « pas de
/// compte » donnent le même écran.
final playedGamesProvider = FutureProvider<List<Game>?>((ref) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return null;
  return ref.watch(profileRepositoryProvider).playedGames();
});
