/// Rattache chaque lecture reconnue d'un étalement à la carte qui la porte.
///
/// **Une carte porte un seul nom, et compte pour un seul exemplaire.** Le
/// catalogue reconnaît plus de lignes qu'il n'y a de cartes : la ligne de
/// capacités « Vol » trouve la carte *Vol* (Flight), le texte de règles
/// « : Régénérez le Meneur de Rakdos. » retrouve la carte qui le porte, la
/// citation « —Ka-Zar » un personnage qui est aussi une carte. Chacune passe
/// le seuil de score ; aucune n'est une carte posée sur la table.
///
/// Les rectangles de cartes isolées ([findCards], [singleCards]) donnent la
/// réponse : dans un rectangle, **seule la lecture la plus proche du bout qui
/// porte les noms** est une carte. Les autres lectures qu'il contient sont
/// *absorbées* — elles ne fabriquent ni carte, ni exemplaire.
///
/// Le filtre qui précédait ne rejetait que ce qui siégeait au-delà de 70 % du
/// bout des noms. Mesuré sur une photo de neuf cartes : « Vol » était à 59 %,
/// la mention de règles de *Meneur de Rakdos* à 82 % mais sauvée par le nom de
/// la même carte — d'où une fausse carte et un exemplaire en trop.
///
/// Invariants :
///
/// - **Ne jamais ajouter.** Le résultat est un sous-ensemble des lectures
///   reçues : l'attribution peut ôter une carte ou un exemplaire, jamais en
///   inventer. Ce qu'elle ne sait pas situer est gardé tel quel.
/// - **Hors de tout rectangle, rien ne change.** Cartes jointives soudées en
///   blocs, nom qui déborde sur la voisine : ces lectures retombent sur le
///   comportement d'avant.
/// - **Un rectangle qui contredit l'orientation de la majorité n'absorbe
///   rien.** Deux cartes debout soudées côte à côte ont le rapport d'une carte
///   couchée, et le second nom y siège au milieu : l'absorber perdrait une
///   carte réelle.
///
/// Exemple :
/// ```dart
/// final r = attributeToCards(
///   lectures,
///   singleCards(findCards(photo)),
///   scaleX: lu.width / photo.width,
///   scaleY: lu.height / photo.height,
///   imageAspect: photo.width / photo.height,
/// );
/// // r.kept : une lecture par carte, plus tout ce qu'aucun rectangle ne porte.
/// ```
library;

import 'card_segmentation.dart';
import 'spread_names.dart';

/// Une lecture que le catalogue a reconnue, et la carte qu'il y a vue.
class MatchedReading {
  const MatchedReading(this.identity, this.line);

  /// Ce qui identifie la carte — l'`oracle_id` dans l'application, le nom
  /// trouvé dans les outils qui rejouent un journal.
  final String identity;

  /// La ligne lue, positionnée en fractions de l'étendue du texte lu.
  final NameCandidate line;
}

/// Le partage des lectures entre cartes et simples mentions.
class Attribution {
  const Attribution(this.kept, this.absorbed, {this.namesSitLow});

  /// Lectures qui désignent une carte posée : une par rectangle, plus celles
  /// qu'aucun rectangle ne porte. Les exemplaires se comptent sur elles seules.
  final List<MatchedReading> kept;

  /// Lectures portées par une carte dont elles ne sont pas le nom.
  final List<MatchedReading> absorbed;

  /// Le bout des cartes qui porte les noms, s'il a pu être lu dans la photo.
  final bool? namesSitLow;
}

/// Partage [readings] entre cartes et mentions, au vu des rectangles [cards].
///
/// **Les positions lues ne sont pas dans le repère de l'image.** ML Kit ne
/// communique pas la taille de la photo : les positions des lignes sont des
/// fractions de l'étendue du texte lu, quand les rectangles sont des fractions
/// de l'image. Mesuré : 1444 × 1855 lus sur une image de 1600 × 2125, soit
/// 11 et 13 % d'écart — assez pour sortir une mention de règles de sa carte.
/// [scaleX] et [scaleY] valent *étendue lue / taille de l'image*.
///
/// **L'orientation d'un rectangle se juge en pixels.** [imageAspect] vaut
/// *largeur / hauteur* de la photo en pixels : sur une photo en portrait, une
/// carte debout peut être plus large que haute en fractions de l'image.
Attribution attributeToCards(
  List<MatchedReading> readings,
  List<CardBounds> cards, {
  double scaleX = 1,
  double scaleY = 1,
  double imageAspect = 1,
}) {
  if (cards.isEmpty || readings.length < 2) {
    return Attribution(List.unmodifiable(readings), const []);
  }

  bool horizontal(CardBounds c) => c.width * imageAspect > c.height;
  final couchees = cards.where(horizontal).length;
  final majoriteCouchee = couchees * 2 > cards.length;

  // Les lectures que porte chaque rectangle, et à quelle position le long de
  // la carte — de 0 à 1 d'un bout à l'autre. Une lecture n'appartient qu'à un
  // rectangle : ils ne se chevauchent pas.
  final portees = <List<({MatchedReading reading, double at})>>[];
  final attribuees = <MatchedReading>{};
  for (final card in cards) {
    final dedans = <({MatchedReading reading, double at})>[];
    portees.add(dedans);
    if (horizontal(card) != majoriteCouchee) continue;

    final mx = card.width * boundsMargin;
    final my = card.height * boundsMargin;
    final couchee = horizontal(card);
    final lo = couchee ? card.left : card.top;
    final hi = couchee ? card.right : card.bottom;
    if (hi - lo <= 0) continue;

    for (final reading in readings) {
      if (attribuees.contains(reading)) continue;
      final x = reading.line.left * scaleX;
      final y = reading.line.top * scaleY;
      if (x < card.left - mx || x > card.right + mx) continue;
      if (y < card.top - my || y > card.bottom + my) continue;
      final at = ((couchee ? x : y) - lo) / (hi - lo);
      // Hors du rectangle le long de la carte : c'est le nom de la voisine, ou
      // le sien qui déborde. Ni l'un ni l'autre ne se juge ici.
      if (at < 0 || at > 1) continue;
      dedans.add((reading: reading, at: at));
      attribuees.add(reading);
    }
  }

  // **Le sens se lit dans la photo.** Un rectangle qui ne porte qu'une carte
  // désigne sans ambiguïté le bout des noms — à condition de prendre, parmi
  // ses lectures, la plus proche d'un bout : la mention de règles d'une carte
  // siège au milieu et voterait au hasard.
  final solitaires = <double>[];
  for (final dedans in portees) {
    if (dedans.isEmpty) continue;
    if (dedans.map((d) => d.reading.identity).toSet().length != 1) continue;
    final auBout = dedans.reduce(
      (a, b) => _versUnBout(a.at) <= _versUnBout(b.at) ? a : b,
    );
    solitaires.add(auBout.at);
  }
  if (solitaires.isEmpty) {
    return Attribution(List.unmodifiable(readings), const []);
  }
  final low = nameSitsLow(solitaires);
  double depuisLesNoms(double at) => low ? at : 1 - at;

  final absorbees = <MatchedReading>{};
  for (final dedans in portees) {
    if (dedans.isEmpty) continue;
    final nom = dedans.reduce(
      (a, b) => depuisLesNoms(a.at) <= depuisLesNoms(b.at) ? a : b,
    );
    for (final d in dedans) {
      // Au bout opposé, même la meilleure lecture est une citation : le nom
      // de cette carte n'a pas été lu, et ce qui l'a été n'en est pas un.
      if (identical(d.reading, nom.reading) &&
          depuisLesNoms(d.at) <= citationEnd) {
        continue;
      }
      absorbees.add(d.reading);
    }
  }

  return Attribution(
    List.unmodifiable(readings.where((r) => !absorbees.contains(r))),
    List.unmodifiable(readings.where(absorbees.contains)),
    namesSitLow: low,
  );
}

double _versUnBout(double at) => at < 0.5 ? at : 1 - at;
