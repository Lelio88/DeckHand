/// Localisation de l'illustration sur une carte.
///
/// L'empreinte porte sur l'illustration seule ; il faut donc la découper dans la
/// photo de la carte entière. Sa position est **fixe en proportions**, ce qui
/// évite toute détection : cadrer la carte suffit.
///
/// Les gabarits sont **cloisonnés par jeu** : une carte Riftbound n'a rien à
/// voir avec un cadre Magic, et les essayer tous multiplierait le calcul autant
/// que le risque de correspondance fortuite.
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
import 'card_bounds.dart';

/// Zone d'illustration, en proportions de la carte.
typedef ArtBox = ({double left, double top, double right, double bottom});

/// Cadres de carte reconnus.
enum CardFrame {
  /// Cadre introduit en 2003, majoritaire aujourd'hui.
  modern((left: 0.080, top: 0.120, right: 0.920, bottom: 0.550), 'magic'),

  /// Cadre d'origine, antérieur à 2003. Ses marges latérales sont plus larges.
  /// Loin d'être anecdotique : le Pauper puise dans toute l'histoire du jeu.
  legacy((left: 0.114, top: 0.100, right: 0.890, bottom: 0.538), 'magic'),

  /// Riftbound, cartes verticales — l'immense majorité.
  ///
  /// **Mesuré par la luminosité de l'image moyenne**, deux méthodes fondées sur
  /// la variance ayant échoué avant : la première confondait l'illustration
  /// avec le cadre ouvragé, la seconde désignait le texte de règles, dont le
  /// contraste noir sur blanc écrase celui d'illustrations aux tons moyens. Sur
  /// l'image moyenne de seize cartes, les trois zones se séparent par leur
  /// clarté — cadre sombre, illustration en tons moyens, pavés de texte quasi
  /// blancs. Une mesure indépendante retombe sur les mêmes valeurs à 0,008
  /// près.
  ///
  /// La borne basse (0,517) exclut la ligne de type, relevée au pixel : elle
  /// forme une bande pleine largeur qui, sinon, gèlerait une ligne entière de
  /// la grille d'empreinte — un huitième de son information dépensé en
  /// constante.
  riftbound((
    left: 0.065,
    top: 0.047,
    right: 0.934,
    bottom: 0.517,
  ), 'riftbound'),

  /// Riftbound, cartes horizontales : les 71 champs de bataille.
  ///
  /// Leur nom est incrusté *dans* l'illustration et ne peut en être retiré ;
  /// il est donc haché avec elle, ce qui est sans conséquence puisqu'il est
  /// constant pour une carte donnée.
  riftboundWide((
    left: 0.041,
    top: 0.199,
    right: 0.962,
    bottom: 0.777,
  ), 'riftbound');

  const CardFrame(this.box, this.game);

  final ArtBox box;

  /// Jeu auquel ce cadre appartient.
  ///
  /// **Essayer les cadres d'un autre jeu coûte deux fois** : le calcul, et le
  /// risque. Une carte Magic découpée au gabarit Riftbound produit une empreinte
  /// qui n'a plus de sens mais peut rencontrer par hasard une entrée de l'index
  /// — or le pipeline est mesuré à zéro faux positif annoncé avec assurance, et
  /// c'est ce résultat qu'il faut protéger.
  final String game;
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

/// Empreintes candidates d'une carte photographiée, une par cadre du jeu.
///
/// On ne sait pas d'avance à quel cadre appartient la carte — c'est précisément
/// ce qu'on cherche à identifier. Les hypothèses du jeu courant sont donc toutes
/// calculées, et la recherche retiendra celle qui trouve la meilleure
/// correspondance.
///
/// [game] restreint les hypothèses : on sait toujours quel jeu on est en train
/// de saisir, et les cadres d'un autre jeu n'apporteraient que du bruit.
Map<CardFrame, ArtHash> artHashCandidates(
  img.Image card, {
  String game = 'magic',
}) => {
  for (final frame in CardFrame.values)
    if (frame.game == game) frame: computeArtHash(cropArt(card, frame)),
};

/// Empreintes lues dans le quadrilatère d'une carte détectée dans la photo.
///
/// Même chose que [artHashCandidates], mais sans supposer que la carte remplit
/// l'image : la zone est lue en interpolant les quatre coins. C'est ce qui rend
/// le scan indifférent au cadrage — mesuré, la reconnaissance passe de 0 à 37
/// sur 40 dès qu'une photo s'écarte de 8 % du cadre idéal.
Map<CardFrame, ArtHash> artHashCandidatesInQuad(
  img.Image photo,
  CardQuad quad, {
  String game = 'magic',
}) => {
  for (final frame in CardFrame.values)
    if (frame.game == game)
      frame: computeArtHash(sampleArt(photo, quad, frame.box)),
};
