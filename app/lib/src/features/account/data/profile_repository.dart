/// Les préférences du compte : les jeux auxquels il joue, et ce qu'il paie un
/// booster.
///
/// **Portées par le compte, pas par l'appareil.** Le jeu *courant* vit dans les
/// préférences locales (`selected_game.dart`) parce qu'il change plusieurs fois
/// par séance et n'a aucune raison de voyager. Les jeux *joués*, eux, sont une
/// propriété de la personne : ils suivent du téléphone au web et survivent à une
/// réinstallation, comme la collection qu'ils décrivent. Le prix d'un booster
/// décrit la même personne — ce qu'elle paie en boutique — et voyage donc avec.
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
/// réécriture. `booster_prices` suit la même discipline.
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

  /// Ce que le compte déclare payer un booster, par jeu.
  ///
  /// Une carte vide n'est pas un échec : elle veut dire « je n'ai rien
  /// déclaré », et l'application retombe alors sur ses prix de repère.
  Future<Map<String, double>> boosterPrices() async {
    final rows = await _client
        .from('profiles')
        .select('booster_prices')
        .limit(1);
    if (rows.isEmpty) return const {};

    return boosterPricesFromColumn(rows.first['booster_prices']);
  }

  /// Enregistre le prix payé pour un jeu, sans toucher aux autres.
  ///
  /// **Une fusion, pas un remplacement.** Envoyer la carte entière écraserait
  /// les prix qu'une autre session — ou un autre appareil — vient de poser pour
  /// d'autres jeux. La fusion se fait ici, sur la carte relue juste avant.
  ///
  /// [priceEur] à `null` **retire** la déclaration et rend la main au prix de
  /// repère. C'est distinct de zéro, qui reste une réponse : « je n'achète pas
  /// de boosters ».
  Future<void> saveBoosterPrice(String game, double? priceEur) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    final merged = Map<String, double>.from(await boosterPrices());
    if (priceEur == null) {
      merged.remove(game);
    } else {
      merged[game] = priceEur;
    }

    await _client.from('profiles').upsert({
      'user_id': userId,
      'booster_prices': merged,
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

/// Traduit la colonne `booster_prices` en prix que cette version sait lire.
///
/// Même discipline que [gamesFromColumn] : on écarte ce qu'on ne comprend pas
/// plutôt que de le deviner.
///
/// **Un prix négatif est écarté**, et ce n'est pas de la coquetterie : il ne
/// veut rien dire, et il produirait une dépense négative — un indicateur qui
/// annonce « vous auriez gagné 240 € en achetant des boosters » est pire qu'un
/// indicateur absent.
///
/// **Postgres rend un `jsonb` numérique entier en `int`**, jamais en `double` :
/// tester `is double` laisserait tomber tout prix rond, et « 6 € » deviendrait
/// silencieusement « rien de déclaré ».
Map<String, double> boosterPricesFromColumn(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, double>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String) continue;
    final price = value is num ? value.toDouble() : null;
    if (price == null || price.isNaN || price < 0) continue;
    out[key] = price;
  }
  return out;
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

/// Les prix de booster déclarés par le compte connecté.
///
/// Vide sans session, et c'est le bon repli : la page de profil n'est
/// atteignable que connecté, et un vide y produit exactement l'affichage voulu
/// — les prix de repère.
final boosterPricesProvider = FutureProvider<Map<String, double>>((ref) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return const {};
  return ref.watch(profileRepositoryProvider).boosterPrices();
});
