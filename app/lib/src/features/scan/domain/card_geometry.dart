/// Proportions physiques d'une carte, par jeu.
///
/// **Ce rapport n'est pas une constante du produit.** Il l'a été tant que les
/// deux premiers jeux couverts partageaient le même carton — Magic et Riftbound
/// impriment tous deux en 63 × 88 mm —, et il était écrit en dur à huit endroits
/// du dépôt sans que rien ne le signale. Le jeu suivant le fera tomber :
/// Yu-Gi-Oh imprime plus petit.
///
/// **Ce que ce rapport décide.** Deux choses, et la seconde est celle qui coûte :
///
/// - il dit si un quadrilatère détecté est une carte ou un rectangle suspect
///   (`findCard`) — là, la tolérance de 0,30 est si large que 4 % d'écart
///   passeraient inaperçus ;
/// - il dit **ce qu'on découpe quand la détection renonce** (`cropToCardFrame`).
///   C'est le repli, et il n'a pas de tolérance : un découpage au mauvais
///   rapport, suivi du bon gabarit d'illustration, rend une empreinte plausible
///   et donc une mauvaise carte. L'échec ne s'annonce pas.
///
/// **Pur, et sans aucun import.** Ce module est lu par le domaine du scan, par
/// le sélecteur de jeu et par les vues du classeur. Le garder sans dépendance
/// évite d'y traîner Flutter d'un côté ou `package:image` de l'autre, et permet
/// au jumeau Python `api/app/vision/card_geometry.py` d'en être la copie exacte.
library;

/// Rapport largeur sur hauteur d'une carte debout, par jeu.
///
/// **Mesuré, pas déduit d'un catalogue d'images.** Un rendu peut porter des
/// marges ou un rognage qui ne sont pas ceux du carton, alors que c'est bien le
/// carton que la photo montre. Pour les deux jeux couverts, les deux
/// coïncident : le carton fait 63 × 88 mm (0,7159) et le rendu Riftbound
/// 744 × 1039 (0,7160), à un millième près.
///
/// Ajouter un jeu ici est **obligatoire** : sans entrée, il retombe sur
/// [defaultCardAspect] en silence. `card_geometry_test.dart` verrouille le
/// point — tout jeu déclaré dans `Game` doit figurer dans cette table.
const Map<String, double> cardAspects = {
  // Magic : 63 × 88 mm. Le rendu Scryfall fait 745 × 1040, soit 0,7163.
  'magic': 63 / 88,
  // Riftbound : même carton que Magic. Mesuré sur le catalogue, une carte
  // debout fait 744 × 1039 et une couchée 1039 × 744 — ce n'est pas un autre
  // format, c'est la même carte tournée d'un quart de tour.
  'riftbound': 63 / 88,
  // Yu-Gi-Oh : 59 × 86 mm, le premier jeu couvert qui n'imprime pas au format
  // des deux autres. **Le rendu de la source s'aligne sur le carton**, ce que
  // rien ne garantissait : mesuré sur 20 cartes de dix cadres différents,
  // 813 × 1185 soit 0,6861, contre 0,68605 pour 59 × 86. C'est la vérification
  // que le paramétrage de ce module attendait pour cesser d'être théorique.
  'yugioh': 59 / 86,
  // Pokémon : même carton que Magic, 63 × 88 mm.
  //
  // **Le rendu de la source ne s'y aligne pas**, contrairement aux trois autres
  // jeux : TCGdex publie 600 × 825, soit 0,7273 contre 0,7159 pour le carton —
  // 1,6 % d'écart, la plus grande divergence rencontrée jusqu'ici. C'est le
  // carton qui gagne, parce que c'est lui que la photo montre, et c'est la règle
  // que ce module s'est donnée dès Riftbound.
  //
  // **Ce que cet écart laisse en suspens** : les fenêtres d'illustration de #28
  // ont été mesurées sur les rendus, en proportions de ceux-ci. Appliquées à une
  // photo de carton, elles peuvent glisser d'environ 1 % en hauteur. Trop peu
  // pour manquer une illustration, assez pour valoir une vérification — celle
  // qu'aucune carte de papier n'a encore permise, faute d'en posséder une.
  'pokemon': 63 / 88,
  // Wankul : format standard présumé, **non vérifié sur carton**.
  //
  // C'est la seule entrée de cette table qui ne repose sur aucune mesure. Les
  // quatre autres ont été confrontées soit au rendu de leur source, soit au
  // carton ; celle-ci sera à vérifier dès qu'une carte sera photographiée, au
  // même titre que la fenêtre d'illustration. La déclarer explicitement plutôt
  // que de la laisser tomber sur `defaultCardAspect` est délibéré : le repli
  // signifie « jeu ajouté sans ses proportions », et le test qui l'attrape doit
  // continuer de servir à ça.
  'wankul': 63 / 88,
  // Star Wars Unlimited : même carton que Magic, 63 × 88 mm.
  //
  // **Le rendu de la source s'y aligne**, mesuré sur 1 428 rendus : 0,7154 à
  // 0,7186 pour les cartes debout, 1,3929 à 1,3978 pour les couchées —
  // l'inverse exact, à 0,4 % près. C'est la même carte tournée d'un quart de
  // tour, comme chez Riftbound.
  //
  // Cette source publie treize formats de rendu, de 1117 × 1560 à 418 × 300,
  // là où les autres n'en ont qu'un. Le rapport, lui, ne bouge pas : c'est
  // l'échelle qui varie, pas la géométrie.
  'swu': 63 / 88,
  // One Piece : même carton que Magic, 63 × 88 mm.
  //
  // **Le rendu s'y aligne**, mesuré sur les deux tailles publiées : 600 × 838
  // et 868 × 1213, soit 0,7160 et 0,7156 — le carton valant 0,7159, elles
  // l'encadrent à un dix-millième. Toutes les cartes sont debout.
  'onepiece': 63 / 88,
  // Disney Lorcana : même carton que Magic, 63 × 88 mm.
  //
  // **Le rendu s'y aligne**, mesuré sur les 3 192 fichiers publiés : 488 × 681,
  // soit 0,7166 contre 0,7159 pour le carton — sept dix-millièmes.
  //
  // Y compris pour les 106 Lieux, et c'est ce qui surprend : ils sont
  // physiquement couchés, mais leur rendu sort en 488 × 681 comme les autres,
  // contenu tourné d'un quart de tour. Le rapport décrit le carton, pas le
  // fichier — et c'est le carton que la photo montre.
  'lorcana': 63 / 88,
};

/// Ce sur quoi retombe un jeu absent de [cardAspects].
///
/// **Un repli, pas une valeur par défaut légitime.** Il existe pour que la
/// reconnaissance continue de fonctionner plutôt que de lever sur un jeu
/// inconnu — refuser de scanner serait pire que scanner de travers. Mais s'y
/// retrouver signifie qu'un jeu a été ajouté sans ses proportions, ce que le
/// test doit attraper avant l'utilisateur.
const double defaultCardAspect = 63 / 88;

/// Proportions d'une carte de [game].
double cardAspectFor(String game) => cardAspects[game] ?? defaultCardAspect;


/// La zone du champ où l'on accepte de chercher une carte.
///
/// **Déclarer où l'on pose ses cartes vaut mieux que distinguer une carte d'une
/// boîte.** Deux photos de décor sur douze produisaient encore un quadrilatère
/// — une boîte de boosters, une serviette imprimée : de vrais rectangles posés,
/// que rien de géométrique ne sépare d'une carte. Les écarter en regardant leur
/// contenu serait un chantier ; les mettre hors du champ regardé n'en est pas
/// un, et c'est ce que l'utilisateur sait de toute façon — il pose ses cartes
/// au même endroit.
///
/// En fractions de l'image du **capteur**, comme les coins que la détection
/// rend : c'est l'écran qui sait de combien il tourne son aperçu.
class ScanRegion {
  const ScanRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// Tout le champ — ce que voit une caméra à qui l'on n'a rien demandé.
  static const ScanRegion whole = ScanRegion(
    left: 0,
    top: 0,
    right: 1,
    bottom: 1,
  );

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// Vrai lorsque la zone couvre tout : il n'y a alors rien à restreindre, et
  /// le chemin ordinaire évite un recadrage qui ne retirerait rien.
  bool get isWhole => left <= 0 && top <= 0 && right >= 1 && bottom >= 1;

  /// La même zone, ramenée dans des bornes utilisables.
  ///
  /// **Une zone dégénérée ne doit pas atteindre la détection.** Un rectangle
  /// glissé jusqu'à devenir un trait rendrait une image d'un pixel de large, où
  /// tout est un bord et rien n'est une carte.
  ScanRegion get sane {
    final l = left.clamp(0.0, 1.0);
    final t = top.clamp(0.0, 1.0);
    final r = right.clamp(0.0, 1.0);
    final b = bottom.clamp(0.0, 1.0);
    if (r - l < minRegionSide || b - t < minRegionSide) return whole;
    return ScanRegion(left: l, top: t, right: r, bottom: b);
  }

  @override
  bool operator ==(Object other) =>
      other is ScanRegion &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Côté minimal d'une zone, en fractions.
///
/// En deçà, une carte n'y tiendrait de toute façon pas : elle occupe au moins
/// un dixième du champ pour que son illustration porte du détail.
const double minRegionSide = 0.15;
