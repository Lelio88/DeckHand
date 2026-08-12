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

  /// Riftbound, cartes couchées : les 64 champs de bataille.
  ///
  /// Leur nom est incrusté *dans* l'illustration et ne peut en être retiré ;
  /// il est donc haché avec elle, ce qui est sans conséquence puisqu'il est
  /// constant pour une carte donnée.
  ///
  /// **La carte est posée en travers**, d'où [landscape] : mesuré sur le
  /// catalogue, une carte couchée fait 1039 × 744, soit un rapport de 1,397 —
  /// exactement l'inverse de 0,716. Ce n'est pas un autre format, c'est la
  /// même carte tournée d'un quart de tour.
  riftboundWide(
    (left: 0.041, top: 0.199, right: 0.962, bottom: 0.777),
    'riftbound',
    landscape: true,
  ),

  /// Yu-Gi-Oh, cadre ordinaire — 14 101 cartes sur 14 491.
  ///
  /// **Mesuré par recoupement, non par une heuristique.** La source publie la
  /// carte entière *et* son illustration détourée : la fenêtre se retrouve donc
  /// en cherchant, dans la première, la région qui reproduit la seconde. C'est
  /// la méthode des deux cadres Magic, et elle rend ici un résultat sans
  /// équivalent — sur 20 cartes tirées dans dix familles de cadre (effet, magie,
  /// piège, normale, XYZ, fusion, lien, synchro, rituel, jeton), **la même
  /// fenêtre à 0,001 près**, pour un écart résiduel de 1 niveau de gris sur 255.
  ///
  /// Riftbound avait demandé trois méthodes et deux échecs pour un seul
  /// gabarit ; ici la source répond elle-même à la question.
  yugioh((left: 0.1181, top: 0.1823, right: 0.8807, bottom: 0.7055), 'yugioh'),

  /// Yu-Gi-Oh, cartes Pendulum — 390 cartes, soit 2,7 %.
  ///
  /// Leur illustration déborde sous le cadre ordinaire pour laisser place aux
  /// deux échelles latérales : plus large (0,062 → 0,936 contre 0,118 → 0,881)
  /// et un peu moins haute. Mesurée sur 18 cartes des six sous-familles
  /// Pendulum, la fenêtre est stable à 0,001 près.
  ///
  /// **Le discriminant est un contrat, pas une devinette.** `frameType` porte
  /// « pendulum » pour ces cartes et pour elles seules — là où Pokémon n'offre
  /// que la rareté, dont le vocabulaire compte quarante valeurs qui ont changé
  /// plusieurs fois en vingt-sept ans (#28).
  ///
  /// **L'illustration détourée de la source ne sert pas ici** : pour une
  /// Pendulum, elle englobe le pavé de texte en plus de l'illustration. C'est
  /// ce qui a fait échouer la première mesure, et c'est pourquoi l'index
  /// découpe lui-même la carte entière plutôt que de faire confiance au
  /// recadrage publié.
  yugiohPendulum((
    left: 0.0615,
    top: 0.1789,
    right: 0.9360,
    bottom: 0.6238,
  ), 'yugioh');

  const CardFrame(this.box, this.game, {this.landscape = false});

  final ArtBox box;

  /// Vrai lorsque la carte se pose en travers.
  ///
  /// **C'est la détection qui en a besoin, pas le découpage.** Le gabarit,
  /// lui, s'exprime déjà en proportions de la carte telle qu'elle est posée.
  /// Mais `findCard` rejette tout quadrilatère dont le rapport s'écarte de
  /// celui d'une carte debout, et une carte couchée s'en écarte de 0,68 pour
  /// une tolérance de 0,30 : elle était donc introuvable, et ce cadre — mesuré,
  /// juste, documenté — n'a jamais pu servir.
  ///
  /// Cette propriété n'ouvre l'orientation couchée qu'aux jeux qui en ont une.
  /// L'élargir à tous reviendrait à accepter n'importe quel rectangle en Magic,
  /// où toutes les cartes sont debout — et le mode de défaillance connu est
  /// précisément là : un quadrilatère faux qui passe le contrôle d'aspect.
  final bool landscape;

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

/// Une manière de lire la carte : un cadre, et l'orientation sous laquelle on
/// le cherche.
///
/// **L'orientation est une hypothèse comme le cadre.** On ignore autant l'un que
/// l'autre au moment de photographier ; la recherche tranche en retenant celle
/// qui trouve la meilleure correspondance.
typedef ArtHypothesis = ({CardFrame frame, int quarterTurns});

/// Empreintes candidates d'une carte photographiée, une par cadre du jeu.
///
/// On ne sait pas d'avance à quel cadre appartient la carte — c'est précisément
/// ce qu'on cherche à identifier. Les hypothèses du jeu courant sont donc toutes
/// calculées, et la recherche retiendra celle qui trouve la meilleure
/// correspondance.
///
/// [game] restreint les hypothèses : on sait toujours quel jeu on est en train
/// de saisir, et les cadres d'un autre jeu n'apporteraient que du bruit.
///
/// **Aucune rotation ici**, contrairement à [artHashCandidatesInQuad] : ce
/// chemin est le repli, et il reçoit une image déjà découpée aux proportions
/// d'une carte debout. Tourner ce découpage ne montrerait pas la carte sous un
/// autre angle, seulement le même rectangle mal cadré.
Map<ArtHypothesis, ArtHash> artHashCandidates(
  img.Image card, {
  String game = 'magic',
}) => {
  for (final frame in CardFrame.values)
    if (frame.game == game)
      (frame: frame, quarterTurns: 0): computeArtHash(cropArt(card, frame)),
};

/// Empreintes lues dans le quadrilatère d'une carte détectée dans la photo.
///
/// Même chose que [artHashCandidates], mais sans supposer que la carte remplit
/// l'image : la zone est lue en interpolant les quatre coins. C'est ce qui rend
/// le scan indifférent au cadrage — mesuré, la reconnaissance passe de 0 à 37
/// sur 40 dès qu'une photo s'écarte de 8 % du cadre idéal.
///
/// **Un cadre couché cherché dans un quadrilatère droit est tourné, jamais lu
/// tel quel.** Une carte couchée glissée dans une pochette verticale se laisse
/// détecter comme une carte debout : ce sont les bords de la pochette que la
/// détection trouve, et son rapport est celui d'une carte. Le gabarit couché
/// s'appliquait alors à une zone parcourue de travers — mesuré sur du carton,
/// « Altar of Blood » ressortait au rang 590 sur 1 035, quand le quart de tour
/// la ramène **au rang 1, à 7 bits, avec une marge de 10**.
///
/// Les deux sens sont essayés parce qu'une empreinte ne survit pas au demi-tour :
/// la même carte lue dans le mauvais sens retombe au rang 185.
///
/// **La réciproque n'est pas faite, et c'est délibéré.** Un cadre droit cherché
/// dans un quadrilatère couché resterait lu tel quel : une carte debout ne se
/// présente pas couchée, et un quadrilatère couché autour d'une carte debout
/// signifie que la détection s'est trompée. Or chaque hypothèse est un tirage de
/// plus dans l'index, et un tirage sur du bruit a environ une chance sur cent de
/// passer les deux garde-fous (mesuré, `app.measure.art_collisions`). Essayé sur
/// une photo au masque faux, ce tirage-là annonçait « Mirror Image » à 12 bits
/// avec la marge requise — une carte inventée, sur le seul résultat que ce
/// pipeline protège. On n'échafaude pas d'hypothèse sur une détection fausse.
Map<ArtHypothesis, ArtHash> artHashCandidatesInQuad(
  img.Image photo,
  CardQuad quad, {
  String game = 'magic',
}) {
  final quadIsUpright = quad.aspect <= 1;
  final candidates = <ArtHypothesis, ArtHash>{};

  for (final frame in CardFrame.values) {
    if (frame.game != game) continue;
    final turns = frame.landscape && quadIsUpright ? const [1, 3] : const [0];
    for (final t in turns) {
      candidates[(frame: frame, quarterTurns: t)] = computeArtHash(
        sampleArt(photo, quad.quarterTurned(t), frame.box),
      );
    }
  }
  return candidates;
}
