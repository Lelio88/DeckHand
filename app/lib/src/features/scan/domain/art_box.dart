/// Localisation de l'illustration sur une carte Magic.
///
/// L'empreinte porte sur l'illustration seule ; il faut donc la découper dans la
/// photo de la carte entière. Sa position est **fixe en proportions**, ce qui
/// évite toute détection : cadrer la carte suffit.
///
/// **Deux gabarits, et c'est mesuré.** Magic a changé de cadre en 2003, et
/// l'illustration n'occupe pas la même zone avant et après. Les proportions
/// ci-dessous ont été obtenues en cherchant, dans le rendu complet de la carte,
/// la fenêtre qui reproduit l'illustration publiée par Scryfall — et non
/// estimées à la règle.
///
/// Sur 50 cartes tirées au hasard, le gabarit moderne seul situe correctement
/// l'illustration dans 42 cas ; essayer les deux et retenir la meilleure
/// correspondance en situe 47. Le coût est négligeable : deux empreintes à
/// calculer, deux recherches linéaires de quelques millisecondes.
///
/// **Limite connue** : les mises en page spéciales — `saga` (illustration
/// verticale), `transform`, cartes pleine page — échappent aux deux gabarits.
/// Elles relèveront de l'OCR du nom, prévu en appoint.
library;

import 'package:image/image.dart' as img;

import 'art_hash.dart';

/// Zone d'illustration, en proportions de la carte.
typedef ArtBox = ({double left, double top, double right, double bottom});

/// Cadres de carte reconnus.
enum CardFrame {
  /// Cadre introduit en 2003, majoritaire aujourd'hui.
  modern((left: 0.080, top: 0.120, right: 0.920, bottom: 0.550)),

  /// Cadre d'origine, antérieur à 2003. Ses marges latérales sont plus larges.
  /// Loin d'être anecdotique : le Pauper puise dans toute l'histoire du jeu.
  legacy((left: 0.114, top: 0.100, right: 0.890, bottom: 0.538));

  const CardFrame(this.box);

  final ArtBox box;
}

/// Découpe la zone d'illustration correspondant à [frame].
img.Image cropArt(img.Image card, CardFrame frame) {
  final box = frame.box;
  final x = (box.left * card.width).round();
  final y = (box.top * card.height).round();
  final width = ((box.right - box.left) * card.width).round();
  final height = ((box.bottom - box.top) * card.height).round();

  return img.copyCrop(
    card,
    x: x.clamp(0, card.width - 1),
    y: y.clamp(0, card.height - 1),
    width: width.clamp(1, card.width - x),
    height: height.clamp(1, card.height - y),
  );
}

/// Empreintes candidates d'une carte photographiée, une par cadre possible.
///
/// On ne sait pas d'avance à quel cadre appartient la carte — c'est précisément
/// ce qu'on cherche à identifier. Les deux hypothèses sont donc calculées, et la
/// recherche retiendra celle qui trouve la meilleure correspondance.
Map<CardFrame, ArtHash> artHashCandidates(img.Image card) => {
  for (final frame in CardFrame.values)
    frame: computeArtHash(cropArt(card, frame)),
};
