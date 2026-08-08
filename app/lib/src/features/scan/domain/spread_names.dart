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
/// s'adapte à la distance de prise de vue.
///
/// **Valeur mesurée, sur un étalement réel de cinq cartes.** Le balayage donne
/// un plateau parfait — cinq cartes sur cinq, aucune fausse — entre 1,10 et
/// 1,20, et 1,15 en est le centre : 0,07 avant le premier faux positif
/// (« Vigilance », mot-clé imprimé sur la carte, à 1,08 fois la médiane), 0,06
/// avant la première carte perdue (« Agent Maria Hill », à 1,21).
///
/// | seuil | justes | fausses | manquées |
/// |---|---|---|---|
/// | sans filtre | 5 | 3 | 0 |
/// | 1,10 – 1,20 | **5** | **0** | **0** |
/// | 1,25 | 3 | 0 | 2 |
/// | 1,30 | 1 | 0 | 4 |
///
/// **L'écart entre un nom et son texte de règles est bien plus faible qu'on ne
/// le croit** : de 20 à 36 %, jamais le double. La fenêtre utile est donc
/// étroite, et elle l'est pour une raison structurelle — les cartes d'un
/// étalement ne sont pas toutes à la même distance de l'objectif, si bien que
/// le nom d'une carte au bord peut être plus petit que le texte de règles d'une
/// carte au centre. Une médiane globale ne peut pas distinguer les deux ; c'est
/// la limite de cette approche, pas un défaut de réglage.
///
/// **Publique parce qu'elle se mesure.** `app/tool/sweep_spread_threshold.dart`
/// rejoue le filtrage à différents seuils sur des lignes réellement lues par
/// l'appareil ; cette constante est la valeur qu'il cherche à départager, pas
/// une préférence à recopier ailleurs.
const double nameHeightRatio = 1.00;

/// Extrait les lignes plausibles comme noms de cartes, dans l'ordre de lecture.
///
/// À la différence de [cardNameCandidates], **aucune zone n'est privilégiée** :
/// sur un étalement, les noms sont répartis dans toute l'image. C'est la taille
/// du texte, le filtrage du bruit et la confrontation au catalogue qui font le
/// tri.
///
/// [heightRatio] n'est ouvert que pour la mesure : l'outil de balayage rejoue
/// le filtrage à différentes valeurs sur des lignes réellement lues. Le produit
/// appelle toujours cette fonction sans l'argument.
List<NameCandidate> spreadNameCandidates(
  List<ReadLine> lines, {
  double heightRatio = nameHeightRatio,
}) {
  final seen = <String>{};
  final candidates = <NameCandidate>[];

  final ordered = [...lines]..sort((a, b) => a.top.compareTo(b.top));
  final threshold = _medianHeight(ordered) * heightRatio;

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

/// Part minimale du nom trouvé que le texte lu doit couvrir.
///
/// **Un nom masqué se lit tronqué, et un tronçon trouve une autre carte.** Sur
/// un étalement, une carte à demi recouverte ne livre qu'un début de nom :
/// « Origine de » a ainsi trouvé « Origine de Thor » avec un score de 0,94 —
/// bien au-dessus du seuil — alors que la carte posée était « Origine des
/// Vengeurs ». Le score ne peut pas s'en apercevoir : le fragment *est* un
/// préfixe exact de ce qu'il a trouvé.
///
/// La longueur, elle, le trahit. Mesuré sur trois étalements réels, toute
/// correspondance juste couvre de 0,94 à 1,12 fois la longueur du nom trouvé —
/// le texte lu peut même dépasser, la lecture ajoutant des parasites — quand le
/// seul faux tombe à 0,67. Le seuil est placé entre les deux, à distance des
/// deux populations.
const double minMatchLengthRatio = 0.80;

/// Vrai si le texte lu couvre assez du nom trouvé pour être crédible.
bool isPlausibleMatch(String read, String matched) {
  if (matched.isEmpty) return false;
  return read.length >= matched.length * minMatchLengthRatio;
}

/// Score en deçà duquel une correspondance n'est pas retenue.
///
/// Une ligne quelconque trouve toujours *quelque chose* dans un catalogue de
/// 31 634 cartes ; c'est le score qui distingue la trouvaille du hasard. Le
/// seuil est haut à dessein : sur un étalement, mieux vaut manquer une carte —
/// l'utilisateur la voit et la rajoute — que d'en inventer une qu'il validera
/// sans y penser, faussant ensuite toutes les suggestions de decks.
const double spreadScoreThreshold = 0.72;
