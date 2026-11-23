/// Ce que l'OCR lit sur la **ligne basse** d'une carte, en pleine résolution.
///
/// **Le volet faisabilité de l'issue n°50.** Le banc de catalogue
/// (`api/app/measure/edition_from_print_line.py`) dit que l'année du copyright
/// et le numéro de collection, **lus sans faute**, trancheraient environ six
/// cases sur dix d'avant M15. Reste à savoir si ML Kit les lit. Sur la photo
/// d'étalement de l'issue, réduite à 1600 px comme le fait `image_picker`, il
/// n'en avait lu aucune ; en pleine résolution, une sur neuf.
///
/// Ce banc **découpe la bande basse** du carton détouré — les 10 % du bas, là
/// où vivent copyright, numéro et total —, la redresse par homographie
/// (`sampleArt`, la lecture du scan), et la donne seule à ML Kit, à deux
/// échelles. La carte peut être couchée ou à l'envers sur la photo : les quatre
/// quarts de tour sont lus, et c'est l'analyse qui reconnaîtra le bon.
///
/// **La photo n'est pas réduite.** C'est tout l'objet de la mesure : savoir ce
/// que gagnerait l'étalement à lever `maxWidth: 1600`. Pousser les photos
/// d'origine, pas des copies réduites.
///
/// **Aucune assertion.** Sa sortie est son résultat : des lignes préfixées
/// `BANDE`, que `api/app/measure/ligne_basse.py` confronte à la vérité du banc
/// (`carte-seule/attendu.csv`, extension et numéro lus à l'œil).
///
/// ```
/// # l'application installée d'abord (flutter test l'installe, ou adb install)
/// adb push ../.deckhand-bench/photos/carte-seule/. /data/local/tmp/bench/
/// adb shell run-as app.deckhand.debug sh -c \
///   'mkdir -p files/bench && cp /data/local/tmp/bench/*.jpg files/bench/'
/// flutter test integration_test/ligne_basse_test.dart -d <appareil> > ligne_basse.log
/// cd ../api && .venv/Scripts/python -m app.measure.ligne_basse ../app/ligne_basse.log
/// ```
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/config/ocr_script.dart';
import 'package:deckhand/src/features/scan/data/card_text_reader.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:deckhand/src/features/scan/domain/card_segmentation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Ne garder que les photos dont le nom contient ce texte. Vide : toutes.
const String _filtre = String.fromEnvironment('DECKHAND_PHOTOS');

/// La bande lue, en proportions du carton : copyright, numéro et total.
const _bande = (left: 0.0, top: 0.90, right: 1.0, bottom: 1.0);

/// Échelles de la bande, en multiples de la taille du carton sur la photo.
const _echelles = [1, 2];

/// La borne `maxWidth` qu'`image_picker` applique aujourd'hui à l'étalement.
const _largeurPicker = 1600;

/// Mode étalement : chaque carte isolée par `findCards` est recadrée, puis
/// détourée comme une carte seule (`files/etalement` au lieu de `files/bench`).
/// Une seule échelle : sur la carte seule, ×2 n'apportait que 2 photos sur 44.
const bool _etalement = bool.fromEnvironment('DECKHAND_ETALEMENT');

/// Marge ajoutée autour du rectangle d'une carte d'étalement avant de la
/// détourer : `findCards` serre la forme, la détection fine veut voir le bord.
const _marge = 0.06;

/// Les cartes de la photo, chacune avec son nom de ligne et ses coins.
List<(String, CardQuad)> _cartes(img.Image image, String nom) {
  CardQuad? detourer(img.Image i) => largestPlausible(
    [findCardByEdges(i), findCard(i)],
    width: i.width,
    height: i.height,
  );
  if (!_etalement) {
    final quad = detourer(image);
    return quad == null ? const [] : [(nom, quad)];
  }
  final cartes = <(String, CardQuad)>[];
  final boites = singleCards(findCards(image));
  for (final (i, b) in boites.indexed) {
    final x0 = ((b.left - _marge * b.width) * image.width)
        .clamp(0, image.width - 1)
        .floor();
    final y0 = ((b.top - _marge * b.height) * image.height)
        .clamp(0, image.height - 1)
        .floor();
    final x1 = ((b.right + _marge * b.width) * image.width)
        .clamp(0, image.width)
        .ceil();
    final y1 = ((b.bottom + _marge * b.height) * image.height)
        .clamp(0, image.height)
        .ceil();
    final recadre = img.copyCrop(
      image,
      x: x0,
      y: y0,
      width: x1 - x0,
      height: y1 - y0,
    );
    final q = detourer(recadre);
    if (q == null) continue;
    Point decale(Point p) => (x: p.x + x0, y: p.y + y0);
    cartes.add((
      '$nom#$i',
      CardQuad(
        topLeft: decale(q.topLeft),
        topRight: decale(q.topRight),
        bottomRight: decale(q.bottomRight),
        bottomLeft: decale(q.bottomLeft),
      ),
    ));
  }
  return cartes;
}

double _longueur(Point a, Point b) {
  final dx = a.x - b.x, dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ce que ML Kit lit sur la bande basse de chaque carte', (
    tester,
  ) async {
    // **Le dossier privé de l'application, garni par `run-as`.** Un fichier
    // poussé par `adb` dans `Android/data/<paquet>` appartient à `shell`
    // (groupe `ext_data_rw`) tant que l'application n'y a pas créé son dossier
    // elle-même : sur un émulateur neuf, elle ne peut pas le lire
    // (`PathAccessException`). `run-as`, permis sur une version de débogage,
    // copie au contraire sous l'identité de l'application.
    final support = await getApplicationSupportDirectory();
    final dossier = Directory(
      '${support.path}/${_etalement ? 'etalement' : 'bench'}',
    );
    final photos =
        dossier
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.jpg'))
            .where((f) => _filtre.isEmpty || f.path.contains(_filtre))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(photos, isNotEmpty, reason: 'aucune photo dans ${dossier.path}');
    print('BANDE debut ${photos.length} photo(s)');

    final temp = await getTemporaryDirectory();
    final lecteur = CardTextReader(script: OcrScript.latin);

    for (final photo in photos) {
      final nom = photo.uri.pathSegments.last;
      final pleine = img.decodeImage(await photo.readAsBytes());
      if (pleine == null) {
        print('BANDE $nom illisible');
        continue;
      }
      // Deux sources : la photo d'origine (« x ») et la même réduite comme le
      // fait `image_picker` aujourd'hui (« r ») — largeur 1600, au plus proche
      // voisin. Leur écart dit ce que gagnerait l'étalement à lever la borne.
      final sources = {
        'x': pleine,
        'r': pleine.width > _largeurPicker
            ? img.copyResize(
                pleine,
                width: _largeurPicker,
                interpolation: img.Interpolation.nearest,
              )
            : pleine,
      };

      for (final MapEntry(key: source, value: image) in sources.entries) {
        // La détection du scan photo (`ScanService`), à l'identique : droites
        // et clarté, le plus grand rectangle plausible des deux — appliquée à
        // chaque carte recadrée en mode étalement.
        final cartes = _cartes(image, nom);
        if (cartes.isEmpty) {
          print('BANDE $nom $source sans-carte ${image.width}x${image.height}');
          continue;
        }
        for (final (etiquette, quad) in cartes) {
          for (var tour = 0; tour < 4; tour++) {
            final q = quad.quarterTurned(tour);
            final largeur = _longueur(q.topLeft, q.topRight);
            final hauteur = _longueur(q.topLeft, q.bottomLeft);
            for (final echelle in _etalement ? const [1] : _echelles) {
              final w = (largeur * echelle).round();
              final h = (hauteur * (_bande.bottom - _bande.top) * echelle)
                  .round();
              if (w < 8 || h < 8) continue;
              final bande = sampleArt(image, q, _bande, width: w, height: h);
              final fichier = File('${temp.path}/bande.png')
                ..writeAsBytesSync(img.encodePng(bande));
              final lignes = await lecteur.readLines(fichier.path);
              final cle = '$etiquette tour=$tour $source$echelle';
              print('BANDE $cle ${w}x$h lignes=${lignes.length}');
              for (final ligne in lignes) {
                print('BANDE $cle « ${ligne.text} »');
              }
            }
          }
        }
      }
    }
    await lecteur.dispose();
    print('BANDE fin');
  }, timeout: const Timeout(Duration(minutes: 60)));
}
