/// Balaye le seuil de taille qui sépare un nom de carte de son texte de règles.
///
/// **Pourquoi hors ligne plutôt qu'en réglant l'application.** Ajuster le seuil
/// dans le code, reconstruire, réinstaller et rephotographier donne un chiffre
/// par essai — et chaque essai porte sur une photo différente, donc sur un
/// problème différent. Ici la photo est prise **une fois**, les lignes qu'elle a
/// produites sont rejouées à tous les seuils, et l'on compare des colonnes d'un
/// même tableau. C'est la différence entre régler et mesurer.
///
/// Le filtrage est celui du produit, importé tel quel : aucune réimplémentation,
/// donc aucune dérive possible entre ce qui est mesuré et ce qui s'exécute.
///
/// Usage :
///   1. construire un APK de mesure :
///      `flutter build apk --release --dart-define=DECKHAND_DIAG=true …`
///   2. capturer pendant le scan :
///      `adb logcat -c && adb logcat | grep DHDIAG > mesure.log`
///   3. écrire la vérité terrain — une carte étalée par ligne, dans n'importe
///      quelle langue, l'orthographe exacte n'est pas requise
///   4. `dart run tool/sweep_spread_threshold.dart mesure.log verite.txt`
///
/// Les noms attendus sont eux aussi résolus par le catalogue : la comparaison
/// porte donc sur des identifiants, et « Foudre » vaut « Lightning Bolt ».
library;

import 'dart:convert';
import 'dart:io';

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/scan/domain/spread_names.dart';

/// Seuils essayés. Zéro sert de témoin : c'est le comportement sans filtre,
/// celui qui proposait huit cartes pour six étalées.
const List<double> _sweep = [
  0, 1.00, 1.05, 1.10, 1.15, 1.20, 1.25, 1.30, 1.35, 1.40, 1.50, 1.60, 1.75, 2.00,
];

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage : dart run tool/sweep_spread_threshold.dart <mesure.log> <verite.txt>',
    );
    exit(64);
  }

  final lines = _readLines(File(args[0]));
  if (lines.isEmpty) {
    stderr.writeln(
      'Aucun événement spread_line dans ${args[0]}.\n'
      "L'APK a-t-il été construit avec --dart-define=DECKHAND_DIAG=true ?",
    );
    exit(65);
  }

  final catalogue = _Catalogue(_secrets());
  await catalogue.signIn();

  final expectedNames = File(args[1])
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();

  final expected = <String>{};
  for (final name in expectedNames) {
    final hit = await catalogue.search(name);
    if (hit == null) {
      stderr.writeln('Vérité terrain introuvable au catalogue : « $name »');
      exit(65);
    }
    expected.add(hit.oracleId);
  }

  stdout.writeln('${lines.length} lignes lues, ${expected.length} cartes étalées.');
  stdout.writeln(_heightProfile(lines));
  stdout.writeln('');

  final rows = <String>[];
  Map<double, _Verdict> verdicts = {};
  for (final ratio in _sweep) {
    final verdict = await _measure(lines, ratio, expected, catalogue);
    verdicts[ratio] = verdict;
    rows.add(verdict.row(ratio));
  }

  stdout.writeln('| seuil | proposées | justes | fausses | manquées | rappel | précision |');
  stdout.writeln('|---|---|---|---|---|---|---|');
  rows.forEach(stdout.writeln);
  stdout.writeln('');

  // Deux détails, et leur écart est le vrai sujet : ce que le filtre écarte,
  // et ce qu'il jette au passage. Un filtre qui gagnerait deux fausses en
  // perdant deux vraies ne vaudrait pas son coût.
  for (final ratio in [0.0, nameHeightRatio]) {
    final verdict = verdicts[ratio];
    if (verdict == null) continue;
    stdout.writeln(ratio == 0 ? 'Sans filtre :' : 'Au seuil $ratio :');
    for (final wrong in verdict.wrong) {
      stdout.writeln('  fausse   « ${wrong.read} » → ${wrong.matched}');
    }
    for (final missed in verdict.missedNames) {
      stdout.writeln('  manquée  $missed');
    }
    stdout.writeln('');
  }

  catalogue.close();
}

/// Une ligne lue par l'appareil, telle que le journal l'a consignée.
List<ReadLine> _readLines(File log) {
  if (!log.existsSync()) {
    stderr.writeln('Journal introuvable : ${log.path}');
    exit(66);
  }

  final lines = <ReadLine>[];
  for (final raw in log.readAsLinesSync()) {
    // On reconnaît l'événement à son contenu, pas à son préfixe : le journal
    // arrive noyé dans le tampon du système, dont l'en-tête varie d'un appareil
    // et d'une version à l'autre. Ce qui ne varie pas, c'est le JSON.
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) continue;
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
    } on FormatException {
      // Une ligne coupée par le tampon se rencontre, et n'a rien d'alarmant
      // tant qu'elle reste rare.
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

/// Répartition des hauteurs lues.
///
/// **C'est le chiffre qui décide s'il y a un seuil à trouver.** Le filtre
/// suppose deux populations de texte bien séparées ; si les hauteurs se
/// pressent autour d'une seule valeur — le cas d'une photo prise d'assez loin
/// pour que seuls les noms soient lisibles — aucun seuil ne les départage, et
/// c'est le principe même du filtre qu'il faut revoir.
String _heightProfile(List<ReadLine> lines) {
  final heights = lines.map((l) => l.height).toList()..sort();
  String at(double q) => heights[(heights.length * q).clamp(0, heights.length - 1).toInt()]
      .toStringAsFixed(4);
  final median = heights[heights.length ~/ 2];
  return 'Hauteurs — min ${at(0)} · q1 ${at(0.25)} · médiane ${at(0.5)} · '
      'q3 ${at(0.75)} · max ${at(0.999)}\n'
      'Rapport max/médiane : ${(heights.last / median).toStringAsFixed(2)}';
}

class _Verdict {
  _Verdict(this.proposed, this.right, this.wrong, this.missedNames);

  final int proposed;
  final Set<String> right;
  final List<({String read, String matched})> wrong;
  final List<String> missedNames;

  String row(double ratio) {
    final total = right.length + missedNames.length;
    final recall = total == 0 ? 0.0 : right.length / total;
    final precision = proposed == 0 ? 0.0 : right.length / proposed;
    final label = ratio == 0 ? 'sans filtre' : ratio.toStringAsFixed(2);
    return '| $label | $proposed | ${right.length} | ${wrong.length} | '
        '${missedNames.length} | ${(recall * 100).toStringAsFixed(0)} % | '
        '${(precision * 100).toStringAsFixed(0)} % |';
  }
}

Future<_Verdict> _measure(
  List<ReadLine> lines,
  double ratio,
  Set<String> expected,
  _Catalogue catalogue,
) async {
  final candidates = spreadNameCandidates(lines, heightRatio: ratio);

  final found = <String, String>{}; // oracleId → ligne lue qui l'a produit
  final wrong = <({String read, String matched})>[];

  for (final candidate in candidates) {
    final hit = await catalogue.search(candidate.text);
    if (hit == null || hit.score < spreadScoreThreshold) continue;
    if (found.containsKey(hit.oracleId)) continue;
    found[hit.oracleId] = candidate.text;
    if (!expected.contains(hit.oracleId)) {
      wrong.add((read: candidate.text, matched: hit.name));
    }
  }

  final right = found.keys.where(expected.contains).toSet();
  final missed = <String>[];
  for (final id in expected) {
    if (!found.containsKey(id)) missed.add(catalogue.nameOf(id));
  }

  return _Verdict(found.length, right, wrong, missed);
}

/// Une correspondance du catalogue, réduite à ce que la mesure exige.
class _Hit {
  const _Hit(this.oracleId, this.name, this.score);

  final String oracleId;
  final String name;
  final double score;
}

/// Accès à `search_cards`, avec mémoire des réponses.
///
/// **Le cache n'est pas un raffinement.** Quatorze seuils sur une photo de
/// soixante lignes feraient huit cents requêtes pour cent textes distincts ;
/// pire, une recherche relancée pourrait répondre autrement d'un seuil à
/// l'autre et brouiller la comparaison. Une réponse par texte, réutilisée
/// partout, garantit que seul le seuil varie.
class _Catalogue {
  _Catalogue(this._secrets);

  final Map<String, String> _secrets;
  final HttpClient _client = HttpClient();
  final Map<String, _Hit?> _cache = {};
  final Map<String, String> _names = {};

  /// Jeton du compte de test, dans lequel `search_cards` se déroule.
  String? _token;

  String get _key =>
      _secrets['SUPABASE_PUBLISHABLE_KEY'] ?? _secrets['SUPABASE_ANON_KEY']!;

  String nameOf(String oracleId) => _names[oracleId] ?? oracleId;

  /// Ouvre une session, sans quoi la recherche est refusée.
  ///
  /// **`search_cards` n'est pas anonyme**, contrairement à ce qu'on pourrait
  /// croire d'une fonction de catalogue : elle rend aussi le nombre
  /// d'exemplaires déjà possédés, donc lit `collection_items`, table protégée.
  /// Sans session, PostgREST répond 401. La mesure doit donc s'authentifier
  /// comme le fait l'application.
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

    final url = Uri.parse('${_secrets['SUPABASE_URL']}/rest/v1/rpc/search_cards');

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
            ((rows.first as Map)['score'] as num?)?.toDouble() ?? 0,
          );
    if (hit != null) _names[hit.oracleId] = hit.name;
    return _cache[query] = hit;
  }

  void close() => _client.close();
}

/// Lit le coffre hors dépôt (garde-fou §IV.7).
///
/// Le chemin remonte de deux crans : l'outil se lance depuis `app/`, et le
/// coffre est voisin du dépôt, pas dedans — c'est précisément ce qui le tient à
/// l'abri d'un commit.
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
