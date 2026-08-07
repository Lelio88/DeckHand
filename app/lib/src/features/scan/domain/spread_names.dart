/// Repérage de plusieurs cartes sur une même photo, par leurs noms.
///
/// **Renversement d'approche.** Les tentatives précédentes découpaient l'image
/// pour isoler chaque carte — seuillage, fermeture morphologique, composantes
/// connexes — et plafonnaient à 57 % de rappel : les cartes se pulvérisaient en
/// fragments, et les recoller soudait les voisines (voir `docs/spread-detection.md`).
///
/// Lire le texte rend ce découpage inutile. Chaque carte porte son nom en clair,
/// et un nom retrouvé au catalogue *est* une carte détectée : la séparation
/// devient un effet de bord de la lecture, plus un problème à résoudre.
///
/// Ce module ne fait que préparer les candidats. Décider lesquels sont de vraies
/// cartes revient au catalogue, seul à pouvoir trancher.
library;

import 'card_name_text.dart';

/// Une ligne susceptible d'être un nom de carte, avec sa position.
class NameCandidate {
  const NameCandidate(this.text, this.top);

  final String text;

  /// Position verticale, en fraction de la hauteur de l'image. Sert à regrouper
  /// les cartes d'une même rangée, et à ordonner les propositions.
  final double top;
}

/// Nombre maximal de lignes envoyées au catalogue.
///
/// Une photo d'étalement produit des dizaines de lignes ; toutes les chercher
/// coûterait autant de requêtes. Les noms étant courts et bien formés, le
/// filtrage en écarte déjà l'essentiel — ce plafond n'est qu'un garde-fou contre
/// une photo pleine de texte parasite.
const int maxSpreadCandidates = 40;

/// Rapport minimal entre la hauteur d'une ligne et la hauteur médiane.
///
/// **C'est ce qui distingue un nom de son texte de règles.** Sur toute carte
/// Magic, le nom est imprimé nettement plus gros que le corps de texte — de
/// l'ordre du double. Or les règles citent régulièrement des noms de cartes
/// (« Foudre inflige 3 blessures… »), et une ligne de règles qui contient un nom
/// produisait une carte fantôme : sur un étalement de six cartes, huit étaient
/// proposées dont trois inventées.
///
/// La hauteur médiane sert de référence plutôt qu'une valeur absolue : elle
/// s'adapte à la distance de prise de vue. Le seuil est bas (1,25) pour tolérer
/// les cartes photographiées de biais, dont le texte paraît plus petit d'un côté.
const double _nameHeightRatio = 1.25;

/// Extrait les lignes plausibles comme noms de cartes, dans l'ordre de lecture.
///
/// À la différence de [cardNameCandidates], **aucune zone n'est privilégiée** :
/// sur un étalement, les noms sont répartis dans toute l'image. C'est la taille
/// du texte, le filtrage du bruit et la confrontation au catalogue qui font le
/// tri.
List<NameCandidate> spreadNameCandidates(List<ReadLine> lines) {
  final seen = <String>{};
  final candidates = <NameCandidate>[];

  final ordered = [...lines]..sort((a, b) => a.top.compareTo(b.top));
  final threshold = _medianHeight(ordered) * _nameHeightRatio;

  for (final line in ordered) {
    // Une photo d'une seule ligne n'a pas de médiane exploitable : on laisse
    // alors passer, le catalogue tranchera.
    if (threshold > 0 && line.height < threshold) continue;

    final text = cleanNameLine(line.text);
    if (!looksLikeCardName(text)) continue;
    if (!seen.add(text.toLowerCase())) continue;

    candidates.add(NameCandidate(text, line.top));
    if (candidates.length >= maxSpreadCandidates) break;
  }

  return candidates;
}

/// Hauteur médiane des lignes lues, référence de ce qu'est un « petit » texte.
///
/// Médiane et non moyenne : le texte de règles domine largement en nombre de
/// lignes, si bien que la médiane tombe dessus — exactement la référence
/// voulue. Une moyenne serait tirée vers le haut par les titres.
double _medianHeight(List<ReadLine> lines) {
  if (lines.length < 4) return 0;
  final heights = lines.map((l) => l.height).toList()..sort();
  return heights[heights.length ~/ 2];
}

/// Score en deçà duquel une correspondance n'est pas retenue.
///
/// Une ligne quelconque trouve toujours *quelque chose* dans un catalogue de
/// 31 634 cartes ; c'est le score qui distingue la trouvaille du hasard. Le
/// seuil est haut à dessein : sur un étalement, mieux vaut manquer une carte —
/// l'utilisateur la voit et la rajoute — que d'en inventer une qu'il validera
/// sans y penser, faussant ensuite toutes les suggestions de decks.
const double spreadScoreThreshold = 0.72;
