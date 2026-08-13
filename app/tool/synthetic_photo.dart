/// Photo synthétique : une carte posée sur une table, vue de travers.
///
/// **Extrait de `framing_bench.dart`, et partagé à dessein.** Deux bancs qui
/// composeraient leurs images différemment ne seraient pas comparables, et
/// l'écart entre eux se confondrait avec l'écart entre ce qu'ils mesurent —
/// exactement la raison pour laquelle les deux bancs de cadrage partagent déjà
/// leur tirage. La composition est donc une seule définition, ici.
///
/// **Les photos sont synthétiques, et c'est un choix.** Une photo réelle porte
/// sa vérité terrain dans la tête de celui qui l'a prise ; une photo composée la
/// porte dans ses paramètres. On sait exactement de combien la carte a été
/// décalée, tournée, agrandie — donc à quel écart correspond quel échec.
///
/// **Ce qu'une photo composée ne prouve pas** : elle n'a ni flou de bougé, ni
/// mise au point ratée, ni reflet sur un protège-carte ; sa table est un grain
/// synthétique traversé d'un dégradé, pas un plateau à lames de bois. Un gain
/// mesuré ici est une condition nécessaire, jamais suffisante.
library;

import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:image/image.dart' as img;

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

  /// Le même régime, déplacé. Sert aux séquences, où la carte bouge d'une image
  /// à l'autre sans que le reste du cadrage change.
  Shot moved({double? offset, double? rotation}) => Shot(
    name,
    margin,
    offset ?? this.offset,
    rotation ?? this.rotation,
    lighting: lighting,
  );
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

/// La table : un grain aléatoire traversé d'un dégradé d'éclairage.
img.Image tableBackground(
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
///
/// [source] est la carte entière. [couchee] la pose en travers, [aspect] est le
/// format du carton du jeu — composer une carte au mauvais format mesurerait la
/// détection sur un objet qui n'existe pas.
///
/// **La taille de la photo ne dépend que du régime**, jamais du décalage : une
/// séquence où la carte bouge doit garder un cadre fixe, sinon c'est la caméra
/// qui bouge et non la carte, et les deux ne se mesurent pas pareil.
img.Image compose(
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
  final photo = tableBackground(photoWidth, photoHeight, rng, shot.lighting);

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

/// La table seule, sans carte : ce que voit l'objectif entre deux cartes.
///
/// Les dimensions sont celles qu'aurait la photo du même régime avec une carte,
/// sans quoi une séquence changerait de cadre en cours de route.
img.Image emptyTable(
  Shot shot,
  math.Random rng, {
  bool couchee = false,
  double aspect = defaultCardAspect,
}) {
  const long = 900;
  final court = (long * aspect).round();
  final margin = (long * shot.margin).round();
  final photo = tableBackground(
    (couchee ? long : court) + 2 * margin,
    (couchee ? court : long) + 2 * margin,
    rng,
    shot.lighting,
  );
  return img.decodeJpg(img.encodeJpg(photo, quality: 78))!;
}
