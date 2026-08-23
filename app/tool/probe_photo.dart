/// Rejoue le pipeline d'empreinte sur une photo, et **montre** ce qu'il découpe.
///
/// **Pourquoi cet outil existe.** Quand la reconnaissance par illustration
/// échoue, le journal de l'appareil dit la distance et le gabarit vainqueur,
/// jamais *où* l'illustration a été prélevée. Or c'est la seule chose qui
/// distingue une photo dégradée d'un découpage pris à côté — et les deux
/// appellent des travaux opposés : améliorer la prise de vue, ou remesurer le
/// gabarit.
///
/// L'outil écrit donc sur le disque la zone effectivement hachée. Un coup d'œil
/// suffit alors : si le rectangle encadre l'illustration, le gabarit est bon et
/// c'est la photo qui pèche ; s'il mord sur le cadre ou le texte, c'est le
/// gabarit.
///
/// Il utilise **le code de production**, jamais une copie : `findCard`,
/// `artHashCandidatesInQuad` et `computeArtHash` sont ceux de l'application.
/// Une reproduction approchée mesurerait autre chose que ce qui tourne.
///
/// Usage :
/// ```
/// dart run tool/probe_photo.dart <photo.jpg> [--game riftbound] [--out <dossier>]
/// ```
library;

import 'dart:io';

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:deckhand/src/features/scan/domain/card_framing.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage : dart run tool/probe_photo.dart <photo> [--game riftbound] '
      '[--out <dossier>]',
    );
    exitCode = 64;
    return;
  }

  final path = args.first;
  final game = _option(args, '--game') ?? 'riftbound';
  final out = _option(args, '--out') ?? Directory.systemTemp.path;

  Directory(out).createSync(recursive: true);
  final bytes = File(path).readAsBytesSync();
  final photo = img.decodeImage(bytes);
  if (photo == null) {
    stderr.writeln('image illisible : $path');
    exitCode = 65;
    return;
  }

  stdout.writeln('photo   ${photo.width} x ${photo.height}');

  // Ce que la détection voit avant de conclure. C'est lui qui décide de tout ;
  // le regarder est le seul moyen de comprendre un échec.
  final seen = debugDetection(photo);
  final view = img.Image(width: seen.width, height: seen.height);
  var on = 0;
  for (var i = 0; i < seen.mask.length; i++) {
    if (seen.mask[i] != 0) on++;
    // Trois niveaux : la forme retenue en blanc, le reste du masque en gris,
    // le fond en noir. La différence entre les deux premiers est précisément
    // ce que la recherche de composante a décidé de garder.
    final kept = (seen.shape?[i] ?? 0) != 0;
    final v = kept ? 255 : (seen.mask[i] != 0 ? 110 : 0);
    view.setPixelRgb(i % seen.width, i ~/ seen.width, v, v, v);
  }
  File('$out/masque.png').writeAsBytesSync(img.encodePng(view));
  stdout.writeln(
    'masque  ${(on / seen.mask.length * 100).toStringAsFixed(1)} % de l\'image '
    'tenu pour du carton  ->  $out/masque.png',
  );
  // **Le discriminant qui manque à la détection.** Une carte est un rectangle
  // plein : sa forme remplit sa boîte englobante. Une forme qui déborde sur le
  // décor garde la boîte de l'image entière tout en la remplissant mal.
  stdout.writeln(
    'forme   remplit ${(seen.fill * 100).toStringAsFixed(1)} % '
    'de sa boîte englobante',
  );

  // Exactement ce que fait `ScanService._byArt` : les coins d'abord, le cadre
  // centré à défaut.
  // **La chaîne de production, les deux détections comprises.** Cet outil
  // annonçait « coins non détectés » là où le service, lui, trouvait la carte :
  // il ne connaissait que le masque par clarté et ignorait la détection par
  // droites, arrivée depuis. Une sonde qui ne suit pas la production ne sonde
  // rien.
  final quad = largestPlausible([
    findCardByEdges(photo, game: game),
    findCard(photo, game: game),
  ], width: photo.width, height: photo.height);
  if (quad == null) {
    stdout.writeln('coins   non détectés — repli sur le cadrage centré');
  } else {
    stdout.writeln(
      'coins   détectés, rapport ${quad.aspect.toStringAsFixed(3)} '
      '(carte : ${cardAspectFor(game).toStringAsFixed(3)})',
    );
    stdout.writeln(
      '        haut-gauche (${quad.topLeft.x.round()}, ${quad.topLeft.y.round()})'
      '  bas-droite (${quad.bottomRight.x.round()}, ${quad.bottomRight.y.round()})',
    );
  }

  final base = quad == null ? cropToCardFrame(photo) : photo;
  final candidates = quad == null
      ? artHashCandidates(base, game: game)
      : artHashCandidatesInQuad(photo, quad, game: game);

  stdout.writeln('\nempreintes par hypothèse :');
  for (final entry in candidates.entries) {
    // Le quart de tour fait partie de l'hypothèse : une carte couchée dans une
    // pochette droite ne se lit qu'ainsi, et c'est le seul endroit où on peut
    // voir laquelle des orientations a été essayée.
    final turns = entry.key.quarterTurns;
    final label = turns == 0
        ? entry.key.frame.name
        : '${entry.key.frame.name}+$turns';
    stdout.writeln('  ${label.padRight(18)} ${entry.value.toHex()}');

    // La zone réellement hachée, écrite pour être regardée. C'est le seul
    // moyen de voir un décalage de gabarit ; aucun chiffre ne le révèle.
    final crop = quad == null
        ? cropArt(base, entry.key.frame)
        : sampleArt(photo, quad.quarterTurned(turns), entry.key.frame.box);
    final file = File('$out/decoupe_$label.png')
      ..writeAsBytesSync(img.encodePng(crop));
    stdout.writeln('  ${' '.padRight(18)} ${file.path}');
  }
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
