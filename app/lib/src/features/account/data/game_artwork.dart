/// L'illustration qui représente chaque jeu dans le sélecteur.
///
/// **Le sélecteur était la seule liste de l'application à ne montrer aucune
/// carte.** La recherche, les classeurs, l'étagère et le constructeur en
/// affichent tous ; le choix du jeu, lui, alignait huit boîtes de texte. Un
/// joueur reconnaît son jeu à une image bien avant d'en lire le nom.
///
/// **Une carte figée par jeu, et non calculée.** Deux autres pistes ont été
/// écartées : la carte la plus jouée du corpus changerait à chaque ingestion —
/// et Wankul n'a pas de corpus —, et une carte de la collection laisserait sept
/// jeux sur huit sans image. Une constante se reconnaît d'une fois sur l'autre,
/// ce qui est exactement ce qu'on demande à un repère.
///
/// **L'identifiant plutôt que l'URL.** Une URL codée en dur se périmerait au
/// premier changement de CDN, et surtout elle contournerait `cardArtUrl` — la
/// composition que TCGdex exige, et dont l'absence a laissé 20 964 cartes
/// Pokémon sans image. L'identité, elle, est dérivée du nom de la carte et ne
/// bouge pas.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../scan/domain/art_box.dart';

/// La carte emblématique de chaque jeu, par son identité.
///
/// Les huit ont été choisies pour être reconnues sans légende : les créatures
/// que la boîte du jeu met en avant, ou la figure qui lui sert d'emblème.
/// Wankul fait exception à sa manière — LAINK est l'un des deux fondateurs du
/// studio dont le jeu est tiré, donc son visage plutôt qu'une créature.
const Map<String, GameArtwork> gameArtworks = {
  // **Magic n'a pas de cadre, et c'est le seul.** Scryfall sert `art_crop`,
  // c'est-à-dire l'illustration déjà détourée ; la recadrer une seconde fois
  // n'en montrerait qu'un morceau.
  'magic': GameArtwork('a6c05941-2cfb-4dac-a7c0-ab808187eb7c'), // Liliana Vess
  'riftbound': GameArtwork(
    'c29c2737-cc51-57f2-b832-5c3bff769df1',
    CardFrame.riftbound,
  ), // Jinx — Rebel
  'yugioh': GameArtwork(
    '74a08599-806b-5b05-abcd-fd90950ac934',
    CardFrame.yugioh,
  ), // Blue-Eyes White Dragon
  'pokemon': GameArtwork(
    'd2efdefa-ab03-56d3-90c1-2862c5316ae6',
    CardFrame.pokemon,
  ), // Pikachu
  'wankul': GameArtwork(
    '8d69959d-1d1a-5a4f-81e4-9cef6a709d88',
    CardFrame.wankul,
  ), // LAINK
  'swu': GameArtwork(
    'a8bf2fbe-a370-530c-9ab2-1342f55817a7',
    CardFrame.swuUnit,
  ), // Darth Vader
  'onepiece': GameArtwork(
    '4c6d617a-49c8-5d74-8508-1ace40453a7c',
    CardFrame.onePiece,
  ), // Monkey.D.Luffy
  'lorcana': GameArtwork(
    'a87007c6-bec6-51c3-8e09-e9485d02ccb9',
    CardFrame.lorcana,
  ), // Mickey Mouse
};

/// Une carte emblématique, et de quoi n'en montrer que l'illustration.
class GameArtwork {
  const GameArtwork(this.oracleId, [this.frame]);

  final String oracleId;

  /// Le cadre dont on retient la fenêtre d'illustration, ou `null` quand la
  /// source publie déjà l'illustration seule — le cas de Magic.
  final CardFrame? frame;
}

/// Charge les huit illustrations, **en une seule requête**.
///
/// Huit requêtes séparées seraient huit allers-retours pour un écran qu'on
/// ouvre pour changer de jeu, pas pour l'admirer. Le `in_` les regroupe.
///
/// Une carte absente du catalogue rend simplement une entrée manquante : la
/// tuile affichera son fond uni plutôt que de faire échouer l'écran entier.
/// C'est le comportement voulu — un sélecteur qui ne s'affiche pas empêche de
/// changer de jeu, un sélecteur sans image reste utilisable.
Future<Map<String, String>> fetchGameArtwork(SupabaseClient client) async {
  final ids = gameArtworks.values.map((a) => a.oracleId).toList();
  final rows = await client
      .from('card_prints')
      .select('oracle_id, art_crop_url')
      .inFilter('oracle_id', ids)
      .not('art_crop_url', 'is', null);

  // `oracle_id` → URL. Une carte peut avoir plusieurs impressions ; la première
  // rencontrée suffit, elles partagent l'illustration bien plus souvent qu'elles
  // n'en diffèrent, et aucune n'est fausse.
  final parOracle = <String, String>{};
  for (final row in rows as List<dynamic>) {
    final oracle = row['oracle_id'] as String?;
    final url = row['art_crop_url'] as String?;
    if (oracle != null && url != null) parOracle.putIfAbsent(oracle, () => url);
  }

  return {
    for (final entry in gameArtworks.entries)
      if (parOracle[entry.value.oracleId] != null)
        entry.key: parOracle[entry.value.oracleId]!,
  };
}

/// Les huit illustrations, chargées une fois par ouverture de l'écran.
///
/// **Sans `family` ni dépendance au jeu choisi** : la grille les montre toutes
/// en même temps, y compris celle du jeu qu'on quitte. Les faire dépendre de
/// `selectedGameProvider` relancerait la requête à chaque changement de jeu,
/// c'est-à-dire précisément quand l'écran doit rester stable sous le doigt.
final gameArtworkProvider = FutureProvider<Map<String, String>>(
  (ref) => fetchGameArtwork(Supabase.instance.client),
);
