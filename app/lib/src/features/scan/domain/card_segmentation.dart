/// Délimite chaque carte d'une photo d'étalement.
///
/// **Quatre tentatives, et la première qui aboutit.** Chercher les arêtes trouve
/// le cadre interne de la carte ; la variance trouve le texte de règles ; la
/// luminosité du fond trouve le panneau de règles, blanc comme la table. Les
/// trois impasses sont consignées dans `docs/spread-detection.md`.
///
/// Ce qui débloque : traiter le panneau de règles pour ce qu'il est — un **trou**
/// dans la forme, cerné par la bordure noire — et non une échancrure.
///
/// **Le piège du bouchage par balayage.** Combler, sur chaque ligne, tout ce qui
/// se trouve entre le premier et le dernier pixel de carte est juste pour un
/// objet isolé, et faux pour une grille : cela soude une rangée entière. Une
/// première version ne voyait plus que trois blocs au lieu de onze cartes, et
/// aucune érosion ne pouvait les redécouper — elles étaient soudées sur toute
/// leur longueur. Un trou, c'est du fond **qui ne touche pas le bord de
/// l'image** : on inonde le fond depuis les bords, ce qui reste sec est un trou.
///
/// **Ce que ça vaut, mesuré.** Sur une photo de onze cartes séparées par un
/// jour : onze formes, chacune épousant sa carte. Sur dix-sept cartes
/// **jointives** : dix formes seulement. La méthode exige un espace — c'est une
/// contrainte de geste, à dire à l'utilisateur plutôt qu'à compenser.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Une carte repérée dans la photo, en fractions de l'image.
class CardBounds {
  const CardBounds(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  bool contains(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;
}

/// Largeur de travail, en pixels.
///
/// **L'endroit où la courbe s'aplatit.** Mesuré sur une photo de onze cartes,
/// en faisant varier la seule résolution :
///
/// | largeur | pixels | durée | cartes trouvées |
/// |---|---|---|---|
/// | 400 px | 212 k | 192 ms | 7 |
/// | 600 px | 478 k | 310 ms | 9 |
/// | **800 px** | 850 k | **499 ms** | **10** |
/// | 1200 px | 1 912 k | 871 ms | 10 |
/// | 1600 px | 3 400 k | 1 400 ms | 10 |
///
/// Deux enseignements. En dessous de 800, le résultat se dégrade franchement :
/// les jours entre cartes ne font plus assez de pixels pour séparer les formes.
/// Au-dessus, **on ne gagne plus rien** — les mêmes dix cartes, pour trois fois
/// le temps.
///
/// Le coût suit à peu près le nombre de pixels : quadrupler la surface
/// multiplie la durée par 2,8, pas par 4 — l'inondation et l'étiquetage
/// parcourent chaque pixel un petit nombre de fois, et le redimensionnement
/// initial se paie une fois pour toutes.
///
/// La contrepartie physique : à cette taille, un pixel vaut environ un tiers de
/// millimètre sur une photo cadrée à quatre cartes de large. Monter la
/// résolution permettrait des jours plus fins entre les cartes — mais des jours
/// qu'on ne conseillerait pas, puisqu'ils ne tiendraient qu'à quelques pixels.
const int _workWidth = 800;

/// Part de la surface encrée en deçà de laquelle une forme est du bruit.
const double _minAreaShare = 0.01;

/// Rapport hauteur/largeur acceptable pour une carte.
///
/// Une carte fait 63 × 88 mm, soit 1,40. Posée de travers, sa boîte englobante
/// s'écarte de ce rapport : la fourchette l'accompagne sans accepter une lame de
/// parquet ni une ombre allongée.
const double _minRatio = 1.15;
const double _maxRatio = 1.75;

/// Élargissement du rectangle avant d'y chercher les lignes.
///
/// **Le nom déborde de sa carte.** Il est imprimé à deux pour cent du bord, et
/// le masque s'arrête sur la bordure noire : le centre de sa ligne tombe parfois
/// dehors. Mesuré, le débordement monte à 5,3 %.
///
/// Trop élargir fait entrer le nom de la carte voisine — à 14,4 % sur une photo
/// aux cartes bien séparées. Balayé sur le résultat final : en dessous de 6 %,
/// une fausse carte réapparaît ; de 6 % à 14 %, le résultat ne bouge plus. Huit
/// pour cent tient le milieu de cette bande.
const double boundsMargin = 0.08;

/// Profondeur au-delà de laquelle une ligne est une citation, non un nom.
///
/// **Le rang ne suffit pas, il faut une distance absolue.** La règle « garder le
/// plus proche du bord » rejetait *Gorille mercenaire*, une vraie carte : son
/// nom débordait sur le rectangle de sa voisine, où un autre nom se trouvait
/// encore plus au bord. Perdre une vraie carte coûte plus que garder une
/// citation qu'on décoche.
///
/// Mesuré, en fraction de la carte, sur les lignes présentes dans un rectangle
/// qui en a élu une autre :
///
/// | | profondeur |
/// |---|---|
/// | vrai nom débordant de chez la voisine | 2,7 % à 8 % |
/// | citation d'ambiance | 14 % — et 15 à 22 % sur une autre photo |
///
/// Onze pour cent tient le milieu. Un nom reste donc rejeté seulement s'il est
/// **à la fois** moins au bord qu'un autre et franchement enfoncé dans la carte.
const double citationDepth = 0.11;

/// Écart de surface toléré avec la carte médiane.
///
/// **Un bloc de cartes soudées peut avoir le rapport d'une carte.** Sur une
/// photo d'épreuve, un groupe couvrant 49 % de la surface encrée présentait un
/// rapport de 1,44 — celui d'une carte. Le rapport ne suffit donc pas à
/// reconnaître une carte isolée ; la surface, si, dès qu'on a plusieurs
/// rectangles à comparer.
const double _areaTolerance = 2.0;

/// Ne garde que les rectangles dont la taille est celle d'une carte isolée.
///
/// Sert à n'appliquer le filtrage des citations que là où l'on sait ce qu'on
/// regarde. Un bloc soudé est écarté : ses lignes retombent alors sur le
/// comportement d'avant, sans filtrage — jamais pire, souvent mieux.
List<CardBounds> singleCards(List<CardBounds> found) {
  if (found.length < 3) return found;
  final areas = found.map((c) => c.width * c.height).toList()..sort();
  final median = areas[areas.length ~/ 2];
  return found
      .where((c) => c.width * c.height <= median * _areaTolerance)
      .toList(growable: false);
}

/// Jour minimal conseillé entre deux cartes, en millimètres.
///
/// **Mesuré en refermant le jour pas à pas.** Sur la photo qui fonctionne, les
/// écarts réels vont de 0,7 à 9,9 mm (médiane 3,5). Combler seulement 0,7 mm
/// fait tomber le compte de onze cartes à sept : les jours les plus serrés ne
/// tenaient qu'à un pixel. Cinq millimètres laissent une quinzaine de pixels à
/// la résolution de travail — assez pour que le résultat ne dépende plus de la
/// chance.
const double recommendedGapMillimetres = 5;

/// Repère les cartes d'une photo d'étalement.
///
/// Rend leurs rectangles en fractions de l'image, dans l'ordre de lecture.
/// Une liste vide signifie que rien ne ressemble à une carte — image trop
/// sombre, cartes jointives, ou cadrage trop lointain.
///
/// [workWidth] n'est ouvert que pour la mesure : `tool/find_cards.dart` compare
/// coût et résultat à plusieurs résolutions. Le produit appelle toujours cette
/// fonction sans l'argument.
List<CardBounds> findCards(img.Image photo, {int workWidth = _workWidth}) {
  final work = photo.width > workWidth
      ? img.copyResize(photo, width: workWidth)
      : photo;
  final w = work.width;
  final h = work.height;

  final mask = _inkMask(work);
  _fillHoles(mask, w, h);

  final labels = Int32List(w * h);
  final count = _label(mask, labels, w, h);

  var inked = 0;
  for (final on in mask) {
    if (on) inked++;
  }
  final floor = inked * _minAreaShare;

  final found = <CardBounds>[];
  final boxes = List.generate(count + 1, (_) => <int>[w, h, -1, -1, 0]);
  for (var i = 0; i < labels.length; i++) {
    final id = labels[i];
    if (id == 0) continue;
    final x = i % w;
    final y = i ~/ w;
    final box = boxes[id];
    if (x < box[0]) box[0] = x;
    if (y < box[1]) box[1] = y;
    if (x > box[2]) box[2] = x;
    if (y > box[3]) box[3] = y;
    box[4]++;
  }

  for (var id = 1; id <= count; id++) {
    final box = boxes[id];
    if (box[4] < floor) continue;
    final bw = max(box[2] - box[0], 1);
    final bh = max(box[3] - box[1], 1);
    final ratio = max(bw, bh) / min(bw, bh);
    if (ratio < _minRatio || ratio > _maxRatio) continue;
    found.add(
      CardBounds(box[0] / w, box[1] / h, box[2] / w, box[3] / h),
    );
  }

  found.sort((a, b) {
    final byRow = a.top.compareTo(b.top);
    return byRow != 0 ? byRow : a.left.compareTo(b.left);
  });
  return found;
}

/// Vrai là où le pixel appartient vraisemblablement à une carte.
///
/// **Deux signaux plutôt qu'un.** La table est un bois clair et peu saturé ; les
/// bordures de carte sont noires et les illustrations colorées. Un pixel sombre
/// *ou* saturé échappe donc au bois, là où la seule luminosité laisserait
/// passer les zones claires d'une illustration.
///
/// La référence de clarté est prise sur les pixels les plus clairs plutôt que
/// sur la moyenne : les cartes occupent souvent plus de la moitié de l'image, et
/// une moyenne globale serait tirée vers le sombre par les cartes elles-mêmes.
List<bool> _inkMask(img.Image photo) {
  final n = photo.width * photo.height;
  final greys = Uint8List(n);
  final sats = Uint8List(n);

  var i = 0;
  for (var y = 0; y < photo.height; y++) {
    for (var x = 0; x < photo.width; x++) {
      final pixel = photo.getPixel(x, y);
      final r = pixel.r.toInt();
      final g = pixel.g.toInt();
      final b = pixel.b.toInt();
      final high = max(r, max(g, b));
      final low = min(r, min(g, b));
      greys[i] = ((r + g + b) ~/ 3).clamp(0, 255);
      sats[i] = high == 0 ? 0 : ((high - low) * 255 ~/ high);
      i++;
    }
  }

  final sorted = Uint8List.fromList(greys)..sort();
  final table = sorted[(sorted.length * 0.70).floor()].toDouble();
  final darkBelow = table * 0.72;
  const saturated = 0.38 * 255;

  return List<bool>.generate(
    n,
    (k) => greys[k] < darkBelow || sats[k] > saturated,
    growable: false,
  );
}

/// Comble les trous : le fond qui ne touche pas le bord appartient à une carte.
void _fillHoles(List<bool> mask, int w, int h) {
  final outside = Uint8List(w * h);
  final stack = <int>[];

  void seed(int index) {
    if (mask[index] || outside[index] != 0) return;
    outside[index] = 1;
    stack.add(index);
  }

  for (var x = 0; x < w; x++) {
    seed(x);
    seed((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    seed(y * w);
    seed(y * w + w - 1);
  }

  while (stack.isNotEmpty) {
    final index = stack.removeLast();
    final x = index % w;
    final y = index ~/ w;
    if (x > 0) seed(index - 1);
    if (x < w - 1) seed(index + 1);
    if (y > 0) seed(index - w);
    if (y < h - 1) seed(index + w);
  }

  for (var i = 0; i < mask.length; i++) {
    if (outside[i] == 0) mask[i] = true;
  }
}

/// Étiquette les composantes connexes, en 4-voisinage.
///
/// Pile explicite plutôt que récursion : une composante peut couvrir des
/// centaines de milliers de pixels, et la pile d'appels n'y suffirait pas.
int _label(List<bool> mask, Int32List labels, int w, int h) {
  var current = 0;
  final stack = <int>[];

  for (var start = 0; start < mask.length; start++) {
    if (!mask[start] || labels[start] != 0) continue;
    current++;
    labels[start] = current;
    stack.add(start);

    while (stack.isNotEmpty) {
      final index = stack.removeLast();
      final x = index % w;
      final y = index ~/ w;

      void visit(int next) {
        if (mask[next] && labels[next] == 0) {
          labels[next] = current;
          stack.add(next);
        }
      }

      if (x > 0) visit(index - 1);
      if (x < w - 1) visit(index + 1);
      if (y > 0) visit(index - w);
      if (y < h - 1) visit(index + w);
    }
  }
  return current;
}
