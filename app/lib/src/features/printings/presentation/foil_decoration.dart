/// Fond d'une ligne selon la finition de l'exemplaire qu'elle décrit.
///
/// **Pourquoi un fond et pas seulement un mot.** Le brillant était signalé par
/// un « · foil » en petits caractères, au bout d'une ligne d'édition déjà
/// chargée. Sur une collection qu'on parcourt au défilement, cette mention se
/// lit une fois qu'on l'a cherchée — or c'est précisément ce qu'on ne fait pas
/// en faisant défiler. Le brillant mérite d'être vu sans être lu : il vaut
/// couramment le double ou le triple de sa jumelle normale, et c'est ce qui
/// distingue deux lignes par ailleurs identiques.
///
/// **Irisé, pas coloré.** Le dégradé passe du cyan au doré en traversant un
/// violet, ce qui imite la diffraction d'une carte brillante inclinée. Chaque
/// teinte est fondue dans la couleur de surface du thème plutôt que posée
/// dessus : la ligne reste dans la palette de l'application et le texte garde
/// son contraste, quel que soit le thème.
library;

import 'package:flutter/material.dart';

const double _radius = 14;

/// Teintes de diffraction, fondues dans la surface. Les opacités sont basses à
/// dessein : au-delà, le dégradé passe devant le nom de la carte, alors qu'il
/// n'est là que pour le qualifier.
const _sheen = <(Color, double)>[
  (Color(0xFF00E5FF), 0.15), // cyan
  (Color(0xFFB388FF), 0.10), // violet
  (Color(0xFFFFD54F), 0.20), // or
];

/// Décoration d'une ligne de collection.
///
/// Sans brillant, c'est la surface ordinaire — le fond irisé perdrait tout son
/// pouvoir de signal s'il habillait aussi les lignes qu'il doit distinguer.
BoxDecoration foilDecoration(ThemeData theme, {required bool foil}) {
  final radius = BorderRadius.circular(_radius);
  final surface = theme.colorScheme.surfaceContainerHigh;

  if (!foil) {
    return BoxDecoration(color: surface, borderRadius: radius);
  }

  return BoxDecoration(
    borderRadius: radius,
    border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.5)),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        for (final (color, alpha) in _sheen)
          Color.alphaBlend(color.withValues(alpha: alpha), surface),
      ],
      stops: const [0, 0.55, 1],
    ),
  );
}

/// Reflet de diffraction posé **sur** une carte brillante.
///
/// **Un fond ne convient pas quand la carte occupe toute la case.** Le dégradé
/// de [foilDecoration] se glisse derrière une ligne de texte ; sur une image
/// pleine, il serait entièrement masqué. Il faut donc le poser par-dessus, en
/// laissant la carte lisible au travers.
///
/// **Un reflet plutôt qu'un symbole.** Une icône dit « cette carte est
/// brillante » ; elle ne le montre pas. Or ce que l'on reconnaît d'un classeur
/// ouvert, c'est justement l'éclat d'une pochette qui accroche la lumière au
/// milieu de cartes mates.
///
/// Les opacités restent basses — la diffraction qualifie la carte, elle ne la
/// remplace pas — et la bande claire traverse en diagonale, comme une pochette
/// inclinée sous une lampe.
class FoilSheen extends StatelessWidget {
  const FoilSheen({
    super.key,
    required this.child,
    required this.foil,
    this.borderRadius,
  });

  final Widget child;

  /// Sans brillant, l'enfant est rendu tel quel : le reflet perdrait tout son
  /// pouvoir de signal s'il habillait aussi les cartes qu'il doit distinguer.
  final bool foil;

  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    if (!foil) return child;

    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        // Le reflet ne doit pas intercepter les gestes destinés à la carte.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0x0000E5FF),
                  Color(0x4D00E5FF), // cyan, au tiers
                  Color(0x33B388FF), // violet
                  Color(0x59FFD54F), // or, aux deux tiers
                  Color(0x00FFD54F),
                ],
                stops: [0, 0.28, 0.5, 0.72, 1],
              ),
            ),
          ),
        ),
        // Un liseré coloré ferme le reflet sur les bords, là où une pochette
        // brillante renvoie le plus de lumière.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.65),
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
