/// Une planche contact des photos d'un dossier (#8).
///
/// **Pour regarder sans payer dix-sept fois.** Établir la vérité d'un banc
/// — combien de cartes porte chaque photo — demande de les voir. Les ouvrir une
/// par une coûte cher ; une mosaïque légendée les montre d'un coup.
library;

// ignore_for_file: avoid_print
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final dir = Directory(args.first);
  final sortie = args[1];
  final parPlanche = args.length > 2 ? int.parse(args[2]) : 6;
  final fichiers =
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jpg') || f.path.endsWith('.png')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  const cell = 460;
  const marge = 26;
  for (var p = 0; p * parPlanche < fichiers.length; p++) {
    final lot = fichiers.skip(p * parPlanche).take(parPlanche).toList();
    final cols = 2;
    final lignes = (lot.length / cols).ceil();
    final planche = img.Image(
      width: cols * cell,
      height: lignes * (cell + marge),
    );
    img.fill(planche, color: img.ColorRgb8(255, 255, 255));
    for (var i = 0; i < lot.length; i++) {
      final photo = img.decodeImage(lot[i].readAsBytesSync());
      if (photo == null) continue;
      final vignette = img.copyResize(
        photo,
        width: photo.width >= photo.height ? cell : null,
        height: photo.width >= photo.height ? null : cell,
      );
      final x = (i % cols) * cell;
      final y = (i ~/ cols) * (cell + marge) + marge;
      img.compositeImage(planche, vignette, dstX: x, dstY: y);
      img.drawString(
        planche,
        lot[i].uri.pathSegments.last.replaceAll('IMG_20260822_', '').replaceAll('.jpg', '').replaceAll('.png', ''),
        font: img.arial24,
        x: x + 4,
        y: y - marge + 2,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
    File('$sortie/planche-$p.png').writeAsBytesSync(img.encodePng(planche));
    print('planche-$p.png : ${lot.length} photos');
  }
}
