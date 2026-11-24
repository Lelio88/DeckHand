/// Lit la **ligne basse** d'une carte photographiée : copyright, numéro de
/// collection, code d'extension (issue n°50).
///
/// **Deux entrées, une seule lecture.** La photo d'une carte seule donne son
/// carton à détourer sur l'image entière ([readSingle]) ; un étalement donne un
/// rectangle par carte isolée, recadré puis détouré comme une carte seule
/// ([readBoxes]). Les deux finissent par [_readBand] : la bande du bas
/// rectifiée, lue dans les deux sens où elle est le petit côté du carton, et
/// [bottomBand] garde celui qui porte le copyright.
///
/// Choix mesurés (`integration_test/ligne_basse_test.dart`, `docs/commandes.md`) :
///
/// - **Découpée, jamais lue sur la photo entière** : c'est ce qui la rend
///   lisible.
/// - **Sur un étalement, la pleine résolution est la condition** : 14 numéros
///   justes sur 31 cartes, aucun faux ; à 1600 px, rien. La bande d'une carte
///   parmi dix n'a plus que quelques pixels de haut.
/// - **Marge de 6 % autour du rectangle** : `findCards` serre la forme encrée,
///   la détection fine veut voir le bord du carton.
///
/// Invariants :
///
/// - **Ne peut rien casser.** Toute erreur rend une liste vide ; la carte
///   reste reconnue comme avant, édition à préciser.
/// - **Un rectangle qui porte deux cartes ne lit rien.** La carte détourée
///   doit couvrir [minBoxCoverage] du rectangle : sinon la bande lue pourrait
///   être celle de la voisine, et son numéro désigner à tort une édition de la
///   carte nommée.
/// - **Magic seulement** : les règles de lecture (force et endurance,
///   « n/total ») sont celles de ses cartons.
///
/// ```dart
/// final lignes = await PrintLineReader(lecteur).readBoxes(
///   photo, rectangles, {2, 5}, photoPath,
/// ); // {2: [...], 5: [...]} — les rectangles lisibles seulement
/// ```
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../../config/selected_game.dart';
import '../../../diagnostics/diagnostics.dart';
import '../data/card_text_reader.dart';
import '../domain/card_bounds.dart';
import '../domain/card_edges.dart';
import '../domain/card_segmentation.dart';
import '../domain/print_line_text.dart';

/// Marge ajoutée autour d'un rectangle d'étalement avant de le détourer, en
/// fraction de ses côtés. La même qu'au banc.
const double boxMargin = 0.06;

/// Part du rectangle d'étalement que la carte détourée doit couvrir.
///
/// Une carte isolée remplit son rectangle, marge comprise, à 80 % ou plus ;
/// deux cartes soudées en un rectangle n'en laissent à chacune que la moitié.
/// Le seuil passe entre les deux.
const double minBoxCoverage = 0.6;

class PrintLineReader {
  const PrintLineReader(this._reader, {this.game = Game.magic});

  final CardTextReader _reader;
  final Game game;

  /// La ligne basse de l'unique carte de la photo, ou rien.
  Future<List<String>> readSingle(
    Uint8List photoBytes,
    String photoPath,
  ) async {
    if (game != Game.magic) return const [];
    try {
      final photo = img.decodeImage(photoBytes);
      if (photo == null) return const [];
      final quad = _detect(photo);
      if (quad == null) return const [];
      return await _readBand(photo, quad, photoPath);
    } catch (error) {
      diagnose('print_line_failed', {'error': '$error'});
      return const [];
    }
  }

  /// La ligne basse de chaque rectangle d'[indexes] dans [boxes], rectangles
  /// en fractions de [photo]. Ne rend que ceux qui ont donné une ligne.
  ///
  /// Les rectangles sont lus l'un après l'autre : ML Kit ne lit qu'une image à
  /// la fois, et le fichier temporaire est partagé.
  Future<Map<int, List<String>>> readBoxes(
    img.Image photo,
    List<CardBounds> boxes,
    Iterable<int> indexes,
    String photoPath,
  ) async {
    if (game != Game.magic) return const {};
    final lines = <int, List<String>>{};
    for (final index in indexes) {
      if (index < 0 || index >= boxes.length) continue;
      try {
        final quad = cardInBox(photo, boxes[index]);
        if (quad == null) continue;
        final band = await _readBand(photo, quad, photoPath);
        if (band.isNotEmpty) lines[index] = band;
      } catch (error) {
        diagnose('print_line_failed', {'box': index, 'error': '$error'});
      }
    }
    return lines;
  }

  /// La carte du rectangle [box], détourée dans le repère de [photo] ; nulle
  /// quand rien n'est trouvé ou que la carte ne remplit pas le rectangle.
  CardQuad? cardInBox(img.Image photo, CardBounds box) {
    final x0 = ((box.left - boxMargin * box.width) * photo.width)
        .clamp(0, photo.width - 1)
        .floor();
    final y0 = ((box.top - boxMargin * box.height) * photo.height)
        .clamp(0, photo.height - 1)
        .floor();
    final x1 = ((box.right + boxMargin * box.width) * photo.width)
        .clamp(0, photo.width)
        .ceil();
    final y1 = ((box.bottom + boxMargin * box.height) * photo.height)
        .clamp(0, photo.height)
        .ceil();
    if (x1 - x0 < 2 || y1 - y0 < 2) return null;

    final crop = img.copyCrop(
      photo,
      x: x0,
      y: y0,
      width: x1 - x0,
      height: y1 - y0,
    );
    final quad = _detect(crop);
    if (quad == null) return null;
    final boxArea = box.width * photo.width * box.height * photo.height;
    if (boxArea <= 0 || _area(quad) < minBoxCoverage * boxArea) {
      diagnose('print_line_box_skipped', {
        'coverage': boxArea <= 0 ? null : _area(quad) / boxArea,
      });
      return null;
    }
    Point shift(Point p) => (x: p.x + x0, y: p.y + y0);
    return CardQuad(
      topLeft: shift(quad.topLeft),
      topRight: shift(quad.topRight),
      bottomRight: shift(quad.bottomRight),
      bottomLeft: shift(quad.bottomLeft),
    );
  }

  /// La détection du scan photo, à l'identique : droites et clarté, le plus
  /// grand rectangle plausible des deux.
  CardQuad? _detect(img.Image image) => largestPlausible(
    [findCardByEdges(image, game: game.id), findCard(image, game: game.id)],
    width: image.width,
    height: image.height,
  );

  /// La bande basse de [quad], lue dans les deux sens où elle est le petit
  /// côté du carton ; le sens qui porte le copyright, ou rien.
  Future<List<String>> _readBand(
    img.Image photo,
    CardQuad quad,
    String photoPath,
  ) async {
    final band = File('$photoPath.ligne-basse.png');
    try {
      final byTurn = <int, List<String>>{};
      for (var turn = 0; turn < 4; turn++) {
        final q = quad.quarterTurned(turn);
        final width = _distance(q.topLeft, q.topRight);
        final height = _distance(q.topLeft, q.bottomLeft);
        if (width > height) continue;
        final pixels = sampleArt(
          photo,
          q,
          printLineBand,
          width: width.round(),
          height: (height * (printLineBand.bottom - printLineBand.top)).round(),
        );
        band.writeAsBytesSync(img.encodePng(pixels));
        byTurn[turn] = [
          for (final line in await _reader.readLines(band.path)) line.text,
        ];
      }
      final turn = bottomBand(byTurn);
      diagnose('print_line', {
        'turn': turn,
        'lines': turn == null ? null : byTurn[turn],
      });
      return turn == null ? const [] : byTurn[turn]!;
    } finally {
      try {
        if (band.existsSync()) band.deleteSync();
      } on FileSystemException {
        // Un fichier temporaire resté là ne gêne rien : le cache l'emportera.
      }
    }
  }

  static double _distance(Point a, Point b) {
    final dx = a.x - b.x, dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Aire du quadrilatère, par la formule du lacet.
  static double _area(CardQuad q) {
    final p = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft];
    var sum = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4];
      sum += a.x * b.y - b.x * a.y;
    }
    return sum.abs() / 2;
  }
}
