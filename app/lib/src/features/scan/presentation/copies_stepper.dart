/// Le compte d'exemplaires qu'on ajuste à la main : « − n + ».
///
/// **Un seul composant pour deux écrans** (#44). L'étalement l'avait en ligne,
/// parce que la lecture des noms ne distingue pas deux cartes côte à côte d'un
/// nom lu deux fois ; le panier du flux en a besoin pour la raison inverse —
/// `CardTracker` compte deux passages quand on repose une carte et qu'on la
/// remontre, et c'est le geste qui est ambigu, pas la mesure. Deux copies du
/// même bloc auraient fini par diverger sur exactement les détails qui
/// comptent : la cible tactile, le blocage à un.
///
/// **Resserré, pour rendre au nom la place que le compte prend.** Deux boutons
/// pleine taille et leur nombre occupaient 116 dp des 360 d'un téléphone
/// étroit ; l'aperçu montrait « Levée de b… » là où le nom tient largement. La
/// cible tactile reste au-dessus des 40 dp que réclame Material. Compté :
/// **104 dp** en tout — deux cibles de 40, 16 pour le nombre, 4 de marge de
/// part et d'autre —, et c'est ce chiffre qui fixe la largeur minimale d'une
/// tuile du panier pour le recevoir ([minWidth]).
///
/// **Il ne descend pas sous un.** Retirer le dernier exemplaire n'est pas ce
/// geste : chaque écran a le sien pour écarter une ligne, et il reste visible.
/// Le bouton est inactif plutôt qu'absent, pour que la forme ne bouge pas.
///
/// Sans état : il montre [quantity] et appelle [onIncrement] / [onDecrement] ;
/// c'est l'appelant qui tient le nombre, et c'est ce qui le rend testable sans
/// panier ni étalement.
library;

import 'package:flutter/material.dart';

class CopiesStepper extends StatelessWidget {
  const CopiesStepper({
    super.key,
    required this.quantity,
    required this.onIncrement,
    required this.onDecrement,
    this.enabled = true,
    this.style,
  });

  final int quantity;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  /// Faux pendant un enregistrement : on ne modifie pas un compte en cours
  /// d'écriture.
  final bool enabled;

  /// Le style du nombre. `titleMedium` du thème par défaut ; le panier le
  /// passe en clair, sur son bandeau sombre.
  final TextStyle? style;

  /// Largeur que le composant occupe, d'un bord à l'autre.
  ///
  /// C'est ce chiffre, et non un seuil choisi, qui dit si une tuile peut
  /// l'accueillir.
  static const double minWidth = 40 + 4 + 16 + 4 + 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.remove_circle_outline),
          tooltip: 'Un de moins',
          color: style?.color,
          onPressed: enabled && quantity > 1 ? onDecrement : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('$quantity', style: style ?? theme.textTheme.titleMedium),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.add_circle_outline),
          tooltip: 'Un de plus',
          color: style?.color,
          onPressed: enabled ? onIncrement : null,
        ),
      ],
    );
  }
}
