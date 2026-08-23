/// Trouver une carte par ses **quatre droites** (#8).
///
/// **Ce que les deux approches précédentes ont raté.** Le masque de production
/// retient ce qui est plus sombre que son voisinage : il suppose une carte
/// foncée sur une table claire, et sur seize photos réelles il n'a rien trouvé
/// de crédible. Un masque bâti sur le gradient a fait pire — 0/16 — parce que
/// dilater des bords puis remplir soude la carte au décor : la forme retenue
/// devient l'image entière.
///
/// **Et l'image entière passait les contrôles.** Une photo de téléphone est en
/// 3:4, soit un rapport de 0,753, quand une carte vaut 0,716 : l'écart est de
/// 0,037 pour une tolérance de 0,30. Autrement dit, **toute détection qui
/// échoue et retient tout le cadre était annoncée comme une carte** — mesuré
/// sur des coins d'image sans aucune carte : quinze faux sur seize. C'est
/// l'explication des cartes inventées observées sur l'appareil.
///
/// **Ce que ce module exploite à la place.** Une carte n'est pas une tache,
/// c'est un quadrilatère : quatre segments longs et rectilignes, deux à deux
/// presque parallèles. Cette propriété ne dépend ni du sens du contraste ni de
/// la couleur du fond — elle tient sur un parquet brun comme sur un drap blanc.
/// C'est ce que fait tout scanner de documents.
///
/// **Hough orienté, et non Hough classique.** En chaque pixel, le gradient
/// donne non seulement une force mais une **direction** : la normale au bord
/// qui passe là. On ne vote donc que pour l'angle mesuré (à quelques degrés
/// près) au lieu des cent quatre-vingts angles possibles. Le calcul y gagne
/// deux ordres de grandeur, et l'accumulateur y gagne surtout en netteté : une
/// texture de parquet vote dans toutes les directions et s'étale, un bord franc
/// vote toujours au même endroit et culmine.
///
/// **Invariant à préserver** : ce module ne doit jamais rendre un quadrilatère
/// qui touche les quatre bords de l'image. Une carte photographiée laisse voir
/// ses bords, faute de quoi il n'y a rien à détourer — et c'est précisément par
/// là que les faux positifs sont entrés.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:image/image.dart' as img;

/// Part des pixels retenus comme bords.
///
/// Un seuil **relatif** : le gradient d'une photo sombre est plus faible que
/// celui d'une photo éclairée, et un seuil absolu trierait les photos au lieu
/// des bords.
const double edgeQuantile = 0.90;

/// Nombre de droites candidates retenues.
///
/// Réparties par famille d'angle : sans plafond par tranche, les lignes d'un
/// bloc de texte — toutes horizontales et toutes franches — occupaient dix-huit
/// places sur vingt, et le bord droit de la carte n'était jamais candidat.
const int defaultMaxLines = 32;

/// Largeur d'analyse du flux caméra.
///
/// **Plus basse que celle de la photo, et sans perte mesurée.** Sur le banc de
/// photos réelles, en luminance : 38 cartes trouvées sur 39 à 240 px contre 37
/// à 400, pour une aire médiane meilleure (54 % contre 48 %). La détection par
/// droites cherche des bords longs, que réduire n'efface pas — au contraire, la
/// réduction lisse les textures fines qui fabriquent de fausses droites.
const int liveAnalysisWidth = 240;

/// Part minimale de chaque côté qui doit être réellement bordée.
///
/// **Le critère qui sépare une carte d'un hasard**, et le seul réglage dont le
/// balayage montre un point d'équilibre net : à 0,74 des cartes s'inventent sur
/// du fond, à 0,86 la détection retombe sur les cadres intérieurs de la carte.
const double defaultMinSupport = 0.78;

/// Pas angulaire de l'accumulateur, en degrés.
const int angleSteps = 180;

/// Étalement du vote, en pas d'angle de part et d'autre.
///
/// Un bord réel n'est pas parfaitement droit — perspective, compression,
/// arrondi des coins. Sans étalement, ses votes se dispersent sur trois
/// colonnes voisines et aucune ne culmine.
const int angleSpread = 2;

/// Une droite de l'image, en coordonnées polaires.
///
/// `rho = x·cos(theta) + y·sin(theta)`, `theta` dans [0, π).
class EdgeLine {
  const EdgeLine(this.theta, this.rho, this.votes);

  final double theta;
  final double rho;
  final int votes;

  /// Le point de cette droite le plus proche de l'origine, et sa direction.
  ({double x, double y}) get point =>
      (x: rho * math.cos(theta), y: rho * math.sin(theta));

  /// Intersection avec une autre droite, ou `null` si elles sont parallèles.
  ({double x, double y})? meet(EdgeLine other) {
    final c1 = math.cos(theta), s1 = math.sin(theta);
    final c2 = math.cos(other.theta), s2 = math.sin(other.theta);
    final det = c1 * s2 - s1 * c2;
    if (det.abs() < 1e-6) return null;
    return (
      x: (rho * s2 - other.rho * s1) / det,
      y: (other.rho * c1 - rho * c2) / det,
    );
  }
}

/// Le gradient de l'image réduite : force et direction en chaque pixel.
({Float32List magnitude, Float32List angle, int width, int height}) gradientOf(
  img.Image small, {
  bool monochrome = false,
}) {
  final w = small.width, h = small.height;

  // **Trois canaux, pas un gris.** Une carte à bordure noire posée sur un
  // parquet brun n'offre presque aucun contraste de luminance : le contour
  // disparaît du masque, et la détection retient alors le pavé de texte, dont
  // les bords sont francs — vérifié à l'œil sur deux photos. Les deux surfaces
  // diffèrent pourtant nettement en couleur. On garde donc, en chaque pixel, la
  // plus forte des trois réponses.
  // **Un seul canal quand il n'y en a qu'un.** Le flux caméra livre un plan de
  // luminance : y chercher trois gradients identiques coûterait trois fois le
  // prix pour le même résultat.
  final canaux = <Float32List>[
    Float32List(w * h),
    if (!monochrome) Float32List(w * h),
    if (!monochrome) Float32List(w * h),
  ];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      final i = y * w + x;
      canaux[0][i] = p.r.toDouble();
      if (!monochrome) {
        canaux[1][i] = p.g.toDouble();
        canaux[2][i] = p.b.toDouble();
      }
    }
  }

  final magnitude = Float32List(w * h);
  final angle = Float32List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      for (final c in canaux) {
        final gx =
            -c[i - w - 1] -
            2 * c[i - 1] -
            c[i + w - 1] +
            c[i - w + 1] +
            2 * c[i + 1] +
            c[i + w + 1];
        final gy =
            -c[i - w - 1] -
            2 * c[i - w] -
            c[i - w + 1] +
            c[i + w - 1] +
            2 * c[i + w] +
            c[i + w + 1];
        final m = math.sqrt(gx * gx + gy * gy);
        if (m > magnitude[i]) {
          magnitude[i] = m;
          angle[i] = math.atan2(gy, gx);
        }
      }
    }
  }
  return (magnitude: magnitude, angle: angle, width: w, height: h);
}

/// Les droites dominantes de l'image, les plus votées d'abord.
///
/// [maxLines] borne ce qui est rendu : au-delà d'une vingtaine, on ramasse le
/// décor sans jamais rien y gagner, et la combinatoire d'appariement enfle.
({List<EdgeLine> lines, Uint8List edges, int width, int height}) dominantLines(
  img.Image small, {
  int maxLines = 24,
  bool monochrome = false,
}) {
  final g = gradientOf(small, monochrome: monochrome);
  final w = g.width, h = g.height;

  // **Le quantile par histogramme, pas par tri.** Trier cent trente mille
  // flottants pour n'en lire qu'un coûtait plus cher que tout le reste de la
  // chaîne. Deux cent cinquante-six cases suffisent : on cherche un seuil, pas
  // un classement.
  var maxMag = 0.0;
  for (final m in g.magnitude) {
    if (m > maxMag) maxMag = m;
  }
  final hist = Int32List(256);
  final echelle = maxMag > 0 ? 255 / maxMag : 0.0;
  for (final m in g.magnitude) {
    hist[(m * echelle).floor().clamp(0, 255)]++;
  }
  final cible = (edgeQuantile * g.magnitude.length).round();
  var cumul = 0, casier = 0;
  for (var i = 0; i < 256; i++) {
    cumul += hist[i];
    if (cumul >= cible) {
      casier = i;
      break;
    }
  }
  // **Jamais zéro.** Sur une image majoritairement plate — un fond uni, une
  // photo floue —, neuf dixièmes des pixels ont un gradient nul et le quantile
  // tombe à zéro : tout devient un bord, le support vaut un partout, et
  // n'importe quel quadrilatère passe. Un pixel sans gradient n'est pas un bord.
  final seuil = echelle == 0
      ? double.infinity
      : math.max(casier / echelle, _gradientPlancher);

  final diag = math.sqrt(w * w + h * h).ceil();
  final rhoOffset = diag; // rho peut être négatif
  final rhoCount = 2 * diag + 1;
  final acc = Int32List(angleSteps * rhoCount);
  final edges = Uint8List(w * h);

  final pas = math.pi / angleSteps;
  for (var i = 0; i < g.magnitude.length; i++) {
    if (g.magnitude[i] < seuil) continue;
    edges[i] = 1;
    final x = i % w, y = i ~/ w;

    // La direction du gradient est la normale au bord : c'est exactement le
    // theta de la droite recherchée, à π près.
    var theta = g.angle[i];
    if (theta < 0) theta += math.pi;
    if (theta >= math.pi) theta -= math.pi;
    final centre = (theta / pas).round();

    for (var d = -angleSpread; d <= angleSpread; d++) {
      final t = (centre + d) % angleSteps;
      final tt = t < 0 ? t + angleSteps : t;
      final a = tt * pas;
      final rho = x * math.cos(a) + y * math.sin(a);
      final r = rho.round() + rhoOffset;
      if (r < 0 || r >= rhoCount) continue;
      acc[tt * rhoCount + r]++;
    }
  }

  // **Suppression non-maximale.** Un bord franc allume une dizaine de cases
  // voisines ; sans cela, les vingt « meilleures » droites seraient vingt
  // variantes du même bord et il n'en resterait aucune pour les trois autres.
  //
  // **Et une répartition par famille d'angle.** Les lignes d'un bloc de texte
  // sont toutes horizontales et toutes franches : prises en bloc, les vingt
  // meilleures droites d'une carte Magic sont dix-huit lignes de texte et deux
  // verticales, si bien que le bord droit de la carte n'entre jamais dans les
  // candidats — vérifié à l'œil, le contour est parfaitement détecté mais
  // jamais retenu. On plafonne donc chaque tranche d'angle.
  const rayonRho = 8;
  const rayonTheta = 3;
  const largeurTranche = 20; // pas d'angle
  final parTranche = <int, int>{};
  final maxParTranche = math.max(4, maxLines ~/ 4);
  final pics = <EdgeLine>[];

  // **On ne trie que ce qui peut gagner.** L'accumulateur compte cent quatre-
  // vingt mille cases pour trente-deux droites retenues : le trier en entier
  // était, à lui seul, la moitié du temps de calcul. Une droite qui rassemble
  // moins d'un cinquième des votes du meilleur pic ne borde rien.
  var meilleur = 0;
  for (final v in acc) {
    if (v > meilleur) meilleur = v;
  }
  final plancher = math.max(8, (meilleur * 0.20).round());
  final indices = <int>[];
  for (var i = 0; i < acc.length; i++) {
    if (acc[i] >= plancher) indices.add(i);
  }
  indices.sort((a, b) => acc[b] - acc[a]);
  final pris = <int>[];
  for (final idx in indices) {
    if (acc[idx] == 0) break;
    if (pics.length >= maxLines) break;
    final tranche = (idx ~/ rhoCount) ~/ largeurTranche;
    if ((parTranche[tranche] ?? 0) >= maxParTranche) continue;
    final t = idx ~/ rhoCount, r = idx % rhoCount;
    var trop = false;
    for (final p in pris) {
      final pt = p ~/ rhoCount, pr = p % rhoCount;
      var dt = (pt - t).abs();
      if (dt > angleSteps / 2) dt = angleSteps - dt;
      if (dt <= rayonTheta && (pr - r).abs() <= rayonRho) {
        trop = true;
        break;
      }
    }
    if (trop) continue;
    pris.add(idx);
    parTranche[tranche] = (parTranche[tranche] ?? 0) + 1;
    pics.add(EdgeLine(t * pas, (r - rhoOffset).toDouble(), acc[idx]));
  }
  // **Les quatre bords du cadre sont des droites, eux aussi.** Une carte cadrée
  // dans le guide de visée déborde de l'image : ses bords haut et bas ne sont
  // nulle part, et aucun gradient ne peut les faire naître. Sans ces droites-là,
  // la détection prenait deux lignes intérieures et rognait la carte de onze
  // pour cent en hauteur — un découpage d'apparence parfaite, au rapport exact
  // d'une carte, mais décalé, donc une empreinte fausse.
  //
  // On ne leur demande évidemment pas de support : on ne voit pas un bord qui
  // est hors champ. C'est l'interdiction du plein cadre qui reste le garde-fou —
  // les quatre à la fois désignent l'image, pas une carte.
  // **Impasse mesurée : ne pas recaler les droites sur leurs pixels.** Le vote
  // étale chaque contribution sur deux pas d'angle, et deux degrés déplacent
  // l'extrémité d'un côté de 240 pixels de huit pixels — 3 %, soit le point où
  // l'empreinte décroche. Ajuster ensuite chaque droite au sens des moindres
  // carrés sur les pixels de bord qu'elle longe **améliore bien le rapport**
  // (0,734 → 0,720 sur une photo réelle, l'attendu étant 0,716) et **dégrade la
  // reconnaissance** : la distance à la bonne carte passe de 14 à 23 bits.
  //
  // La raison tient au voisinage : les pixels retenus ne sont pas seulement
  // ceux du bord de la carte, mais aussi ceux des cadres qui le longent — le
  // liseré, le cadre de l'illustration —, et ils tirent la droite ailleurs. Un
  // rapport plus juste sur un cadre déplacé ne vaut rien.
  pics
    ..add(EdgeLine(0, 0, 0))
    ..add(EdgeLine(0, (w - 1).toDouble(), 0))
    ..add(EdgeLine(math.pi / 2, 0, 0))
    ..add(EdgeLine(math.pi / 2, (h - 1).toDouble(), 0));

  return (lines: pics, edges: edges, width: w, height: h);
}

/// Gradient en deçà duquel un pixel n'est jamais un bord.
///
/// Exprimé sur l'échelle 0-255 des canaux : quelques niveaux d'écart entre deux
/// voisins, soit moins que le bruit d'un capteur.
const double _gradientPlancher = 12.0;

/// Règle la force de la continuité, pour les bancs. Ne pas toucher ailleurs.
set continuityBonus(double v) => _bonusContinuite = v;

/// Ce que vaut, dans le choix, un cadre compatible avec le précédent.
///
/// **Assez pour départager deux formes plausibles, pas pour en imposer une
/// mauvaise.** Un quadrilatère franchement meilleur l'emporte toujours ; c'est
/// seulement quand deux candidats se valent que la continuité tranche.
double _bonusContinuite = 1.35;

/// Part minimale de chaque bord où la matière doit changer.
///
/// **Volontairement bas.** Il ne s'agit pas d'exiger un contraste franc — une
/// carte photographiée dans l'ombre en manque —, mais d'écarter le cas où il
/// n'y en a **aucun** : le même parquet des deux côtés du prétendu bord.
///
/// Mesuré sur douze photos de décor sans carte et trente-neuf cartes seules :
/// à 0,30 les quadrilatères inventés sur du sol ou un plan de travail
/// disparaissent **sans coûter une seule carte** ; au-delà de 0,45 les cartes
/// commencent à tomber sans qu'un faux de plus ne s'en aille.
///
/// Ces deux-là sont une boîte de boosters et une serviette imprimée : de vrais
/// objets rectangulaires posés, que ce critère valide à juste titre. Les écarter
/// demanderait de regarder ce qu'il y a *dedans* — c'est le travail de
/// l'empreinte, en aval, qui ne leur trouvera aucune correspondance.
const double _ruptureMinimale = 0.30;

/// Part minimale de l'image exigée d'un quadrilatère au quatrième côté déduit.
const double _aireMinDeduite = 0.30;

/// Règle le plafond de couverture, pour les bancs. Ne pas toucher ailleurs.
set cardCoverageCeiling(double v) => maxCardCoverage = v;

/// Part de l'image au-delà de laquelle un quadrilatère n'est plus une carte.
///
/// **Le garde-fou que « le plus grand gagne » rendait indispensable.** Deux
/// chaînes proposent un cadre et l'on retient le plus vaste, parce qu'un cadre
/// intérieur est contenu dans ce qu'il borde. Mais une détection qui **échoue**
/// retient tout le cadre, et se trouve alors être la plus vaste de toutes :
/// mesuré sur une photo réelle, le quadrilatère retenu couvrait **94 %** de
/// l'image, l'empreinte était prélevée sur la photo entière, et la carte
/// annoncée n'avait aucun rapport avec celle qu'on tenait.
///
/// Une carte photographiée de près peut remplir 80 % du cadre ; au-delà, elle
/// n'y montre plus ses bords et il n'y a rien à détourer.
///
/// **0,84 plutôt que 0,88, et le banc le dit** : à 0,88 un parquet couvrant
/// 92 % de l'image passait encore pour une carte ; à 0,84 il tombe, sans qu'une
/// seule carte réelle soit perdue au passage.
double maxCardCoverage = 0.84;

/// Marque une droite déduite plutôt que vue.
///
/// Négatif pour ne jamais être confondu avec un vrai décompte de votes, ni avec
/// les zéro d'une droite de cadre.
const int _voteDeduit = -1;

/// Support exigé des côtés vus quand un côté manque à l'appel.
///
/// Vaut dans deux régimes : un couple sorti du cadre (guide de visée) ou un
/// quatrième côté déduit (doigt sur un bord). Dans les deux cas il reste moins
/// de bords pour affirmer qu'il y a une carte, d'où une exigence plus haute que
/// le régime ordinaire.
///
/// **Le balayage montre un point d'équilibre étroit** : à 0,86 quatre fonds sur
/// seize s'inventent une carte, à 0,92 une carte réellement tenue à la main se
/// voit détourer par la moitié. 0,90 tient les deux.
const double _supportSansCouple = 0.90;

/// De part et d'autre de ce segment, est-ce la même matière ?
///
/// **Le critère qui distingue une carte d'une lame de parquet.** Le support dit
/// qu'un bord passe là ; il ne dit pas que ce bord sépare deux choses. Or une
/// veine de bois, une rainure de plan de travail, une jointure de lame sont des
/// droites franches et parallèles — mesuré sur douze photos de décor sans
/// aucune carte, cinq s'en fabriquaient une, dont trois sur du sol.
///
/// Une carte, elle, est un **objet posé** : sur toute la longueur de son bord,
/// ce qu'il y a dedans diffère de ce qu'il y a dehors, et **toujours dans le
/// même sens** — une bordure sombre reste plus sombre que la table sur les
/// quatre côtés. Une veine de bois change de sens d'un bout à l'autre.
///
/// Rend la part des échantillons dont l'écart va dans le sens majoritaire et
/// dépasse le bruit.
double _rupture(
  ({double x, double y}) a,
  ({double x, double y}) b,
  ({double x, double y}) centre,
  img.Image im,
) {
  final longueur = math.sqrt(
    (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y),
  );
  if (longueur < 8) return 0;

  // La normale, orientée vers l'intérieur du quadrilatère.
  var nx = -(b.y - a.y) / longueur, ny = (b.x - a.x) / longueur;
  final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
  if ((centre.x - mx) * nx + (centre.y - my) * ny < 0) {
    nx = -nx;
    ny = -ny;
  }

  double? lire(double x, double y) {
    // Hors du cadre, on ne sait pas : ramener le pixel du bord donnerait un
    // écart nul, c'est-à-dire un verdict « même matière » tiré de rien.
    final xi = x.round(), yi = y.round();
    if (xi < 0 || yi < 0 || xi >= im.width || yi >= im.height) return null;
    final p = im.getPixel(xi, yi);
    return (p.r.toDouble() + p.g.toDouble() + p.b.toDouble()) / 3;
  }

  const recul = 5.0;
  final pas = math.max(12, (longueur / 3).round());
  final ecarts = <double>[];
  for (var i = 0; i <= pas; i++) {
    final t = _marge + (i / pas) * (1 - 2 * _marge);
    final x = a.x + (b.x - a.x) * t;
    final y = a.y + (b.y - a.y) * t;
    final dedans = lire(x + nx * recul, y + ny * recul);
    final dehors = lire(x - nx * recul, y - ny * recul);
    if (dedans == null || dehors == null) continue;
    ecarts.add(dedans - dehors);
  }

  // **Ne pas pouvoir juger n'est pas juger contre.** Un côté porté par le bord
  // de l'image — carte cadrée dans le guide de visée — n'a pas de dehors à
  // regarder. Trois tests l'ont montré avant l'appareil.
  if (ecarts.isEmpty) return 1;

  var positifs = 0;
  for (final e in ecarts) {
    if (e > 0) positifs++;
  }
  final sens = positifs * 2 >= ecarts.length ? 1 : -1;
  var daccord = 0;
  for (final e in ecarts) {
    if (e * sens > _ecartMinimal) daccord++;
  }
  return daccord / ecarts.length;
}

/// Écart de luminance en deçà duquel deux voisins sont la même matière.
///
/// Sur l'échelle 0-255 : le bruit d'un capteur et les nuances d'une même lame de
/// parquet restent en dessous.
const double _ecartMinimal = 10.0;

/// Range quatre coins dans l'ordre où l'on lit une carte.
///
/// **Sans quoi l'illustration serait lue à l'envers.** L'assemblage rend les
/// intersections dans l'ordre où les droites ont été essayées, qui n'a aucune
/// raison de suivre le tour de la carte : mesuré, un quadrilatère parfaitement
/// juste sortait avec son coin haut-gauche à droite, ce qui découpe en miroir
/// une fenêtre d'apparence irréprochable.
///
/// On trie par angle autour du centre — ce qui donne le tour — puis on part du
/// coin le plus proche de l'origine.
List<({double x, double y})> _ordonner(List<({double x, double y})> coins) {
  final cx = coins.map((p) => p.x).reduce((a, b) => a + b) / 4;
  final cy = coins.map((p) => p.y).reduce((a, b) => a + b) / 4;
  final tour = [...coins]
    ..sort(
      (p, q) => math
          .atan2(p.y - cy, p.x - cx)
          .compareTo(math.atan2(q.y - cy, q.x - cx)),
    );
  var depart = 0;
  var meilleur = double.infinity;
  for (var i = 0; i < 4; i++) {
    final d = tour[i].x + tour[i].y;
    if (d < meilleur) {
      meilleur = d;
      depart = i;
    }
  }
  return [for (var i = 0; i < 4; i++) tour[(depart + i) % 4]];
}

/// Cette droite est-elle un bord du cadre plutôt qu'un bord vu ?
bool _estBordDuCadre(EdgeLine l, int w, int h) =>
    l.votes == 0 &&
    (l.rho.abs() < 1 || (l.rho - (w - 1)).abs() < 1 || (l.rho - (h - 1)).abs() < 1);

/// Quelle part d'un segment est réellement bordée de pixels de bord.
///
/// **Le critère qui sépare une carte d'un hasard.** Un pic de Hough dit qu'une
/// droite existe quelque part, pas qu'elle longe le côté sur toute sa longueur :
/// quarante pixels alignés au fond d'une image suffisent à faire naître une
/// droite, et quatre de ces droites se croisent en un quadrilatère plausible.
/// Mesuré sur des coins d'image sans carte, huit sur seize passaient ainsi.
///
/// Le bord d'une carte, lui, est **continu**. On échantillonne donc le segment
/// et l'on regarde, en face de chaque point, s'il y a bien un pixel de bord à
/// un ou deux pixels près.
/// Part du segment ignorée à chaque extrémité, pour les coins arrondis.
const double _marge = 0.06;

({double net, double troue}) _support(
  ({double x, double y}) a,
  ({double x, double y}) b,
  Uint8List edges,
  int w,
  int h,
) {
  final longueur = math.sqrt(
    (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y),
  );
  final pas = math.max(16, longueur.round());
  var vus = 0, testes = 0, lacune = 0, pireLacune = 0;
  for (var i = 0; i <= pas; i++) {
    // **Sans les extrémités.** Une carte a les coins arrondis : le segment
    // droit y passe dans le vide sur quelques pixels, et un contour parfait
    // plafonnait ainsi vers 0,6 — au même niveau qu'un alignement fortuit du
    // décor, ce qui rendait le critère incapable de les séparer.
    final t = _marge + (i / pas) * (1 - 2 * _marge);
    final x = (a.x + (b.x - a.x) * t).round();
    final y = (a.y + (b.y - a.y) * t).round();
    if (x < 0 || y < 0 || x >= w || y >= h) continue;
    testes++;
    // **Une fenêtre large de trois pixels.** L'accumulateur quantifie rho au
    // pixel et étale le vote sur deux pas d'angle : la droite rendue longe le
    // bord sans se confondre avec lui, à deux ou trois pixels près sur une
    // photo de quatre cents de large.
    var trouve = false;
    for (var dy = -3; dy <= 3 && !trouve; dy++) {
      for (var dx = -3; dx <= 3; dx++) {
        final nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        if (edges[ny * w + nx] != 0) {
          trouve = true;
          break;
        }
      }
    }
    if (trouve) {
      vus++;
      lacune = 0;
    } else {
      lacune++;
      if (lacune > pireLacune) pireLacune = lacune;
    }
  }
  if (testes == 0) return (net: 0, troue: 0);

  // **Deux lectures du même côté.** `net` est la part réellement bordée ; `troue`
  // est ce qu'elle vaudrait si l'on comblait la plus longue interruption.
  //
  // C'est ce qui distingue un doigt d'un hasard : une main masque une portion
  // **contiguë** du bord — mesuré, un pouce couvre près d'un tiers du côté
  // gauche —, tandis qu'un alignement fortuit du décor est troué partout. Le
  // premier retrouve un support parfait dès qu'on lui pardonne une lacune, le
  // second reste bas.
  return (
    net: vus / testes,
    troue: math.min(1.0, (vus + pireLacune) / testes),
  );
}

/// Le plus grand des cadres proposés, à condition qu'il reste une carte.
///
/// **Deux chaînes valent mieux qu'une, mais pas à n'importe quel prix.** On
/// retient le plus vaste parce qu'un cadre intérieur — celui de l'illustration,
/// celui du bloc de texte — est contenu dans ce qu'il borde. Une détection qui
/// échoue retient pourtant tout le cadre de la photo, et gagnerait à ce jeu :
/// mesuré, un quadrilatère couvrant 94 % de l'image l'emportait, et l'empreinte
/// se prélevait sur la photo entière.
CardQuad? largestPlausible(
  Iterable<CardQuad?> candidates, {
  required int width,
  required int height,
}) {
  final aire = width * height;
  final retenus = candidates
      .whereType<CardQuad>()
      .where((q) => q.area / aire <= maxCardCoverage)
      .toList();
  if (retenus.isEmpty) return null;
  return retenus.reduce((a, b) => a.area >= b.area ? a : b);
}

/// Les coins de la carte, cherchés par ses quatre droites.
///
/// Rend `null` plutôt qu'un quadrilatère douteux — l'appelant retombe alors sur
/// la chaîne par clarté, puis sur le cadrage centré.
///
/// **Mesuré sur seize photos réelles** (fonds, lumières et appareils variés) :
/// quinze cartes trouvées contre quatre pour la chaîne par clarté, et surtout
/// **zéro carte inventée** sur des fonds sans carte, contre deux. Coût : 65 ms
/// par photo sur poste fixe, contre 12 ms — sans importance pour une photo,
/// rédhibitoire pour le flux caméra, qui garde donc l'autre chemin.
CardQuad? findCardByEdges(
  img.Image photo, {
  String game = 'magic',
  double ruptureMin = _ruptureMinimale,
  int width = analysisWidth,
  CardQuad? anchor,
}) {
  if (photo.width < 32 || photo.height < 32) return null;

  final scale = photo.width > width ? photo.width / width : 1.0;
  final small = scale > 1
      ? boxReduce(
          photo,
          width,
          (photo.height / scale).round().clamp(1, photo.height),
        )
      : photo;

  final champ = dominantLines(small, maxLines: defaultMaxLines);
  final quad = bestQuad(
    champ.lines,
    champ.edges,
    champ.width,
    champ.height,
    game,
    image: small,
    minSupport: defaultMinSupport,
    ruptureMin: ruptureMin,
    anchor: anchor?.scaled(1 / scale),
  );
  return quad?.scaled(scale);
}

/// Les coins de la carte, cherchés dans le **plan de luminance** d'une image de
/// caméra.
///
/// **Ce que cela évite.** [findCardByEdges] réclame un `img.Image` ; une image de
/// caméra n'en est pas un, et la construire coûte 10,4 ms sur l'appareil —
/// mesuré — avant même que la détection commence, pour un plan qui porte déjà le
/// seul canal utile.
///
/// **Ce que l'on perd sans la couleur.** Le gradient sur trois canaux est ce qui
/// permet de voir une bordure noire sur un parquet brun. Mesuré sur le banc de
/// photos réelles : 37 cartes trouvées sur 39 au lieu de 38, à aire médiane
/// égale. Le contrôle de matière, lui, garde tout son sens — il compare des
/// luminances, pas des couleurs.
CardQuad? findCardByEdgesInLuma(
  Uint8List luma, {
  required int width,
  required int height,
  required int rowStride,
  int pixelStride = 1,
  String game = 'magic',
  int analysisWidth = liveAnalysisWidth,
  bool upright = true,
  CardQuad? anchor,
}) {
  if (width < 32 || height < 32) return null;

  final scale = width > analysisWidth ? width / analysisWidth : 1.0;
  final target = scale > 1 ? analysisWidth : width;
  final targetHeight = scale > 1
      ? (height / scale).round().clamp(1, height)
      : height;
  final small = boxReduceLuma(
    luma,
    width: width,
    height: height,
    rowStride: rowStride,
    pixelStride: pixelStride,
    outWidth: target,
    outHeight: targetHeight,
  );

  final champ = dominantLines(
    small,
    maxLines: defaultMaxLines,
    monochrome: true,
  );
  final quad = bestQuad(
    champ.lines,
    champ.edges,
    champ.width,
    champ.height,
    game,
    image: small,
    minSupport: defaultMinSupport,
    upright: upright,
    anchor: anchor?.scaled(1 / scale),
  );
  return quad?.scaled(scale);
}

/// Le meilleur quadrilatère formé par quatre des droites données.
///
/// Cherche deux paires de droites presque parallèles, presque perpendiculaires
/// entre paires, dont les quatre intersections forment un rectangle au rapport
/// d'une carte. Rend `null` s'il n'existe pas de tel assemblage.
CardQuad? bestQuad(
  List<EdgeLine> lines,
  Uint8List edges,
  int width,
  int height,
  String game, {
  img.Image? image,
  double aspectTol = 0.12,
  double minArea = 0.12,
  double minSupport = 0.85,
  double ruptureMin = _ruptureMinimale,
  bool? upright,
  double supportPartiel = _supportSansCouple,
  CardQuad? anchor,
}) {
  if (lines.length < 4) return null;

  // **Une seule orientation quand elle est connue.** Accepter les deux double la
  // surface d'acceptation, et c'est par là qu'une carte s'est inventée sur un
  // parquet : les lames y ont le format d'une carte couchée. Le mode photo ne
  // sait pas comment le téléphone était tenu et doit donc accepter les deux ;
  // le flux, lui, connaît l'orientation de son capteur et n'a aucune raison de
  // l'oublier.
  //
  // Un jeu qui imprime réellement en travers — les Terrains Wankul, les champs
  // de bataille Riftbound — garde les deux quoi qu'il arrive : là, l'orientation
  // n'est pas une inconnue mais une propriété de la carte.
  final debout = cardAspectFor(game);
  final couche = 1 / debout;
  final jeuCouche = CardFrame.values.any((f) => f.game == game && f.landscape);
  final accepte = <double>[
    if (upright == null || upright) debout,
    if (upright == null || !upright || jeuCouche) couche,
    if (upright != null && upright && jeuCouche) couche,
  ];

  CardQuad? best;
  var bestScore = -1.0;

  double ecart(double a, double b) {
    var d = (a - b).abs();
    if (d > math.pi / 2) d = math.pi - d;
    return d;
  }

  for (var i = 0; i < lines.length; i++) {
    for (var j = i + 1; j < lines.length; j++) {
      // Paire 1 : presque parallèles, et pas confondues.
      if (ecart(lines[i].theta, lines[j].theta) > 0.20) continue;
      if ((lines[i].rho - lines[j].rho).abs() < 20) continue;

      for (var k = 0; k < lines.length; k++) {
        if (k == i || k == j) continue;

        // **Le quatrième côté peut se déduire des trois autres.** Une carte
        // tenue à la main a un doigt sur un bord : mesuré sur une photo réelle,
        // le bord haut disparaissait sous le pouce et la détection se rabattait
        // sur le pavé de texte, seul rectangle complet restant — d'où une
        // empreinte calculée sur « Éphémère ».
        //
        // Or le rapport d'une carte est connu. Deux côtés opposés vus donnent
        // une dimension ; le rapport donne l'autre ; le troisième côté dit d'où
        // partir. Le quatrième n'a plus qu'une place possible, de chaque côté.
        // On ne lui demande évidemment aucun support — il n'est pas visible —,
        // et c'est pourquoi les trois autres doivent être francs.
        final ecartement = (lines[i].rho - lines[j].rho).abs();
        final deduites = <EdgeLine>[
          for (final aspect in accepte)
            for (final signe in [1, -1])
              EdgeLine(
                lines[k].theta,
                lines[k].rho + signe * ecartement / aspect,
                _voteDeduit,
              ),
        ];

        final candidates = [...lines, ...deduites];
        for (var l = 0; l < candidates.length; l++) {
          final deduite = l >= lines.length;
          if (!deduite && (l <= k || l == i || l == j)) continue;
          if (ecart(lines[k].theta, candidates[l].theta) > 0.20) continue;
          if ((lines[k].rho - candidates[l].rho).abs() < 20) continue;

          // Les deux paires doivent être presque perpendiculaires.
          final entre = ecart(lines[i].theta, lines[k].theta);
          if ((entre - math.pi / 2).abs() > 0.25) continue;

          final a = lines[i].meet(lines[k]);
          final b = lines[j].meet(lines[k]);
          final c = lines[j].meet(candidates[l]);
          final d = lines[i].meet(candidates[l]);
          if (a == null || b == null || c == null || d == null) continue;

          final coins = [a, b, c, d];
          var dedans = true;
          for (final p in coins) {
            if (p.x < -width * 0.05 ||
                p.y < -height * 0.05 ||
                p.x > width * 1.05 ||
                p.y > height * 1.05) {
              dedans = false;
              break;
            }
          }
          if (!dedans) continue;

          final ordonnes = _ordonner(coins);
          final quad = CardQuad(
            topLeft: ordonnes[0],
            topRight: ordonnes[1],
            bottomRight: ordonnes[2],
            bottomLeft: ordonnes[3],
          );

          double dist(({double x, double y}) p, ({double x, double y}) q) =>
              math.sqrt(
                (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y),
              );
          final cote1 = dist(a, b), cote2 = dist(b, c);
          if (cote1 < 12 || cote2 < 12) continue;

          final aire = cote1 * cote2;

          // **Une déduction ne s'accorde qu'à une grande carte.** Le quatrième
          // côté n'est pas vu : il reste trois bords pour affirmer qu'il y a une
          // carte là, et le contrôle de rapport ne filtre plus rien puisqu'on
          // bâtit le quadrilatère à la bonne proportion. Mesuré, les fonds qui
          // s'inventaient ainsi une carte tenaient dans 17 à 19 % de l'image,
          // quand une carte réellement tenue à la main en occupe 54 à 64 % — le
          // seuil est le milieu de ce fossé, pas un chiffre choisi.
          //
          // C'est cohérent avec l'usage : on déduit un bord parce qu'un doigt le
          // masque, donc parce que la carte est présentée de près.
          final part = aire / (width * height);
          if (part < (deduite ? _aireMinDeduite : minArea)) continue;

          // **Jamais le cadre entier, ni même deux bords opposés.** C'est par
          // là que les faux positifs sont entrés : une détection ratée retient
          // toute l'image, dont le rapport 3:4 ressemble à celui d'une carte.
          //
          // La règle vaut aussi quand un seul couple de côtés déborde : une
          // carte qui remplit la hauteur du cadre n'y montre ni son bord haut
          // ni son bord bas, et il n'y a alors rien à lire pour ce module — le
          // repli par clarté, lui, sait encore travailler. Deux tests le
          // vérifiaient déjà sans qu'on l'ait prévu : leurs photos de contrôle
          // sont cadrées ainsi, et la détection y répondait par un quadrilatère
          // couché formé de bords intérieurs.
          var minX = a.x, maxX = a.x, minY = a.y, maxY = a.y;
          for (final p in coins) {
            if (p.x < minX) minX = p.x;
            if (p.x > maxX) maxX = p.x;
            if (p.y < minY) minY = p.y;
            if (p.y > maxY) maxY = p.y;
          }
          // **Presque tout le cadre n'est pas une carte non plus.** Un parquet
          // photographié de près rendait un quadrilatère couvrant 92 % de
          // l'image : appuyé sur les bords du cadre, il échappe au contrôle de
          // matière, qui n'a pas de dehors à regarder. Une carte occupant
          // plus de 88 % du cadre n'y montre de toute façon plus ses bords.
          if (aire / (width * height) > maxCardCoverage) continue;
          if (maxX - minX >= width - 2 && maxY - minY >= height - 2) continue;

          // **Les quatre côtés doivent être réellement bordés.** C'est ici
          // que tombent les assemblages fortuits du décor : ils se croisent au
          // bon rapport mais ne longent rien.
          // Un côté porté par le cadre est exempté : il n'y a rien à y voir.
          // Les quatre à la fois désignent l'image et non une carte — c'est
          // l'interdiction du plein cadre, plus bas, qui les écarte.
          final bordI = _estBordDuCadre(lines[i], width, height);
          final bordJ = _estBordDuCadre(lines[j], width, height);
          final bordK = _estBordDuCadre(lines[k], width, height);
          final bordL = _estBordDuCadre(candidates[l], width, height);

          // Un côté déduit ne se cumule pas avec un côté hors cadre : il ne
          // resterait que deux bords réellement vus pour affirmer qu'il y a une
          // carte, ce qui est le régime où les fonds se mettent à en produire.
          if (deduite && (bordI || bordJ || bordK)) continue;

          // **Par paire opposée, ou pas du tout.** Exempter n'importe quel côté
          // porté par le cadre laissait bâtir un quadrilatère sur deux bords
          // d'image et deux textures du décor : mesuré, treize fonds sans carte
          // sur seize devenaient des cartes. Le seul cas légitime est celui du
          // guide de visée — la carte déborde d'un côté *et* de son opposé —, et
          // il se reconnaît à cela : les deux droites manquantes sont
          // parallèles, les deux autres sont de vrais bords.
          final paireIJ = bordI && bordJ;
          final paireKL = bordK && bordL;
          final cadres = (bordI ? 1 : 0) + (bordJ ? 1 : 0) + (bordK ? 1 : 0) + (bordL ? 1 : 0);
          if (cadres > 0 && !(paireIJ ^ paireKL)) continue;
          if (cadres > 2) continue;

          final vus = <({double net, double troue})>[];
          void juger(
            bool exempt,
            ({double x, double y}) p,
            ({double x, double y}) q,
          ) {
            if (exempt) return;
            vus.add(_support(p, q, edges, width, height));
          }

          // Chaque côté est porté par deux droites ; il est vu dès que l'une
          // des deux est un vrai bord.
          juger(bordK, a, b);
          juger(bordJ, b, c);
          juger(bordL || deduite, c, d);
          juger(bordI, d, a);

          // Quand un couple manque, l'autre doit être franc : on n'a plus que
          // deux bords pour affirmer qu'il y a une carte là.
          // **Une main masque un bord, pas trois.** Quand le quatrième côté est
          // déduit, on pardonne son interruption à **un seul** des côtés vus —
          // celui que tient le doigt ; les autres doivent être francs.
          //
          // Sans cette restriction, la déduction faisait revenir quatre cartes
          // inventées sur seize fonds : un quadrilatère déduit passe le contrôle
          // de rapport **par construction**, puisqu'on le bâtit à la bonne
          // proportion, et le support restait alors le seul garde-fou.
          // **La matière doit changer aux quatre bords.** Sans ce contrôle,
          // cinq photos de décor sur douze s'inventaient une carte — trois sur
          // du parquet, dont les lames sont des droites parallèles franches.
          if (image != null) {
            final cx = coins.map((p) => p.x).reduce((x, y) => x + y) / 4;
            final cy = coins.map((p) => p.y).reduce((x, y) => x + y) / 4;
            final centre = (x: cx, y: cy);
            var pire = 1.0;
            for (var n = 0; n < 4; n++) {
              final r = _rupture(coins[n], coins[(n + 1) % 4], centre, image);
              if (r < pire) pire = r;
            }
            if (pire < ruptureMin) continue;
          }

          final seuil = cadres > 0 || deduite ? supportPartiel : minSupport;
          final nets = [for (final v in vus) v.net]..sort();
          var sup = nets.isEmpty ? 1.0 : nets.first;
          if (deduite && nets.length > 1) {
            final pardonne = vus.reduce((a, b) => a.net <= b.net ? a : b);
            sup = math.min(pardonne.troue, nets[1]);
          }
          if (sup < seuil) continue;

          // **L'orientation se lit sur le quadrilatère rangé, pas sur l'ordre
          // des droites.** `cote1 / cote2` désigne le rapport entre la première
          // paire essayée et la seconde : il vaut 0,716 ou 1,397 selon l'ordre
          // de la boucle, pour la même carte. Un contrôle d'orientation fondé
          // là-dessus acceptait donc les deux quoi qu'on lui demande — un test
          // l'a pris avant l'appareil. `CardQuad.aspect` mesure, lui, la largeur
          // sur la hauteur **dans l'image**.
          final oriente = quad.aspect;
          var proche = double.infinity;
          for (final a in accepte) {
            final e = (oriente - a).abs();
            if (e < proche) proche = e;
          }
          if (proche > aspectTol) continue;

          // **Le plus grand gagne.** Une carte contient ses propres cadres —
          // celui de l'illustration, celui du bloc de texte — et ceux-là ont
          // des bords plus francs que le contour de la carte sur une table
          // claire. Un score fondé sur la netteté détourait donc le pavé de
          // texte, au rapport d'une carte couchée : vérifié à l'œil sur la
          // photo, le rectangle rouge encadrait « Éphémère » et non la carte.
          // L'aire tranche sans ambiguïté, puisqu'un cadre intérieur est par
          // construction plus petit que ce qui le contient.
          var score = aire * sup * (1 - proche / aspectTol);

          // **À score comparable, on garde ce qu'on regardait déjà.** Mesuré sur
          // photos réelles bruitées : la plupart des images rendent un cadre
          // parfaitement stable (±0,2 %), mais certaines hésitent entre deux
          // formes distinctes — une largeur allant de 1807 à 3292 pixels sur la
          // même photo. Ce n'est pas du bruit, c'est un choix qui bascule ; et
          // comme l'empreinte décroche au-delà de 3 % d'écart de cadrage, une
          // seule bascule suffit à prélever l'illustration de travers et à
          // annoncer une carte que personne n'a montrée.
          //
          // Moyenner serait faux, précisément parce que ce sont des sauts : la
          // moyenne de deux formes distinctes n'est aucune des deux. On préfère
          // donc la continuité, sans la figer — l'ancre bonifie, elle n'impose
          // pas, et une carte qu'on retire du champ finit par perdre.
          if (anchor != null) {
            final ax = (anchor.topLeft.x + anchor.bottomRight.x) / 2;
            final ay = (anchor.topLeft.y + anchor.bottomRight.y) / 2;
            final cxq = coins.map((p) => p.x).reduce((x, y) => x + y) / 4;
            final cyq = coins.map((p) => p.y).reduce((x, y) => x + y) / 4;
            final ecartCentre = math.sqrt(
              (ax - cxq) * (ax - cxq) + (ay - cyq) * (ay - cyq),
            );
            final ecartAire = (aire - anchor.area).abs() / anchor.area;
            final diagonale = math.sqrt(
              width * width + height * height,
            );
            if (ecartCentre < diagonale * 0.08 && ecartAire < 0.20) {
              score *= _bonusContinuite;
            }
          }
          if (score > bestScore) {
            bestScore = score;
            best = quad;
          }
        }
      }
    }
  }
  return best;
}
