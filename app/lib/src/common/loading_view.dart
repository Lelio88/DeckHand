/// Ce qu'un écran montre pendant qu'il attend, et qui change avec l'attente.
///
/// **Un seul indicateur ne peut pas servir deux attentes très différentes**, et
/// les deux existent. Mesuré sous le rôle réel, sur la séquence de lancement —
/// résumé, étagère et suggestions lancés ensemble :
///
/// | | à froid | à chaud |
/// |---|---|---|
/// | Lancement | **7,4 s** | 0,43 s |
/// | Ouvrir un classeur | 0,78 s | 0,15 s |
/// | Les neuf illustrations, version lisible | 0,27 s | 0,27 s |
///
/// Tout est sous la demi-seconde **sauf le premier appel d'une session**, que le
/// cache froid du serveur fait payer jusqu'à sept secondes. Le serveur n'a que
/// 224 Mio de cache pour une base de 742 Mo : aucune réécriture de requête ne
/// raccourcit ce moment-là.
///
/// D'où trois états plutôt qu'un :
///
/// 1. **Rien**, pendant [avantSquelette]. Le cas courant se résout dedans, et
///    une grille grise qui paraît puis disparaît en un tiers de seconde agite
///    l'écran plus qu'un vide. C'est la raison pour laquelle un squelette
///    permanent aurait été une régression.
/// 2. **Le squelette**, ensuite : l'écran prend sa forme définitive et le
///    contenu vient s'y poser, au lieu d'un saut depuis un rond qui tourne.
/// 3. **Le squelette et un mot**, passé [avantMot]. À sept secondes, un
///    indicateur muet se lit comme une panne — et c'en est une, aux yeux de qui
///    regarde. Nommer la cause coûte une ligne et rend l'attente supportable.
///
/// Usage canonique :
///
/// ```dart
/// cells.settled(   // et non `when` — voir `settled_async.dart`
///   loading: () => const LoadingView(skeleton: BinderGridSkeleton()),
///   error: (e, _) => StateMessage(...),
///   data: (cells) => ...,
/// )
/// ```
///
/// Sans [skeleton], c'est l'indicateur circulaire qui tient la deuxième place —
/// utile là où l'écran n'a pas de forme prévisible à annoncer.
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// Avant ce délai, l'écran ne montre rien.
///
/// 800 ms couvre le chemin tiède mesuré (0,43 s au lancement, 0,15 s pour une
/// feuille) avec de la marge : dans la vie courante, aucun squelette n'apparaît
/// jamais.
const Duration avantSquelette = Duration(milliseconds: 800);

/// Passé ce délai, l'attente s'explique.
///
/// Trois secondes : au-delà, on ne se demande plus si c'est lent, on se demande
/// si c'est cassé.
const Duration avantMot = Duration(seconds: 3);

/// Ce qui s'affiche pendant une attente, selon sa durée.
class LoadingView extends StatefulWidget {
  const LoadingView({super.key, this.skeleton, this.message});

  /// La forme que l'écran prendra. À défaut, un indicateur circulaire.
  final Widget? skeleton;

  /// Ce qu'on dit quand l'attente dure. Le défaut nomme la cause réelle.
  final String? message;

  @override
  State<LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<LoadingView> {
  /// 0 : rien. 1 : le squelette. 2 : le squelette et le mot.
  int _etape = 0;
  Timer? _versSquelette;
  Timer? _versMot;

  @override
  void initState() {
    super.initState();
    _versSquelette = Timer(avantSquelette, () {
      if (mounted) setState(() => _etape = 1);
    });
    _versMot = Timer(avantMot, () {
      if (mounted) setState(() => _etape = 2);
    });
  }

  @override
  void dispose() {
    _versSquelette?.cancel();
    _versMot?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_etape == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final forme =
        widget.skeleton ??
        const Center(child: CircularProgressIndicator(strokeWidth: 2));

    if (_etape == 1) return forme;

    return Column(
      children: [
        Expanded(child: forme),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  // **Ce n'est pas une formule d'attente, c'est la cause.** Le
                  // premier appel d'une session froide coûte des secondes parce
                  // que le serveur relit ses pages au disque ; les suivants sont
                  // immédiats. Le dire évite de croire à une panne, et annonce
                  // que cela ne se reproduira pas.
                  widget.message ?? 'Le serveur se réveille…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Un bloc gris à la place d'un contenu qui arrive.
///
/// **Il ne scintille pas.** Le battement des squelettes à la mode attire l'œil
/// sur l'attente au lieu de l'en distraire, et il coûte une animation par bloc
/// sur une grille qui en compte neuf. Un aplat suffit à dire « il y aura
/// quelque chose ici ».
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height, this.radius = 8});

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// La forme d'une feuille de classeur : neuf cases, trois par trois.
///
/// Le rapport 63 × 88 est celui d'une carte : la grille annonce donc exactement
/// la place que les cartes prendront, et rien ne saute quand elles arrivent.
class BinderGridSkeleton extends StatelessWidget {
  const BinderGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 63 / 88,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: 9,
        itemBuilder: (_, _) => const SkeletonBox(radius: 6),
      ),
    );
  }
}

/// La forme de l'étagère : des tuiles d'extension empilées.
class ShelfSkeleton extends StatelessWidget {
  const ShelfSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, _) => const SkeletonBox(height: 58, radius: 12),
    );
  }
}

/// La forme de la liste de decks : une vignette, deux lignes, une jauge.
class DeckListSkeleton extends StatelessWidget {
  const DeckListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: 5,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, _) => const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 40, height: 56, radius: 6),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 13, radius: 4),
                SizedBox(height: 8),
                SkeletonBox(width: 140, height: 11, radius: 4),
                SizedBox(height: 12),
                SkeletonBox(height: 6, radius: 3),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
