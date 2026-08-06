/// Cadrage d'une photo sur la carte qu'elle contient.
///
/// Une photo n'a jamais les proportions d'une carte : l'appareil impose les
/// siennes, et il reste du décor autour. Faute de détection de contours — hors
/// sujet pour le jalon 2 — on retient le plus grand rectangle **aux proportions
/// d'une carte Magic**, centré dans l'image.
///
/// C'est ce que l'utilisateur voit dans le guide affiché à l'écran : le cadre
/// définit ce qui sera analysé, il lui suffit d'y placer sa carte.
library;

import 'package:image/image.dart' as img;

/// Proportions d'une carte Magic : 63 × 88 mm.
const double cardAspectRatio = 63 / 88;

/// Découpe le plus grand rectangle aux proportions d'une carte, centré.
///
/// L'image est retournée telle quelle si elle a déjà ces proportions, à un
/// arrondi près.
img.Image cropToCardFrame(img.Image photo) {
  final width = photo.width;
  final height = photo.height;
  if (width < 2 || height < 2) return photo;

  var cropWidth = width;
  var cropHeight = (width / cardAspectRatio).round();

  if (cropHeight > height) {
    cropHeight = height;
    cropWidth = (height * cardAspectRatio).round();
  }

  cropWidth = cropWidth.clamp(1, width);
  cropHeight = cropHeight.clamp(1, height);

  if (cropWidth == width && cropHeight == height) return photo;

  return img.copyCrop(
    photo,
    x: (width - cropWidth) ~/ 2,
    y: (height - cropHeight) ~/ 2,
    width: cropWidth,
    height: cropHeight,
  );
}
