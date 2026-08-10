/// Balaye la longueur minimale d'une ligne pour valoir nom de carte.
///
/// **La question posée.** Le filtre de taille ne sépare plus rien sur des
/// cartes entières — le rapport entre la plus grande ligne et la médiane tombe
/// à 1,20 — et il coûte cher : 65 % de rappel avec, 88 % sans. Ce qu'il évitait
/// encore, ce sont des fragments de trois lettres qui trouvent une vraie carte
/// (« ure » → *Ureni's Rebuff*). Si une simple longueur minimale les écarte, le
/// filtre de taille peut disparaître et le rappel remonter de vingt points.
///
/// Le filtrage par taille est donc **désactivé** ici (`heightRatio: 0`) : on
/// mesure ce que la longueur seule sait faire.
///
/// Usage :
///   dart run tool/sweep_min_length.dart mesure.log verite.txt
library;

import 'dart:convert';
import 'dart:io';

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/scan/domain/spread_names.dart';

/// Longueurs essayées. Trois est la valeur en vigueur ; au-delà de huit, des
/// noms courts légitimes (« Fog », « Shock ») commenceraient à tomber.
const List<int> _lengths = [3, 4, 5, 6, 7, 8, 10];

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage : dart run tool/sweep_min_length.dart <mesure.log> <verite.txt>',
    );
    exit(64);
  }

  final lines = _readLines(File(args[0]));
  if (lines.isEmpty) {
    stderr.writeln('Aucun événement spread_line dans ${args[0]}.');
    exit(65);
  }

  final catalogue = _Catalogue(_secrets());
  await catalogue.signIn();

  final expected = <String>{};
  for (final name
      in File(args[1])
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('#'))) {
    final hit = await catalogue.search(name);
    if (hit == null) {
      stderr.writeln('Vérité terrain introuvable : « $name »');
      exit(65);
    }
    expected.add(hit.oracleId);
  }

  stdout.writeln(
    '${lines.length} lignes lues, ${expected.length} cartes étalées.',
  );
  stdout.writeln('Filtre de taille désactivé — seule la longueur trie.\n');
  stdout.writeln(
    '| longueur min | proposées | justes | fausses | rappel | précision |',
  );
  stdout.writeln('|---|---|---|---|---|---|');

  final wrongBy = <int, List<String>>{};
  for (final minLength in _lengths) {
    final candidates = spreadNameCandidates(
      lines,
      heightRatio: 0,
      minLength: minLength,
    );

    final found = <String>{};
    final wrong = <String>[];
    for (final candidate in candidates) {
      final hit = await catalogue.search(candidate.text);
      if (hit == null || hit.score < spreadScoreThreshold) continue;
      if (!isPlausibleMatch(candidate.text, hit.matchedName)) continue;
      if (!found.add(hit.oracleId)) continue;
      if (!expected.contains(hit.oracleId)) {
        wrong.add('« ${candidate.text} » → ${hit.name}');
      }
    }

    wrongBy[minLength] = wrong;
    final right = found.where(expected.contains).length;
    final recall = right / expected.length;
    final precision = found.isEmpty ? 0.0 : right / found.length;
    stdout.writeln(
      '| $minLength | ${found.length} | $right | ${wrong.length} | '
      '${(recall * 100).toStringAsFixed(0)} % | '
      '${(precision * 100).toStringAsFixed(0)} % |',
    );
  }

  for (final entry in wrongBy.entries) {
    if (entry.value.isEmpty) continue;
    stdout.writeln('\nFausses à ${entry.key} caractères :');
    for (final w in entry.value) {
      stdout.writeln('  $w');
    }
  }

  catalogue.close();
}

List<ReadLine> _readLines(File log) {
  if (!log.existsSync()) {
    stderr.writeln('Journal introuvable : ${log.path}');
    exit(66);
  }
  final lines = <ReadLine>[];
  for (final raw in log.readAsLinesSync()) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) continue;
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
    } on FormatException {
      continue;
    }
    if (event['event'] != 'spread_line') continue;
    lines.add(
      ReadLine(
        event['text'] as String,
        (event['top'] as num).toDouble(),
        (event['height'] as num).toDouble(),
      ),
    );
  }
  return lines;
}

class _Hit {
  const _Hit(this.oracleId, this.name, this.matchedName, this.score);
  final String oracleId;
  final String name;
  final String matchedName;
  final double score;
}

class _Catalogue {
  _Catalogue(this._secrets);

  final Map<String, String> _secrets;
  final HttpClient _client = HttpClient();
  final Map<String, _Hit?> _cache = {};
  String? _token;

  String get _key =>
      _secrets['SUPABASE_PUBLISHABLE_KEY'] ?? _secrets['SUPABASE_ANON_KEY']!;

  Future<void> signIn() async {
    final url = Uri.parse(
      '${_secrets['SUPABASE_URL']}/auth/v1/token?grant_type=password',
    );
    final request = await _client.postUrl(url);
    request.headers.set('apikey', _key);
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'email': _secrets['DECKHAND_TEST_EMAIL'],
        'password': _secrets['DECKHAND_TEST_PASSWORD'],
      }),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      stderr.writeln('Connexion refusée (${response.statusCode}) : $body');
      exit(70);
    }
    _token = (jsonDecode(body) as Map)['access_token'] as String;
  }

  Future<_Hit?> search(String query) async {
    if (_cache.containsKey(query)) return _cache[query];

    final url = Uri.parse(
      '${_secrets['SUPABASE_URL']}/rest/v1/rpc/search_cards',
    );
    final request = await _client.postUrl(url);
    request.headers.set('apikey', _key);
    request.headers.set('Authorization', 'Bearer ${_token ?? _key}');
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'q': query, 'max_results': 1}));

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      stderr.writeln('search_cards a répondu ${response.statusCode} : $body');
      exit(70);
    }

    final rows = jsonDecode(body) as List<dynamic>;
    final hit = rows.isEmpty
        ? null
        : _Hit(
            (rows.first as Map)['oracle_id'] as String,
            (rows.first as Map)['name'] as String,
            (rows.first as Map)['matched_name'] as String? ??
                (rows.first as Map)['name'] as String,
            ((rows.first as Map)['score'] as num?)?.toDouble() ?? 0,
          );
    return _cache[query] = hit;
  }

  void close() => _client.close();
}

Map<String, String> _secrets() {
  final file = File('../../.deckhand-secrets/supabase.env');
  if (!file.existsSync()) {
    stderr.writeln('Secrets introuvables : ${file.absolute.path}');
    exit(66);
  }
  final values = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final split = trimmed.indexOf('=');
    if (split < 0) continue;
    values[trimmed.substring(0, split)] = trimmed.substring(split + 1);
  }
  return values;
}
