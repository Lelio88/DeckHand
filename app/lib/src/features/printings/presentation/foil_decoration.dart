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
