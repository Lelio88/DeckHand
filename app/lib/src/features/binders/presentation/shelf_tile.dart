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
/// **Le symbole officiel tient lieu de bundle.** Aucune source exploitable ne
/// publie les visuels des produits — boîtes, displays, illustrations
/// promotionnelles appartiennent aux marchands ou à Wizards, sans API. Le
/// symbole imprimé sur chaque carte est ce qui s'en approche le plus, et c'est
/// le marqueur qu'un joueur reconnaît avant d'avoir lu le nom. Il est
/// monochrome par nature : on le teinte en blanc, comme le reste de
/// l'habillage.
///
/// **La tuile ne sait pas ouvrir un classeur** et n'a donc besoin d'aucun
/// provider : elle reçoit [onOpen]. Le câblage vit dans `binder_view.dart`,
/// avec le reste de la navigation.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
                if (entry.iconSvgUri != null)
                  Positioned(
                    top: 9,
                    right: 11,
                    child: _SetIcon(url: entry.iconSvgUri!),
                  ),
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

/// Le symbole officiel de l'extension, en médaillon.
///
/// **Un jeton dans un jeton.** Le symbole est une silhouette pleine, souvent
/// dense : posé nu sur une illustration il deviendrait illisible dès que
/// celle-ci est claire. Le disque sombre lui donne le fond constant qu'un
/// symbole imprimé a sur le carton d'une carte.
///
/// Le SVG n'est pas mis en cache par le disque ici — `flutter_svg` garde le
/// rendu en mémoire pour la session, et une silhouette d'un kilo-octet ne
/// justifie pas davantage.
class _SetIcon extends StatelessWidget {
  const _SetIcon({required this.url});

  final String url;

  /// Diamètre du disque. Assez grand pour qu'un symbole chargé se lise, assez
  /// petit pour ne pas concurrencer l'illustration.
  static const double _size = 38;

  @override
  Widget build(BuildContext context) => Container(
    width: _size,
    height: _size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.black.withValues(alpha: 0.46),
      border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
    ),
    padding: const EdgeInsets.all(7),
    child: SvgPicture(
      _SafeSvgLoader(url),
      // Le SVG de Scryfall ne porte pas de couleur : ses tracés prennent celle
      // du contexte. On la fixe donc explicitement plutôt que de dépendre du
      // noir par défaut, invisible sur ce fond.
      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
      // Rien pendant le chargement : un disque vide vaut mieux qu'un indicateur
      // qui clignote sur chaque tuile de la liste.
      placeholderBuilder: (_) => const SizedBox.shrink(),
    ),
  );
}

/// Un chargeur de SVG distant qui ne peut pas faire tomber la tuile.
///
/// **Ce que le réseau renvoie n'est pas toujours un SVG.** `SvgNetworkLoader`
/// ne regarde ni le code HTTP ni le type de contenu, et son `provideSvg` fait
/// un `message!` : une URL morte — Scryfall répond alors 27 Ko de page HTML —
/// ou un portail captif suffisent à faire lever « Invalid SVG data » au
/// décodeur. L'exception naît dans un `compute`, hors de l'arbre, là où
/// l'`errorBuilder` du widget ne la voit jamais : elle remonte donc jusqu'à la
/// zone et emporte l'écran pour un ornement.
///
/// Le remède est pris à la source : l'échec réseau et le contenu qui n'est pas
/// du SVG rendent tous deux un SVG **valide et vide**, que le décodeur accepte
/// et qui ne dessine rien.
class _SafeSvgLoader extends SvgNetworkLoader {
  const _SafeSvgLoader(super.url);

  /// Un SVG valide qui ne dessine rien.
  static const String _nothing =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>';

  @override
  Future<Uint8List?> prepareMessage(BuildContext? context) async {
    try {
      return await super.prepareMessage(context);
    } on Exception {
      // Réseau coupé, hôte injoignable, TLS refusé : il n'y a rien à montrer,
      // et rien à dire non plus — le symbole est décoratif.
      return null;
    }
  }

  @override
  String provideSvg(Uint8List? message) {
    if (message == null || message.isEmpty) return _nothing;
    final text = utf8.decode(message, allowMalformed: true);
    return text.contains('<svg') ? text : _nothing;
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
