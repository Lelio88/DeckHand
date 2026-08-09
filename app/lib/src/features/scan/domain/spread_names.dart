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
/// **Ce plafond a longtemps été le vrai goulot, sans qu'on le sache.** Il était
/// à 40, et coupait les candidats **par position**, de haut en bas : sur une
/// photo de dix-sept cartes entières, 141 lignes sont lues, 85 passent le filtre
/// de taille, et les quarante-cinq dernières n'étaient jamais interrogées — donc
/// les cartes des rangées du bas restaient invisibles.
///
/// Le symptôme trahissait la cause : désactiver le filtre de taille *dégradait*
/// le résultat, parce que plus de lignes passaient et que le plafond coupait
/// d'autant plus tôt dans la photo. Mesuré à seuil constant, le seul passage de
/// 40 à 150 fait monter le rappel de 47 % à 65 %, sans une fausse carte de plus.
///
/// Il reste un garde-fou : chaque candidat coûte une requête, et une photo
/// pleine de texte parasite ne doit pas en déclencher des centaines. Les
/// requêtes partent par lots pour que ce volume reste tenable.
const int maxSpreadCandidates = 150;

/// Rapport minimal entre la hauteur d'une ligne et la hauteur médiane.
///
/// **Zéro : ce filtre est désactivé, et c'est une conclusion, pas un oubli.**
/// Il avait été introduit pour empêcher les textes de règles de fabriquer des
/// cartes fantômes — sur toute carte Magic, le nom est imprimé plus gros que le
/// corps de texte. Quatre mesures successives l'ont démonté :
///
/// 1. Il ne mesurait pas la taille du texte mais sa **longueur** : la hauteur
///    venait d'une boîte alignée sur les axes, qui grandit avec la ligne dès que
///    la carte penche. Corrélation de 0,965 avec le nombre de caractères.
/// 2. Corrigé — hauteur prise sur les coins du quadrilatère —, il ne séparait
///    plus rien : sur un étalement de cartes entières, le rapport entre la plus
///    grande ligne et la médiane tombe à **1,20**. Il n'y a pas deux populations.
/// 3. Il **masquait le vrai goulot** : plus il laissait passer de lignes, plus le
///    plafond de candidats coupait tôt dans la photo. Le désactiver *dégradait*
///    donc le résultat, ce qui donnait l'illusion qu'il servait.
/// 4. Le plafond relevé, la mesure est sans appel — sur dix-sept cartes à plat,
///    88 % de rappel et 94 % de précision **sans** lui, contre 65 % et 92 %
///    avec. Sur un éventail de dix-neuf, 84 % et 94 % dans les deux cas.
///
/// Ce qui écarte réellement les fausses cartes est ailleurs : le seuil de score,
/// la règle de longueur relative ([minMatchLengthRatio]), le nettoyage des
/// parasites et le filtre des lignes de type.
///
/// La constante et le paramètre restent : `app/tool/sweep_spread_threshold.dart`
/// les rejoue sur des lignes réellement lues, et une photo future pourrait
/// rouvrir la question. Mais elle a été tranchée sur des chiffres.
const double nameHeightRatio = 0;

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
  int minLength = minNameLength,
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
    if (!looksLikeCardName(text, minLength: minLength)) continue;
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

/// Longueur minimale d'une ligne pour valoir nom de carte.
///
/// **C'est ce qui doit remplacer le filtre de taille.** Sur des cartes entières,
/// la taille du texte ne sépare plus rien — le rapport entre la plus grande
/// ligne et la médiane tombe à 1,20. Ce qui produit encore de fausses cartes,
/// ce sont les fragments : « ure » trouve *Ureni's Rebuff*, « Squ » trouve
/// *Squall*, « Car » trouve *Carom*. La règle de longueur relative ne les
/// attrape pas, un fragment court trouvant souvent un nom court.
///
/// Ouvert pour la mesure, comme [nameHeightRatio].
const int minNameLength = 3;

/// Score en deçà duquel une correspondance n'est pas retenue.
///
/// Une ligne quelconque trouve toujours *quelque chose* dans un catalogue de
/// 31 634 cartes ; c'est le score qui distingue la trouvaille du hasard. Le
/// seuil est haut à dessein : sur un étalement, mieux vaut manquer une carte —
/// l'utilisateur la voit et la rajoute — que d'en inventer une qu'il validera
/// sans y penser, faussant ensuite toutes les suggestions de decks.
const double spreadScoreThreshold = 0.72;
