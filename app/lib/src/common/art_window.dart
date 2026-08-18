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
library;

import 'package:flutter/widgets.dart';

import '../features/scan/domain/art_box.dart';
import 'card_image.dart';

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

  @override
  Widget build(BuildContext context) {
    final box = frame?.box;
    if (box == null) {
      return CardImage(url: url, fit: BoxFit.cover);
    }

    // Le resserrement ne peut pas retourner la fenêtre : sur un cadre déjà
    // étroit, on prend la moitié de ce qui reste plutôt que rien.
    final marge = inset.clamp(
      0.0,
      ((box.right - box.left).clamp(0.0, 1.0)) / 4,
    );
    final gauche = box.left + marge;
    final haut = box.top + marge;
    final largeur = (box.right - marge) - gauche;
    final hauteur = (box.bottom - marge) - haut;

    // **On agrandit l'image jusqu'à ce que la FENÊTRE remplisse la place**,
    // puis `alignment` décide quelle partie reste visible.
    //
    // `FractionallySizedBox` plutôt qu'un `OverflowBox` dans un
    // `LayoutBuilder` : la première version faisait cela, et l'écran des
    // comptes s'affichait **entièrement vide** — sans bandeau rouge, sans trace
    // dans le journal. Le reste de l'application fonctionnait, ce qui rendait
    // la panne d'autant plus discrète. Ce widget-ci travaille en fractions des
    // contraintes reçues, sans avoir à les mesurer lui-même.
    return ClipRect(
      child: FractionallySizedBox(
        widthFactor: 1 / largeur,
        heightFactor: 1 / hauteur,
        alignment: Alignment(_align(gauche, largeur), _align(haut, hauteur)),
        child: CardImage(url: url, fit: BoxFit.fill),
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
