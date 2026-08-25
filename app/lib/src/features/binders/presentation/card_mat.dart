/// Le tapis de présentation : toutes les versions possédées d'une carte (#21).
///
/// **Ce que `!card` ne pouvait pas dire.** La commande répond « 3 cases
/// (+5 autres) » ; les cinq autres, personne ne saura jamais à quoi elles
/// ressemblent — et c'est précisément la question qu'on se pose devant une
/// carte qu'on possède en plusieurs dessins. Le tapis les pose côte à côte.
///
/// **Ce n'est pas un classeur, et il ne doit pas le singer.** Ni reliure, ni
/// page, ni numéro de case : une planche de six Trésors venus de six extensions
/// n'existe nulle part dans le classeur, et lui donner un feuilletage raconterait
/// « je suis allé page 12 » là où il n'y a pas de page où aller. D'où un widget
/// séparé, et un type qui l'impose — `BinderReveal` ne prend qu'un
/// [BinderRequest], le compilateur refuse de lui passer un tapis.
///
/// **Il prend moins de place, et c'est le point.** Un bandeau en bas d'écran
/// plutôt qu'une planche : le commentaire garde son espace, et l'animation reste
/// une animation.
///
/// **La taille des cartes suit leur nombre, et le plafond est mesuré.** Sur les
/// 646 points utiles de la planche : jusqu'à six cartes tiennent à la taille
/// d'une case de classeur (88 × 123), huit à 74 × 103, dix à 57 × 80 — et douze
/// à 47 × 65, où l'on ne reconnaît plus rien. D'où [maxCards] = 10 : le dernier
/// compte où une carte reste une carte.
///
/// **Une seule carte est centrée**, à sa pleine taille : c'est le cas d'une
/// portée qui a retiré les autres versions, et il ne doit pas donner
/// l'impression d'un tapis raté.
///
/// **Ce widget est pur**, comme `BinderReveal` : on lui donne le temps écoulé,
/// il rend l'image correspondante. C'est ce qui permet à un test de l'interroger
/// à un instant choisi plutôt que d'attendre.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../common/card_image.dart';
import '../domain/spotlight_request.dart';
import 'binder_reveal.dart' show RevealMetrics;

/// Le découpage temporel de l'arrivée, en millisecondes.
///
/// **Les cartes se posent l'une après l'autre.** Toutes ensemble, le tapis
/// apparaîtrait — ce serait un changement d'image, pas un geste. Décalées, on
/// les compte du regard, ce qui est exactement ce qu'on veut faire d'elles.
@immutable
class MatTiming {
  const MatTiming(this.count);

  /// Nombre de cartes réellement posées.
  final int count;

  /// Le temps qu'une carte met à se poser.
  static const double arrival = 320;

  /// Le décalage d'une carte à la suivante.
  ///
  /// **Court devant [arrival]** : les cartes se chevauchent en arrivant, si
  /// bien que dix d'entre elles tiennent en une seconde et demie au lieu de
  /// trois secondes et quart. Bornées par `overlayLinger`, comme le classeur.
  static const double stagger = 130;

  double get total => arrival + stagger * math.max(0, count - 1);

  /// Avancement de la carte d'indice [i], de 0 à 1.
  double at(int i, double elapsed) {
    final t = (elapsed - i * stagger) / arrival;
    if (t.isNaN) return 1;
    return t.clamp(0.0, 1.0);
  }
}

/// Les mesures du tapis, en pixels logiques.
@immutable
class MatMetrics {
  const MatMetrics._();

  /// La largeur maximale : celle de la planche du classeur, jamais plus.
  static const double maxWidth = RevealMetrics.width;

  /// La largeur minimale, celle qu'il faut à la légende.
  ///
  /// **Sans elle, un tapis d'une seule carte ferait 136 points de large** et sa
  /// légende — le nom, le compte, le demandeur, le crédit — serait illisible.
  /// Le tapis suit son contenu vers le haut, pas vers le bas.
  static const double minWidth = 380;

  static const double pad = 24;
  static const double gap = 8;

  /// La légende sous les cartes.
  static const double caption = 54;

  /// Le plus grand nombre de cartes qu'on pose. Voir l'en-tête : c'est le
  /// dernier compte où une carte reste reconnaissable.
  static const int maxCards = 10;

  /// Ce que la largeur laisse à chaque carte, pour [count] cartes.
  ///
  /// **Plafonnée à la taille d'une case de classeur.** Au-delà, une carte seule
  /// occuperait la moitié de l'écran — et le tapis cesserait d'être discret,
  /// ce qui est sa seule raison d'exister.
  static Size cardSize(int count) {
    final n = count.clamp(1, maxCards);
    final dispo = maxWidth - 2 * pad - gap * (n - 1);
    final largeur = math.min(RevealMetrics.cellWidth, dispo / n);
    return Size(
      largeur,
      largeur * RevealMetrics.cellHeight / RevealMetrics.cellWidth,
    );
  }

  /// La hauteur totale du tapis, pour [count] cartes.
  static double height(int count) => cardSize(count).height + 2 * pad + caption;

  /// La largeur du tapis, pour [count] cartes.
  ///
  /// **Il suit son contenu.** Un tapis de pleine largeur pour quatre cartes est
  /// un grand panneau sombre avec quelque chose au milieu ; sa seule raison
  /// d'exister est de tenir peu de place. Borné en bas par la légende, en haut
  /// par la planche.
  static double width(int count) {
    final n = count.clamp(1, maxCards);
    final contenu = 2 * pad + cardSize(n).width * n + gap * (n - 1);
    return contenu.clamp(minWidth, maxWidth);
  }
}

/// Le tapis et ses cartes.
class CardMat extends StatelessWidget {
  const CardMat({super.key, required this.strip, required this.elapsed});

  final SpotlightStrip strip;

  /// Millisecondes écoulées depuis l'arrivée de la demande.
  final double elapsed;

  /// Les versions réellement posées — au plus [MatMetrics.maxCards].
  List<SpotlightCard> get shown =>
      strip.entries.take(MatMetrics.maxCards).toList();

  MatTiming get timing => MatTiming(shown.length);

  @override
  Widget build(BuildContext context) {
    final couleurs = Theme.of(context).colorScheme;
    final cartes = shown;
    if (cartes.isEmpty) return const SizedBox.shrink();

    final taille = MatMetrics.cardSize(cartes.length);
    final t = timing;

    return SizedBox(
      width: MatMetrics.width(cartes.length),
      height: MatMetrics.height(cartes.length),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: couleurs.surfaceContainerLowest.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: couleurs.outlineVariant),
          boxShadow: const [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(MatMetrics.pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: taille.height,
                // **Centrées, quel qu'en soit le nombre.** Une seule version —
                // le cas d'une portée qui a retiré les autres — se pose au
                // milieu, et non collée au bord gauche comme un tapis raté.
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < cartes.length; i++) ...[
                      if (i > 0) const SizedBox(width: MatMetrics.gap),
                      _Posee(
                        carte: cartes[i],
                        taille: taille,
                        avance: t.at(i, elapsed),
                        couleurs: couleurs,
                      ),
                    ],
                  ],
                ),
              ),
              const Spacer(),
              _legende(couleurs),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legende(ColorScheme couleurs) {
    final total = strip.entries.length;
    final posees = shown.length;
    // **Dire qu'on tronque, plutôt que de tronquer en silence.** Un tapis de
    // dix cartes sur quatorze qui n'annoncerait rien se lirait « j'en ai dix ».
    // Une carte reste possible : la portée peut avoir retiré les autres
    // versions après que la base a accepté le tapis.
    final mot = total > 1 ? 'versions' : 'version';
    final compte = posees == total ? '$total $mot' : '$posees des $total $mot';

    return Row(
      children: [
        Flexible(
          // **`Text.rich` et non `RichText`.** Le second n'hérite pas du
          // `DefaultTextStyle` : sans famille de police explicite, le nom se
          // rendait dans la police du moteur — des rectangles sur la capture,
          // et une autre typographie que le reste du calque en direct.
          child: Text.rich(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            TextSpan(
              children: [
                TextSpan(
                  text: strip.displayName,
                  style: TextStyle(
                    color: couleurs.onSurface,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(
                  text: '   $compte',
                  style: TextStyle(
                    color: couleurs.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        // **Le pseudonyme cède, le crédit jamais.** La base en autorise
        // quarante caractères, et le tapis peut être à sa largeur minimale :
        // sans souplesse, la ligne débordait — mesuré à 26 px. Le crédit, lui,
        // est un garde-fou (§IV.2) et ne peut pas être ce qui disparaît.
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: couleurs.primaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              strip.requestedBy == null
                  ? 'demandée dans le chat'
                  : 'demandée par ${strip.requestedBy}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: couleurs.onPrimaryContainer,
                fontSize: 11,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Garde-fou §IV.2 : le crédit est visible de qui regarde. Un calque est
        // vu par plus d'inconnus qu'un écran « à propos ».
        Text(
          'Scryfall',
          style: TextStyle(
            color: couleurs.onSurfaceVariant.withValues(alpha: 0.7),
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

/// Une carte qui se pose sur le tapis.
///
/// **Elle monte et se révèle**, elle n'apparaît pas : une carte posée sur un
/// tapis vient de quelque part. Le déplacement est court — un tiers de sa
/// hauteur — parce qu'un grand geste sur dix cartes décalées donnerait une
/// vague plutôt qu'un dépôt.
class _Posee extends StatelessWidget {
  const _Posee({
    required this.carte,
    required this.taille,
    required this.avance,
    required this.couleurs,
  });

  final SpotlightCard carte;
  final Size taille;
  final double avance;
  final ColorScheme couleurs;

  @override
  Widget build(BuildContext context) {
    final t = Curves.easeOutCubic.transform(avance.clamp(0.0, 1.0));
    return Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, (1 - t) * taille.height / 3),
        child: SizedBox(
          width: taille.width,
          height: taille.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: couleurs.surfaceContainerHigh,
              boxShadow: [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, 0.45 * t),
                  blurRadius: 12 * t,
                  offset: Offset(0, 4 * t),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CardImage(
                url: carte.imageUrl,
                uprightInCell: true,
                placeholder: _repli(),
                errorBuilder: (_) => _repli(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// **Le numéro, pas le nom.** La légende porte déjà le nom, et les versions
  /// le partagent toutes : ce qui les distingue, c'est la case.
  Widget _repli() => Center(
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Text(
        carte.collectorNumber == null ? '—' : '#${carte.collectorNumber}',
        textAlign: TextAlign.center,
        style: TextStyle(color: couleurs.onSurfaceVariant, fontSize: 11),
      ),
    ),
  );
}
