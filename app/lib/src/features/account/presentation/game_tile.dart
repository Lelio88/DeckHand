/// La tuile d'un jeu, et la grille qui les range.
///
/// **Extraites de l'écran de compte parce que deux écrans les montrent** : le
/// sélecteur, où l'on change de jeu, et l'étape de choix, où l'on déclare ceux
/// auxquels on joue. Les recopier aurait laissé les deux diverger au premier
/// ajustement — c'est ce que `ui_coherence_test` constate ailleurs dans le
/// dépôt, où chaque écran avait réinventé une réponse déjà tranchée.
///
/// **L'image porte l'identité, le texte porte les chiffres.** Un joueur
/// reconnaît son jeu à une carte bien avant d'en lire le nom ; les compteurs, eux,
/// ne se lisent que lorsqu'on les cherche. D'où la hiérarchie : l'image occupe le
/// haut de la tuile, le nom vient sous elle, et le détail en petit.
library;

import 'package:flutter/material.dart';

import '../../../common/art_window.dart';
import '../../scan/domain/art_box.dart';

/// Une tuile de la grille : l'illustration d'une carte, puis le nom du jeu.
///
/// **La sélection se voit deux fois** — un cadre coloré et une pastille posée
/// sur l'image. Une seule des deux suffirait sur un écran clair ; sur un fond
/// sombre où les illustrations sont elles-mêmes colorées, le cadre seul se perd.
class GameTile extends StatelessWidget {
  const GameTile({
    super.key,
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.artUrl,
    this.frame,
    this.note,
    this.rank,
  });

  final String name;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;

  /// L'illustration de la carte emblématique, ou `null` tant qu'elle charge.
  ///
  /// **Nullable à dessein** : la grille s'affiche avant que la requête
  /// n'aboutisse, et un sélecteur qui attend son image pour apparaître
  /// empêcherait de changer de jeu pendant une seconde. Le fond uni tient la
  /// place, l'image s'y pose quand elle arrive.
  final String? artUrl;

  /// Le cadre dont on retient la fenêtre, ou `null` si la source publie déjà
  /// l'illustration seule.
  final CardFrame? frame;

  /// Réserve à faire connaître avant de choisir ce jeu, ou `null`.
  final String? note;

  /// Le rang de ce jeu dans un ordre en cours de composition, ou `null`.
  ///
  /// **Un chiffre plutôt qu'une coche, parce que l'ordre est l'enjeu.** À
  /// l'étape de choix, cocher trois jeux ne dit rien tant qu'on ne voit pas
  /// lequel passera premier — c'est pourtant celui-là qui décidera de l'écran
  /// d'ouverture. Le sélecteur, lui, n'a qu'un jeu courant : il laisse ce champ
  /// nul et garde sa coche.
  final int? rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        // `clipBehavior` pour que l'illustration épouse les coins arrondis :
        // sans lui, elle déborde du cadre par ses angles.
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: theme.colorScheme.surfaceContainerHighest),
                  // **L'illustration seule, pas la carte entière.** Sept
                  // sources sur huit publient le rendu complet — cadre, nom,
                  // texte de règles —, et huit tuiles côte à côte mêlaient
                  // alors des illustrations pleines et des cartes miniatures
                  // illisibles. La fenêtre vient du scan : c'est exactement la
                  // zone que la reconnaissance découpe.
                  if (artUrl != null) ArtWindow(url: artUrl!, frame: frame),
                  if (selected)
                    Positioned(top: 6, right: 6, child: _Badge(rank: rank)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer
                          : null,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.8,
                            )
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La pastille posée sur l'image d'une tuile retenue : un rang, ou une coche.
class _Badge extends StatelessWidget {
  const _Badge({this.rank});

  final int? rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        shape: BoxShape.circle,
      ),
      // Une pastille chiffrée doit rester ronde jusqu'à deux chiffres : la
      // contrainte minimale l'empêche de se resserrer sur un « 1 » étroit.
      constraints: const BoxConstraints(minWidth: 21, minHeight: 21),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(3),
      child: rank == null
          ? Icon(Icons.check, size: 15, color: theme.colorScheme.onPrimary)
          : Text(
              '$rank',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimary,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
    );
  }
}

/// Dispose des tuiles de largeur égale en rangées, sans zone défilante.
///
/// **Ce widget existe parce qu'un `GridView` imbriqué a bloqué le défilement.**
/// La recette habituelle — `shrinkWrap: true` avec
/// `NeverScrollableScrollPhysics` — laisse la grille *absorber* le geste
/// vertical plutôt que de le laisser remonter au `ListView` parent. L'écran se
/// fige, et rien ne le signale : la grille s'affiche parfaitement, elle refuse
/// seulement de bouger.
///
/// Une `Column` de `Row` n'a pas ce défaut, parce qu'elle ne défile pas du tout.
/// Elle coûte en revanche de connaître le rapport des tuiles — un `Row` ne sait
/// pas donner une hauteur à ses enfants —, d'où [aspectRatio].
class GameRows extends StatelessWidget {
  const GameRows({
    super.key,
    required this.children,
    required this.perRow,
    required this.spacing,
    required this.aspectRatio,
  });

  final List<Widget> children;
  final int perRow;
  final double spacing;

  /// Largeur sur hauteur d'une tuile. `AspectRatio` la traduit en hauteur une
  /// fois la largeur connue, ce qui reproduit `childAspectRatio` du `GridView`.
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += perRow) {
      final slice = children.skip(i).take(perRow).toList();
      rows.add(
        Row(
          // **Surtout pas `stretch`.** Une `Row` ne connaît sa hauteur qu'une
          // fois ses enfants mesurés ; leur demander de la remplir la lui
          // demande à elle, et la mise en page se referme sur elle-même. Le
          // symptôme n'est pas une exception mais un écran ENTIÈREMENT VIDE,
          // sans bandeau rouge ni trace au journal — le reste de l'application
          // continuant de fonctionner. C'est `AspectRatio` qui donne la
          // hauteur ici, et lui seul.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < perRow; j++) ...[
              if (j > 0) SizedBox(width: spacing),
              Expanded(
                // La dernière rangée peut être incomplète : on garde la place
                // vide plutôt que d'étirer la tuile restante sur deux colonnes.
                child: j < slice.length
                    ? AspectRatio(aspectRatio: aspectRatio, child: slice[j])
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
      if (i + perRow < children.length) rows.add(SizedBox(height: spacing));
    }
    return Column(children: rows);
  }
}
