/// Rapatrier l'index d'empreintes pour un banc, hors de l'application.
///
/// **Pourquoi un chargeur à part.** Les bancs existants n'avaient jamais eu
/// besoin de l'index réel : ils comparaient une empreinte à une référence
/// calculée sur place. Analyser une vidéo suppose au contraire de chercher dans
/// le catalogue entier, donc de le rapatrier.
///
/// **Sans client Supabase, et sans session.** Un `dart run tool/…` ne démarre
/// pas Flutter ; `Supabase.instance` n'y existe pas. Mais `art_hash_page` et
/// `art_hash_count` sont accordées à `anon` : une requête HTTP avec la clé
/// publiable suffit, et elle emprunte exactement le chemin de l'application.
///
/// **Aucune duplication de format.** L'index est reconstruit par
/// `ArtHashIndex.fromEntries`, comme dans l'application, puis conservé par
/// `toBytes()`. Écrire un encodeur côté Python aurait créé un troisième jumeau
/// à tenir en phase, sur la structure la moins tolérante à la dérive du projet.
///
/// Usage :
/// ```dart
/// final index = await chargerIndex('magic');
/// ```
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';

/// Où le coffre de secrets vit, relativement au dossier `app/`.
const String _secretsPath = '../../.deckhand-secrets/supabase.env';

/// Où l'index rapatrié est conservé. Ignoré par git — c'est un artefact, et le
/// dépôt est public.
const String _cacheDir = 'tool/.cache';

/// Mêmes valeurs que l'application : mille par page, quatre pages à la fois.
/// Le pourquoi de ces deux nombres est écrit dans `art_index_repository.dart`.
const int _pageSize = 1000;
const int _concurrency = 4;

Map<String, String> _lireSecrets() {
  final fichier = File(_secretsPath);
  if (!fichier.existsSync()) {
    throw StateError(
      'coffre introuvable : $_secretsPath\n'
      'Le banc se lance depuis le dossier app/.',
    );
  }
  final valeurs = <String, String>{};
  for (final ligne in fichier.readAsLinesSync()) {
    final nu = ligne.trim();
    if (nu.isEmpty || nu.startsWith('#')) continue;
    final coupe = nu.indexOf('=');
    if (coupe <= 0) continue;
    valeurs[nu.substring(0, coupe).trim()] = nu
        .substring(coupe + 1)
        .trim()
        .replaceAll('"', '');
  }
  return valeurs;
}

/// L'index du jeu, servi du cache local s'il y est.
///
/// [forcer] retélécharge même si le cache existe — à employer après une
/// ingestion, le cache ne portant aucune date de péremption. Un banc n'est pas
/// l'application : il vaut mieux un rapatriement explicite qu'un comptage
/// réseau à chaque exécution.
Future<ArtHashIndex> chargerIndex(String game, {bool forcer = false}) async {
  final fichier = File('$_cacheDir/$game.idx');
  if (!forcer && fichier.existsSync()) {
    final index = ArtHashIndex.fromBytes(await fichier.readAsBytes());
    print('index $game : ${index.length} empreintes (cache local)');
    return index;
  }

  final secrets = _lireSecrets();
  final url = secrets['SUPABASE_URL'];
  final key = secrets['SUPABASE_PUBLISHABLE_KEY'];
  if (url == null || key == null) {
    throw StateError(
      'SUPABASE_URL ou SUPABASE_PUBLISHABLE_KEY absente de $_secretsPath',
    );
  }

  final client = HttpClient();
  try {
    final total = await _rpc<int>(client, url, key, 'art_hash_count', {
      'p_game': game,
    });
    if (total <= 0) {
      throw StateError('aucune empreinte pour « $game » — jeu inconnu ?');
    }

    final offsets = [
      for (var offset = 0; offset < total; offset += _pageSize) offset,
    ];
    final pages = <List<IndexEntry>>[];
    final chrono = Stopwatch()..start();

    for (var debut = 0; debut < offsets.length; debut += _concurrency) {
      final lot = offsets.skip(debut).take(_concurrency);
      final arrivees = await Future.wait([
        for (final offset in lot) _page(client, url, key, game, offset),
      ]);
      pages.addAll(arrivees);
      stdout.write(
        '\r  ${pages.length * _pageSize > total ? total : pages.length * _pageSize}'
        '/$total empreintes…',
      );
    }
    stdout.writeln();

    final index = ArtHashIndex.fromEntries([for (final page in pages) ...page]);
    await Directory(_cacheDir).create(recursive: true);
    await fichier.writeAsBytes(index.toBytes());
    print(
      'index $game : ${index.length} empreintes '
      'en ${(chrono.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, '
      'conservé dans $_cacheDir',
    );
    return index;
  } finally {
    client.close();
  }
}

Future<List<IndexEntry>> _page(
  HttpClient client,
  String url,
  String key,
  String game,
  int offset,
) async {
  final rows = await _rpc<List<dynamic>>(client, url, key, 'art_hash_page', {
    'p_offset': offset,
    'p_limit': _pageSize,
    'p_game': game,
  });
  return [
    for (final row in rows.cast<Map<String, dynamic>>())
      (
        oracleId: row['oracle_id'] as String,
        printId: row['print_id'] as String,
        hash: ArtHash.fromHex(row['hash_hex'] as String),
      ),
  ];
}

Future<T> _rpc<T>(
  HttpClient client,
  String url,
  String key,
  String nom,
  Map<String, Object?> params,
) async {
  final requete = await client.postUrl(Uri.parse('$url/rest/v1/rpc/$nom'));
  requete.headers
    ..set('apikey', key)
    ..set('Authorization', 'Bearer $key')
    ..set('Content-Type', 'application/json');
  requete.write(jsonEncode(params));

  final reponse = await requete.close();
  final corps = await reponse.transform(utf8.decoder).join();
  if (reponse.statusCode != 200) {
    throw HttpException('$nom : HTTP ${reponse.statusCode} — $corps');
  }
  return jsonDecode(corps) as T;
}
