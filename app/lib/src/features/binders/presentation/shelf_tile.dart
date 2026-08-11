/// La tuile d'une édition sur l'étagère.
///
/// **Une étagère de noms ne se distingue pas.** Cinq lignes de texte gris se
/// ressemblent toutes, alors qu'un classeur physique se reconnaît de loin — à
/// sa tranche, à sa couleur, à ce qu'on y a rangé. La tuile est donc une
/// bannière : l'illustration de la plus chère des cartes qu'on possède dans
/// l'édition, assombrie juste ce qu'il faut pour que le texte tienne dessus.
///
/// **Le voile n'est pas une décoration, c'est ce qui rend le texte lisible.**
/// Une illustration peut être claire ou sombre, et l'on ne sait pas laquelle
/// remontera : plutôt que d'espérer un contraste, on le fabrique — dégradé noir
/// en bas, texte blanc par-dessus. C'est aussi pourquoi l'habillage reste
/// achromatique : la couleur vient de l'image, pas du thème.
///
/// **La tuile ne sait pas ouvrir un classeur** et n'a donc besoin d'aucun
/// provider : elle reçoit [onOpen]. Le câblage vit dans `binder_view.dart`,
/// avec le reste de la navigation.
library;

import 'package:flutter/material.dart';

import '../domain/binder.dart';

/// Hauteur de la bannière.
///
/// Assez pour qu'une illustration recadrée — 626 × 457 chez Scryfall — se
/// reconnaisse, assez peu pour que trois ou quatre classeurs tiennent à
/// l'écran : l'étagère reste une liste qu'on parcourt.
const double _bannerHeight = 118;

/// Ce qui détache le texte clair d'une illustration quelconque.
const List<Shadow> _legibility = [
  Shadow(blurRadius: 6, color: Colors.black87),
];

class ShelfTile extends StatelessWidget {
  const ShelfTile({super.key, required this.entry, required this.onOpen});

  final BinderShelfEntry entry;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Un classeur à peine entamé mérite mieux que « 0 % » : sous le dixième, la
    // décimale dit qu'on a commencé.
    final percent = (entry.completion * 100).toStringAsFixed(
      entry.completion < 0.1 ? 1 : 0,
    );
    final cover = entry.artCropUrl;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(14),
        color: theme.colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: onOpen,
          child: SizedBox(
            height: _bannerHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Le fond coloré est peint **avant** l'illustration et reste
                // dessous : il habille l'attente du réseau, l'édition sans
                // illustration connue et l'URL qui ne répond pas, sans qu'aucun
                // de ces cas ait à être distingué.
                const _Backdrop(),
                if (cover != null)
                  Image.network(
                    cover,
                    fit: BoxFit.cover,
                    // Une image qui surgit d'un coup fait sursauter la liste ;
                    // le fond étant déjà là, un fondu suffit.
                    frameBuilder: (context, child, frame, wasSynchronous) =>
                        wasSynchronous
                        ? child
                        : AnimatedOpacity(
                            opacity: frame == null ? 0 : 1,
                            duration: const Duration(milliseconds: 240),
                            child: child,
                          ),
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                const _Veil(),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(13, 0, 13, 11),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Text(
                                entry.setName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  shadows: _legibility,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$percent %',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                shadows: _legibility,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${entry.setCode.toUpperCase()} · '
                          '${entry.ownedCells} / ${entry.totalCells} cases · '
                          '${entry.pages} pages',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.82),
                            shadows: _legibility,
                          ),
                        ),
                        const SizedBox(height: 7),
                        // La barre dit d'un coup d'œil ce que le rapport
                        // chiffré demande de calculer — c'est le taux de
                        // complétion qui fait regarder un classeur, pas le
                        // nombre de cartes.
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: entry.completion,
                            minHeight: 5,
                            // Blanc sur voile noir plutôt que la teinte du
                            // thème : la barre doit se lire sur une
                            // illustration inconnue, où l'accent du thème peut
                            // se fondre.
                            color: Colors.white,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.26,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le fond d'une tuile, sous l'illustration.
///
/// Un dégradé plutôt qu'un gris : sans couverture — édition sans illustration
/// connue, réseau absent — la tuile doit rester une tuile, pas une case vide.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
      ),
    );
  }
}

/// Ce qui rend le texte lisible sur n'importe quelle illustration.
class _Veil extends StatelessWidget {
  const _Veil();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          Colors.black.withValues(alpha: 0.86),
          Colors.black.withValues(alpha: 0.52),
          Colors.black.withValues(alpha: 0.12),
        ],
        // Le noir dense s'arrête au tiers bas, là où vit le texte : au-dessus,
        // l'illustration doit rester une illustration.
        stops: const [0, 0.5, 1],
      ),
    ),
  );
}
