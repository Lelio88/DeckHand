/// Cadrage d'une photo sur la carte qu'elle contient.
///
/// Une photo n'a jamais les proportions d'une carte : l'appareil impose les
/// siennes, et il reste du décor autour. On retient donc le plus grand rectangle
/// **aux proportions d'une carte du jeu saisi**, centré dans l'image.
///
/// C'est ce que l'utilisateur voit dans le guide affiché à l'écran : le cadre
/// définit ce qui sera analysé, il lui suffit d'y placer sa carte.
///
/// **C'est le repli de la détection de bords, et c'est ce qui le rend
/// sensible.** Quand `findCard` renonce, tout le scan repose sur ce découpage :
/// le gabarit d'illustration du jeu s'applique ensuite à ce qu'il a rendu. Un
/// rapport faux ici ne se voit pas — il produit une empreinte plausible, donc
/// une mauvaise carte ou aucune. Le jeu doit donc y arriver aussi sûrement qu'il
/// arrive à `findCard` et à `artHashCandidates`.
library;

import 'package:image/image.dart' as img;

import 'card_geometry.dart';

/// Découpe le plus grand rectangle aux proportions d'une carte de [game],
/// centré.
img.Image cropToCardFrame(img.Image photo, {String game = 'magic'}) =>
    cropToAspect(photo, cardAspectFor(game));

/// Découpe le plus grand rectangle de rapport [aspect], centré.
///
/// **Séparé de [cropToCardFrame] pour être vraiment testable.** Les deux jeux
/// couverts impriment sur le même carton : un test qui les comparerait ne
/// prouverait rien du paramétrage. En exposant le découpage à un rapport
/// quelconque, on vérifie la mécanique elle-même, et [cropToCardFrame] n'a plus
/// qu'à choisir la bonne valeur.
///
/// L'image est retournée telle quelle si elle a déjà ces proportions, à un
/// arrondi près.
img.Image cropToAspect(img.Image photo, double aspect) {
  final width = photo.width;
  final height = photo.height;
  if (width < 2 || height < 2) return photo;

  var cropWidth = width;
  var cropHeight = (width / aspect).round();

  if (cropHeight > height) {
    cropHeight = height;
    cropWidth = (height * aspect).round();
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
