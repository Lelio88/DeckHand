/// Affiche la seule zone illustrée d'une carte, découpée dans son rendu entier.
///
/// **Les sources ne publient pas toutes la même chose.** Scryfall sert
/// l'illustration détourée — `art_crop` — et rien d'autre ; les sept autres
/// servent la carte entière, cadre, nom, texte de règles et numéro compris.
/// Affichées côte à côte, les huit tuiles du sélecteur mêlaient donc des
/// illustrations pleines et des cartes miniatures dont le texte était illisible.
///
/// **La fenêtre n'est pas inventée ici : c'est celle du scan.** Chaque
/// `CardFrame` porte des proportions mesurées sur des dizaines de cartes, et
/// c'est exactement la zone que la reconnaissance découpe pour calculer une
/// empreinte. Les réutiliser à l'affichage évite d'entretenir deux vérités sur
/// « où se trouve l'illustration ».
///
/// **Magic n'a pas de fenêtre**, et c'est normal : `art_crop` *est* déjà la
/// zone illustrée. Passer `frame: null` laisse l'image intacte.
///
/// **Une fenêtre a des proportions, et les perdre déforme les visages.** La
/// première version étirait l'image jusqu'à ce que la fenêtre épouse la tuile,
/// facteur horizontal et facteur vertical calculés séparément : les deux ne sont
/// presque jamais égaux — une fenêtre d'illustration est large et basse quand
/// une tuile est presque carrée —, et l'écart passait tel quel dans le rendu.
/// Ce fichier tient donc désormais le rapport de la carte, et s'en sert.
library;

import 'package:flutter/widgets.dart';

import '../features/scan/domain/art_box.dart';
import '../features/scan/domain/card_geometry.dart';
import 'card_image.dart';

/// La fenêtre réellement affichée, en fractions de la carte.
///
/// Séparée du widget pour être mesurable sans monter d'écran : c'est elle qui
/// porte le resserrement et son garde-fou.
///
/// **Le resserrement ne peut pas retourner la fenêtre** : sur un cadre déjà
/// étroit, on prend la moitié de ce qui reste plutôt que rien.
({double left, double top, double width, double height}) artWindowRect(
  ArtBox box,
  double inset,
) {
  final marge = inset.clamp(0.0, ((box.right - box.left).clamp(0.0, 1.0)) / 4);
  final gauche = box.left + marge;
  final haut = box.top + marge;
  return (
    left: gauche,
    top: haut,
    width: (box.right - marge) - gauche,
    height: (box.bottom - marge) - haut,
  );
}

/// Rapport largeur sur hauteur du **rendu** que porte ce cadre.
///
/// **C'est le rendu qui compte ici, pas le carton** — contrairement à la
/// reconnaissance, qui découpe une photo. `cardAspects` décrit le carton ; les
/// deux coïncident partout sauf chez Pokémon, dont TCGdex publie 0,7273 pour un
/// carton à 0,7159. Ce 1,6 % d'écart laisse une déformation résiduelle du même
/// ordre, invisible à l'œil — là où l'étirement qu'il remplace atteignait 80 %.
/// Une seconde table pour l'affichage coûterait plus qu'elle ne rapporte.
///
/// **Limite connue, et elle n'est pas exercée** : deux cadres couchés — les
/// Terrains Wankul et les Lieux Lorcana — sont publiés *debout*, contenu tourné
/// d'un quart de tour. Leur fenêtre s'exprime dans le repère de la carte posée
/// sur la table, si bien qu'elle ne se pose pas telle quelle sur le fichier : il
/// faudrait le redresser d'abord, comme le fait `UprightInCell`. Aucune des
/// cartes emblématiques du sélecteur n'est dans ce cas ; le jour où l'une le
/// sera, c'est ici que la rotation devra entrer, avant le découpage.
double artWindowCardAspect(CardFrame frame) {
  final debout = cardAspectFor(frame.game);
  return frame.landscape ? 1 / debout : debout;
}

/// L'illustration d'une carte, remplissant la place qu'on lui donne.
class ArtWindow extends StatelessWidget {
  const ArtWindow({
    super.key,
    required this.url,
    this.frame,
    this.inset = 0.04,
  });

  final String url;

  /// Resserrement appliqué à la fenêtre, en fraction de la carte.
  ///
  /// **Les fenêtres du scan sont volontairement généreuses.** Elles servent à
  /// calculer une empreinte, où quelques pixels de cadre au bord ne coûtent
  /// rien — ils sont identiques sur toutes les cartes et ne font que geler des
  /// bits. À l'affichage, en revanche, ils se voient : un liseré rouge sur One
  /// Piece, le haut du bandeau « MICKEY MOUSE » sur Lorcana, les pastilles de
  /// coin sur Wankul.
  ///
  /// Quatre centièmes suffisent à les faire disparaître sans mordre sur
  /// l'illustration. Le réglage vit ici, et non dans `art_box.dart` : toucher
  /// aux gabarits déplacerait les empreintes de tout un jeu, et le scan
  /// échouerait en silence.
  final double inset;

  /// Le cadre dont on retient la fenêtre, ou `null` pour afficher tel quel.
  final CardFrame? frame;

  /// Côté d'une carte dans le repère interne du découpage.
  ///
  /// Unité arbitraire : [FittedBox] remet ensuite la fenêtre à l'échelle de la
  /// place reçue. Elle est donc sans effet sur la netteté — le moteur
  /// n'échantillonne l'image qu'une fois, avec la matrice complète — et ne joue
  /// que sur les arrondis de mise en page, d'où une valeur large.
  static const double _canvas = 1000;

  @override
  Widget build(BuildContext context) {
    final cadre = frame;
    if (cadre == null) {
      return CardImage(url: url, fit: BoxFit.cover);
    }

    final fenetre = artWindowRect(cadre.box, inset);
    final aspect = artWindowCardAspect(cadre);

    // **Le montage se lit de l'intérieur vers l'extérieur.**
    //
    // 1. `FractionallySizedBox` agrandit l'image jusqu'à ce que la FENÊTRE
    //    remplisse le `SizedBox` qui l'enveloppe, et `alignment` décide laquelle
    //    de ses parties y tombe.
    // 2. Le `SizedBox` porte exactement les proportions de la fenêtre dans le
    //    fichier — d'où [artWindowCardAspect]. C'est ce qui garantit que
    //    l'image, elle, garde les siennes : elle mesure `_canvas` sur
    //    `_canvas / aspect`, donc `BoxFit.fill` ne l'étire d'aucun côté.
    // 3. `FittedBox` en `cover` met cette fenêtre à l'échelle de la tuile. Il
    //    conserve le rapport par construction : ce qui dépasse est rogné, et
    //    rien n'est déformé.
    //
    // **Pourquoi pas un simple facteur de zoom unique.** Prendre le plus grand
    // des deux facteurs supprime bien l'étirement, mais recadre au passage : sur
    // une tuile du sélecteur, Riftbound perdait ainsi la moitié de la largeur de
    // sa fenêtre et ne montrait plus le haut de l'illustration. Le rapport de la
    // carte est ce qui manquait pour couvrir la fenêtre *et* rien de plus.
    //
    // **Ni `LayoutBuilder`, ni `OverflowBox`.** La toute première version en
    // faisait un, et l'écran des comptes s'affichait **entièrement vide** — sans
    // bandeau rouge, sans trace dans le journal. Ce montage-ci se passe de
    // mesurer quoi que ce soit : `FittedBox` sait couvrir sa place sans qu'on la
    // lui dise. Il attend en revanche des contraintes bornées, ce que lui donne
    // le `Stack` de la tuile — placé dans une colonne sans hauteur, il prendrait
    // la taille brute de `_canvas`.
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: fenetre.width * _canvas,
          height: fenetre.height * _canvas / aspect,
          child: ClipRect(
            child: FractionallySizedBox(
              widthFactor: 1 / fenetre.width,
              heightFactor: 1 / fenetre.height,
              alignment: Alignment(
                _align(fenetre.left, fenetre.width),
                _align(fenetre.top, fenetre.height),
              ),
              child: CardImage(url: url, fit: BoxFit.fill),
            ),
          ),
        ),
      ),
    );
  }

  /// Convertit une arête en alignement Flutter, de -1 à +1.
  ///
  /// La part de l'image hors fenêtre vaut `1 - taille` ; l'arête en occupe
  /// `debut`. Le rapport des deux donne la position relative, que l'échelle de
  /// [Alignment] étire ensuite de -1 à +1.
  ///
  /// **Le cas `taille == 1` est le piège** : une fenêtre pleine largeur ne
  /// laisse rien à décaler, et le rapport diviserait par zéro. Il se produit
  /// pour de vrai — `CardFrame.pokemonFull` va de 0 à 1, l'illustration *étant*
  /// la carte.
  static double _align(double debut, double taille) {
    final reste = 1 - taille;
    if (reste <= 0) return 0;
    return (debut / reste) * 2 - 1;
  }
}
