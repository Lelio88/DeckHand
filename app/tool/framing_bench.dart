/// Banc de cadrage, côté Dart : que coûte une photo prise à main levée ?
///
/// **Jumeau de `api/app/measure/framing_bench.py`, et pourquoi il en faut un.**
/// Le banc Python mesure la détection de bords du jumeau Python. Or le code qui
/// tourne sur le téléphone est celui-ci, et c'est lui qu'il faut départager
/// quand plusieurs approches de détection sont en concurrence. Porter quatre
/// approches vers Python multiplierait les occasions de se tromper ; porter le
/// banc une fois ne les multiplie pas.
///
/// **Les photos sont synthétiques, et c'est un choix.** Une photo réelle porte
/// sa vérité terrain dans la tête de celui qui l'a prise ; une photo composée la
/// porte dans ses paramètres. On sait exactement de combien la carte a été
/// décalée, tournée, agrandie — donc à quel écart correspond quel échec. C'est
/// le seul moyen de mesurer une détection sans posséder mille cartes.
///
/// **Ce que ce banc ne prouve pas.** Une photo composée n'a ni flou de bougé, ni
/// mise au point ratée, ni reflet sur un protège-carte ; sa table est un grain
/// synthétique traversé d'un dégradé, pas un plateau à lames de bois. Un gain
/// mesuré ici est une condition nécessaire, jamais suffisante : la seule preuve
/// reste une carte de papier devant l'objectif. Le banc sert à **éliminer** ce
/// qui échoue et à comparer ce qui passe, pas à décréter qu'une approche marche.
///
/// **Le tirage vient de la base**, exporté par
/// `python -m app.measure.export_framing_set`. Même filtre et même ordre que le
/// banc Python : deux bancs qui mesureraient des cartes différentes ne seraient
/// pas comparables.
///
/// Les images sont mises en cache sur le disque. Scryfall demande un débit bas
/// et un `User-Agent` descriptif (`CLAUDE.md` §IV.4) : le cache fait qu'un banc
/// rejoué n'émet aucune requête, ce qui compte quand on le rejoue une fois par
/// approche.
///
/// Usage :
/// ```
/// dart run tool/framing_bench.dart              # détection des bords
/// dart run tool/framing_bench.dart --centered   # cadrage centré, pour comparer
/// dart run tool/framing_bench.dart --cards 12   # échantillon plus petit
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_framing.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:image/image.dart' as img;

/// Seuil de confiance du scan, en bits. Au-delà, la carte est « perdue » : ce
/// n'est pas une erreur silencieuse — l'application dit son doute —, mais elle
/// ne reconnaît rien.
const int confidence = 12;

/// Un régime de prise de vue, décrit par ce que la main fait de travers.
class Shot {
  const Shot(
    this.name,
    this.margin,
    this.offset,
    this.rotation, {
    this.lighting = 18,
  });

  final String name;

  /// Marge de table autour de la carte, en fraction de sa hauteur.
  final double margin;

  /// Décalage du centre, en fraction de la largeur de la carte.
  final double offset;

  /// Rotation, en degrés.
  final double rotation;

  /// Amplitude du dégradé d'éclairage sur la table, en niveaux de gris.
  ///
  /// **Ajouté parce que les cinq régimes d'origine ne reproduisaient pas le
  /// défaut mesuré sur une carte de papier.** À ±18, la table reste partout
  /// plus claire que le seuil qui la sépare du carton, et la détection réussit
  /// cinq régimes sur cinq — alors qu'elle échoue sur une vraie photo. Le banc
  /// ne mesurait donc que le cadrage, jamais l'éclairage, et aucune amélioration
  /// de la détection n'y aurait été visible.
  ///
  /// Ce que ce paramètre reproduit est banal : une lampe de côté, une fenêtre à
  /// gauche. Il fait passer une part de la table sous le seuil de carton, elle
  /// touche la carte, la recherche de forme réunit les deux, et la boîte
  /// englobante devient l'image entière — exactement la chaîne observée sur
  /// la photo réelle.
  final double lighting;
}

/// Du cadrage parfait — que personne n'atteint — au cadrage négligent.
/// Valeurs identiques au banc Python, sans quoi les deux ne se compareraient
/// pas. Les intermédiaires encadrent ce qu'une main produit réellement.
/// Les trois derniers reprennent les cadrages courants sous un éclairage
/// latéral marqué — le cas qu'une vraie photo a mis au jour, et que les cinq
/// premiers ne couvrent pas.
const List<Shot> regimes = [
  Shot('parfait', 0.00, 0.00, 0.0),
  Shot('soigné', 0.03, 0.01, 0.5),
  Shot('ordinaire', 0.08, 0.03, 2.0),
  Shot('à la volée', 0.15, 0.06, 5.0),
  Shot('négligent', 0.25, 0.10, 9.0),
  Shot('soigné + lampe', 0.03, 0.01, 0.5, lighting: 60),
  Shot('ordinaire + lampe', 0.08, 0.03, 2.0, lighting: 60),
  Shot('négligent + lampe', 0.25, 0.10, 9.0, lighting: 60),
];

Future<void> main(List<String> args) async {
  final centered = args.contains('--centered');
  final limit = int.tryParse(_option(args, '--cards') ?? '') ?? 40;

  final root = File.fromUri(Platform.script).parent;
  final setFile = File('${root.path}/${_option(args, '--set') ?? 'framing_set.json'}');
  if (!setFile.existsSync()) {
    stderr.writeln(
      'tirage absent : ${setFile.path}\n'
      'lancer d\'abord : cd api && python -m app.measure.export_framing_set',
    );
    exitCode = 66;
    return;
  }

  final entries = (jsonDecode(setFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>()
      .take(limit)
      .toList();

  final cache = Directory('${root.path}/.framing_cache')
    ..createSync(recursive: true);

  stdout.writeln(
    'Banc de cadrage — ${entries.length} cartes × ${regimes.length} régimes — '
    '${centered ? 'cadrage centré' : 'détection des bords'}',
  );

  final distances = {for (final shot in regimes) shot.name: <int>[]};
  var gaveUp = 0;
  var skipped = 0;

  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final card = await _cardImage(entry, cache);
    if (card == null) {
      skipped++;
      continue;
    }
    final expected = ArtHash.fromHex(entry['hash'] as String);
    // **Le tirage dit ce qu'il contient.** Le gabarit et l'orientation se
    // déduisent du jeu et de la disposition, au lieu d'être supposés : c'est ce
    // qui permet de mesurer les cartes couchées, que le banc ignorait.
    final frame = _frameOf(entry);
    final couchee = frame == CardFrame.riftboundWide;
    final game = entry['game'] as String? ?? 'magic';
    // La carte synthétique est découpée aux proportions du jeu tiré, et non à
    // celles de Magic : composer une carte au mauvais format mesurerait la
    // détection sur un objet qui n'existe pas.
    final aspect = cardAspectFor(game);

    for (final shot in regimes) {
      // Une graine par (carte, régime) : le grain de la table et le tirage sont
      // ainsi identiques d'une exécution à l'autre, donc d'une approche à
      // l'autre. Sans cela, deux mesures différeraient par leur bruit.
      final photo = _compose(
        card,
        shot,
        math.Random(20260810 + i * 17),
        couchee: couchee,
        aspect: aspect,
      );
      final quad = centered ? null : findCard(photo, game: game);
      final img.Image art;
      if (quad == null) {
        if (!centered) gaveUp++;
        art = cropArt(cropToCardFrame(photo, game: game), frame);
      } else {
        art = sampleArt(photo, quad, frame.box);
      }
      distances[shot.name]!.add(_hamming(computeArtHash(art), expected));
    }
    stdout.write('  ${i + 1}/${entries.length}\r');
  }
  stdout.write('${' ' * 24}\r');

  _report(distances, gaveUp, skipped);
}

/// Distance de Hamming entre deux empreintes.
int _hamming(ArtHash a, ArtHash b) {
  var total = 0;
  for (var i = 0; i < a.bytes.length; i++) {
    var x = a.bytes[i] ^ b.bytes[i];
    while (x != 0) {
      total += x & 1;
      x >>= 1;
    }
  }
  return total;
}

/// Carte entière, depuis le cache disque ou depuis Scryfall.
Future<img.Image?> _cardImage(
  Map<String, dynamic> entry,
  Directory cache,
) async {
  final file = File('${cache.path}/${entry['id']}.jpg');
  if (!file.existsSync()) {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(entry['url'] as String));
      // Descriptif, comme le garde-fou l'exige : une source doit pouvoir
      // identifier qui l'interroge et pourquoi.
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'DeckHand/0.1 (https://github.com/Lelio88/DeckHand)',
      );
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = await response.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      file.writeAsBytesSync(bytes);
      // Débit bas : le banc n'a aucune raison d'être pressé, et la source en a
      // de nous limiter.
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }
  try {
    return img.decodeImage(file.readAsBytesSync());
  } on Object {
    return null;
  }
}

/// Fond de table texturé.
///
/// Un aplat uni rendrait la détection triviale et le banc menteur. Le grain
/// met en difficulté les approches par région ; le dégradé diagonal imite
/// l'éclairage inégal, qui est l'écueil mesuré sur une vraie photo — un coin de
/// table plus sombre passe sous le seuil de carton et fusionne avec la carte.
img.Image _tableBackground(
  int width,
  int height,
  math.Random rng,
  double lighting,
) {
  final canvas = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final grain = rng.nextInt(29) - 14;
      final gradient = (-lighting + 2 * lighting * x / (width - 1)).round();
      canvas.setPixelRgb(
        x,
        y,
        (168 + grain + gradient).clamp(0, 255),
        (150 + grain + gradient).clamp(0, 255),
        (124 + grain + gradient).clamp(0, 255),
      );
    }
  }
  return canvas;
}

/// Photo synthétique : la carte posée sur une table, vue de travers.
img.Image _compose(
  img.Image source,
  Shot shot,
  math.Random rng, {
  bool couchee = false,
  double aspect = defaultCardAspect,
}) {
  // Le grand côté fixe la taille, quelle que soit l'orientation : une carte
  // couchée occupe la même surface qu'une carte debout, elle est seulement
  // tournée d'un quart de tour.
  const long = 900;
  final court = (long * aspect).round();
  final cardWidth = couchee ? long : court;
  final cardHeight = couchee ? court : long;
  var card = img.copyResize(
    source,
    width: cardWidth,
    height: cardHeight,
    interpolation: img.Interpolation.cubic,
  );

  final margin = (long * shot.margin).round();
  final photoWidth = cardWidth + 2 * margin;
  final photoHeight = cardHeight + 2 * margin;
  final photo = _tableBackground(photoWidth, photoHeight, rng, shot.lighting);

  if (shot.rotation != 0) {
    // **Le fond de la rotation doit être transparent, sans quoi le banc mesure
    // un artefact.** Une rotation sur fond opaque remplit les coins libérés
    // d'une couleur unie ; ce losange ceignant la carte est exactement ce qu'un
    // masque de carte cherche, et la détection trouve alors les coins du
    // losange au lieu de ceux de la carte. Le banc Python a rencontré ce piège
    // et le documente ; il se transpose tel quel.
    card = img.copyRotate(
      card.convert(numChannels: 4),
      angle: shot.rotation,
      interpolation: img.Interpolation.cubic,
    );
  }

  final dx = (cardWidth * shot.offset).round();
  final dy = (cardHeight * shot.offset * aspect).round();
  img.compositeImage(
    photo,
    card,
    dstX: (photoWidth - card.width) ~/ 2 + dx,
    dstY: (photoHeight - card.height) ~/ 2 + dy,
  );

  // La compression est celle d'un téléphone, pas celle d'un scanner : elle fait
  // partie de ce que la détection doit encaisser.
  return img.decodeJpg(img.encodeJpg(photo, quality: 78))!;
}

void _report(Map<String, List<int>> distances, int gaveUp, int skipped) {
  stdout.writeln('\nSeuil de confiance : $confidence bits');
  if (gaveUp > 0) {
    stdout.writeln(
      'détections abandonnées (repli sur le cadrage centré) : $gaveUp',
    );
  }
  if (skipped > 0) {
    stdout.writeln('cartes non téléchargées : $skipped');
  }
  stdout.writeln('');
  stdout.writeln(
    '${'régime'.padRight(24)}${'médiane'.padLeft(8)}'
    '${'reconnues'.padLeft(12)}${'perdues'.padLeft(10)}',
  );
  for (final shot in regimes) {
    final values = [...distances[shot.name]!]..sort();
    if (values.isEmpty) continue;
    final median = values[values.length ~/ 2];
    final found = values.where((v) => v <= confidence).length;
    stdout.writeln(
      '${shot.name.padRight(24)}${median.toString().padLeft(8)}'
      '${'$found/${values.length}'.padLeft(12)}'
      '${(values.length - found).toString().padLeft(10)}',
    );
  }
}

/// Gabarit à appliquer, d'après ce que le tirage déclare.
///
/// Le banc mesurait Magic seul et prenait `modern` pour acquis. Un tirage porte
/// désormais son jeu et sa disposition, ce qui est la seule façon de mesurer un
/// gabarit qui n'est pas celui par défaut — à commencer par les cartes
/// couchées, dont le cadre est mesuré depuis longtemps sans avoir jamais servi.
CardFrame _frameOf(Map<String, dynamic> entry) {
  final game = entry['game'] as String? ?? 'magic';
  final layout = entry['layout'] as String? ?? 'normal';
  if (game != 'riftbound') return CardFrame.modern;
  return layout == 'landscape' ? CardFrame.riftboundWide : CardFrame.riftbound;
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
