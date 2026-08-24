/// Le classeur qui s'ouvre, feuillette, et laisse sortir la carte demandée (#21).
///
/// **Pourquoi un classeur plutôt qu'une carte qui apparaît.** Le classeur est la
/// métaphore centrale du produit : une bannière montre *une carte*, une page de
/// classeur montre **où elle vit**. `!card` répond déjà « page 3 case 4 » ; ici
/// on le montre au lieu de l'écrire. Les huit cases voisines racontent en prime
/// quelque chose qu'aucune légende ne dirait aussi vite — un trou juste à côté
/// de la carte demandée se lit sans explication.
///
/// **Le défilé part de la page 1, et ce n'est pas décoratif au sens péjoratif.**
/// Quand on va chercher une carte dans un classeur, on l'ouvre au début et on
/// feuillette : partir de la première page est le geste exact. Le numéro défile
/// avec les pages et s'arrête sur le bon, si bien que le défilé *dit* la
/// distance parcourue au lieu de seulement l'illustrer.
///
/// **Les pages qui défilent sont génériques, et c'est ce qui rend le geste bon
/// marché.** À vingt-quatre millisecondes la page, personne ne lit rien ;
/// charger quarante-cinq vraies pages coûterait quarante-cinq appels réseau pour
/// du flou. Seule la page qui se pose est réelle.
///
/// **C'est la page du classeur, et elle doit s'y ressembler.** Une première
/// version dessinait les neuf cases en aplats gris, au motif qu'à cette taille
/// neuf illustrations se disputeraient le regard. L'argument tombe devant
/// l'écran de collection, qui en affiche neuf depuis toujours et reste lisible :
/// **c'est la même page**, montrée ailleurs. Les cases portent donc les mêmes
/// cartes, avec le même vocabulaire — case pleine à l'illustration, case vide en
/// **fantôme à un quart d'opacité** avec son numéro par-dessus, « un manque
/// qu'on montre, pas une carte ».
///
/// **Les couleurs viennent du thème, pas d'ici.** `Theme.of(context)` rend le
/// nuancier de l'application — sombre, doré. Recopier des valeurs
/// hexadécimales aurait fait diverger le calque de l'écran qu'il représente au
/// premier changement de thème ; c'est exactement ce qui lui donnait un air de
/// panneau bleu-violet étranger au produit.
///
/// **Les illustrations passent par [CardImage], jamais par `Image.network`.**
/// C'est le point de passage unique où l'URL est composée : le contourner a déjà
/// coûté 20 964 cartes Pokémon dont aucune ne s'affichait, faute d'un suffixe
/// que la source exige.
///
/// **Les pages qui défilent montrent le dos des cartes.** C'est ce qu'on voit
/// d'une feuille qu'on tourne, et cela évite la question du contenu : neuf dos
/// génériques ne prétendent être aucune page en particulier. Le dos est
/// **dessiné**, non chargé : la face cachée d'une carte Magic est une œuvre de
/// l'éditeur, et le projet ne réhéberge rien (§IV.3).
///
/// **La reliure est ce qui fait lire « classeur ».** Une première version n'avait
/// qu'un panneau sombre et une grille : regardée à l'écran, elle ne ressemblait
/// à rien de particulier. Le dos, ses anneaux et une page d'une autre matière
/// que la couverture suffisent — et il a fallu la capture pour le voir, aucun
/// test ne mesurant « est-ce que ça a l'air d'un classeur ».
///
/// **Ce widget est pur.** Il ne porte ni minuteur ni contrôleur : on lui donne
/// le temps écoulé, il rend l'image correspondante. C'est ce qui permet à un
/// test de mesurer la trajectoire de la carte à un instant choisi, plutôt que
/// d'attendre — et donc de vérifier qu'elle sort bien de *sa* case.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../common/card_image.dart';
import '../../printings/presentation/foil_decoration.dart';
import '../domain/binder.dart';
import '../domain/spotlight_card.dart';

/// Le découpage temporel de l'apparition, en millisecondes.
///
/// **Le total est borné par la durée d'affichage du calque.** `overlayLinger`
/// vaut douze secondes ; une intro de plus de deux secondes et demie mangerait
/// le temps qu'on a pour *regarder* la carte, qui est l'objet de tout ceci. D'où
/// un défilé plafonné, quel que soit le nombre de pages à parcourir : au-delà
/// d'une cinquantaine, le flou est déjà du flou.
@immutable
class RevealTiming {
  const RevealTiming(this.page);

  /// Page à atteindre, à partir de 1.
  final int page;

  /// Ouverture du classeur.
  static const double open = 300;

  /// Coût d'une page feuilletée.
  static const double perPage = 24;

  /// Plafond du défilé — cinquante pages tiennent dedans, cinq cents aussi.
  static const double riffleMax = 1200;

  /// Le temps que la case mette à s'allumer, une fois la page posée.
  static const double settle = 250;

  /// La sortie de la carte hors de sa case.
  static const double eject = 550;

  double get riffle => math.min(riffleMax, math.max(0, page - 1) * perPage);

  double get total => open + riffle + settle + eject;

  /// Avancement de l'ouverture, de 0 à 1.
  double openAt(double t) => _unit(t / open);

  /// Avancement du défilé, de 0 à 1. Vaut 1 d'emblée quand il n'y a rien à
  /// feuilleter — la page 1 est déjà la bonne.
  double riffleAt(double t) => riffle <= 0 ? 1 : _unit((t - open) / riffle);

  /// Avancement de la sortie de la carte, de 0 à 1.
  double ejectAt(double t) => _unit((t - open - riffle - settle) / eject);

  /// Le numéro de page affiché à cet instant. Il monte avec le défilé et
  /// s'arrête sur le bon — c'est ce qui donne un sens au feuilletage.
  int pageAt(double t) {
    final parcouru = riffleAt(t) * math.max(0, page - 1);
    return math.min(page, 1 + parcouru.floor());
  }

  static double _unit(double v) => v.isNaN ? 1 : v.clamp(0.0, 1.0);
}

/// Les mesures de la planche, en pixels logiques.
///
/// **Une taille fixe, et non une mise en page élastique.** Une *browser source*
/// OBS est réglée à une résolution donnée puis redimensionnée à la main dans la
/// scène : une planche de taille connue s'y place une fois pour toutes, là où
/// une mise en page qui suit la fenêtre changerait d'allure au premier
/// redimensionnement.
@immutable
class RevealMetrics {
  const RevealMetrics._();

  static const double cellWidth = 88;
  static const double cellHeight = 123;
  static const double gap = 8;
  static const double pad = 24;

  /// Le dos du classeur, avec ses anneaux. C'est lui qui fait lire « classeur »
  /// plutôt que « panneau sombre à grille ».
  static const double spine = 28;

  /// La marge de la page autour de ses neuf cases.
  static const double pagePad = 14;

  static const double gutter = 60;
  static const double heroWidth = 250;
  static const double heroHeight = 349;
  static const double footer = 62;

  static const double gridWidth = 3 * cellWidth + 2 * gap;
  static const double gridHeight = 3 * cellHeight + 2 * gap;

  static const double pageWidth = gridWidth + 2 * pagePad;
  static const double pageHeight = gridHeight + 2 * pagePad;

  static const double gridLeft = pad + spine + pagePad;
  static const double gridTop = pad + pagePad;

  static const double width =
      pad + spine + pageWidth + gutter + heroWidth + pad;
  static const double height = pad + pageHeight + 14 + footer + pad;

  /// La page elle-même, sur laquelle les cases sont posées.
  static Rect get pageRect =>
      Rect.fromLTWH(pad + spine, pad, pageWidth, pageHeight);

  /// Le dos du classeur.
  static Rect get spineRect => Rect.fromLTWH(pad, pad, spine, pageHeight);

  /// La case d'un emplacement, de 1 à 9, en lecture occidentale.
  static Rect slotRect(int slot) {
    final index = (slot - 1).clamp(0, 8);
    final row = index ~/ 3;
    final col = index % 3;
    return Rect.fromLTWH(
      gridLeft + col * (cellWidth + gap),
      gridTop + row * (cellHeight + gap),
      cellWidth,
      cellHeight,
    );
  }

  /// Où la carte finit sa course.
  static Rect get heroRect => Rect.fromLTWH(
    pad + spine + pageWidth + gutter,
    pad + (pageHeight - heroHeight) / 2,
    heroWidth,
    heroHeight,
  );

  /// Où la carte se trouve à cet avancement de sortie.
  ///
  /// **Elle part de sa case et non du bord de la planche** : c'est toute la
  /// différence entre « une carte apparaît » et « cette carte-là sort d'ici ».
  static Rect cardRect(int slot, double eject) {
    final t = Curves.easeOutCubic.transform(eject.clamp(0.0, 1.0));
    return Rect.lerp(slotRect(slot), heroRect, t)!;
  }
}

class BinderReveal extends StatelessWidget {
  const BinderReveal({
    super.key,
    required this.card,
    required this.cells,
    required this.elapsed,
  });

  final SpotlightCard card;

  /// Les neuf cases de la page. Peut être vide — la lecture de la page est un
  /// second appel, et **son échec ne doit pas empêcher la carte de sortir** :
  /// la grille se dessine alors sans savoir quelles voisines sont possédées.
  final List<BinderCell> cells;

  /// Millisecondes écoulées depuis l'arrivée de la demande.
  final double elapsed;

  RevealTiming get timing => RevealTiming(card.page);

  @override
  Widget build(BuildContext context) {
    final t = timing;
    final couleurs = Theme.of(context).colorScheme;
    final ouverture = Curves.easeOutCubic.transform(t.openAt(elapsed));
    final eject = t.ejectAt(elapsed);
    final avance = t.riffleAt(elapsed);
    final posee = avance >= 1;

    return Opacity(
      opacity: ouverture,
      child: Transform(
        alignment: Alignment.centerLeft,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          // Le classeur bascule vers le lecteur en s'ouvrant, comme une
          // couverture qu'on relève.
          ..rotateY(-(1 - ouverture) * 1.15),
        child: SizedBox(
          width: RevealMetrics.width,
          height: RevealMetrics.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              // La couverture, prise au nuancier de l'application : c'est la
              // teinte des fonds de l'écran de collection, assombrie de ce
              // qu'il faut pour rester lisible par-dessus une vidéo.
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
            // **La pile est rognée à la couverture.** Une feuille qui a
            // dépassé le quart de tour part de l'autre côté du dos : sans
            // rognage elle flottait hors du classeur, sur la vidéo.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                children: [
                  _spine(couleurs),
                  _page(couleurs),
                  // **La page de destination est dessous depuis le début.** Ne
                  // la peupler qu'à la fin faisait apparaître ses neuf cartes
                  // d'un coup ; les feuilles qui passent la découvrent par
                  // morceaux, comme un vrai feuilletage.
                  ..._slots(couleurs, eject),
                  if (t.riffle > 0 && avance < 1) ..._sheets(couleurs, avance),
                  if (posee) _highlight(couleurs),
                  if (posee) _card(couleurs, eject),
                  _footer(couleurs, t.pageAt(elapsed)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Le dos et ses anneaux — le signal « classeur ».
  Widget _spine(ColorScheme couleurs) => Positioned.fromRect(
    rect: RevealMetrics.spineRect,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: couleurs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: couleurs.surfaceContainerLowest,
                border: Border.all(color: couleurs.outline, width: 1.4),
              ),
            ),
        ],
      ),
    ),
  );

  /// La feuille, opaque comme celle de l'écran de collection : sans fond plein,
  /// on verrait par transparence la page du dessous pendant le retournement.
  Widget _page(ColorScheme couleurs) => Positioned.fromRect(
    rect: RevealMetrics.pageRect,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: couleurs.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: couleurs.outlineVariant),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 12,
            offset: Offset(2, 3),
          ),
        ],
      ),
    ),
  );

  /// Les neuf cases de la page de destination.
  ///
  /// Dessinées **dès le départ**, sous les feuilles qui défilent : c'est ce que
  /// l'on entrevoit en feuilletant, et cela évite que la page se remplisse d'un
  /// coup quand la dernière feuille se pose.
  List<Widget> _slots(ColorScheme couleurs, double eject) => [
    for (var slot = 1; slot <= 9; slot++)
      Positioned.fromRect(
        rect: RevealMetrics.slotRect(slot),
        child: _Slot(
          cell: _cellFor(slot),
          couleurs: couleurs,
          // La case visée se vide **au moment où la carte en sort**, pas
          // avant : le trou doit apparaître avec le mouvement, sinon la carte
          // semble sortir d'une case déjà vide.
          sortie: slot == card.slot && eject > 0,
        ),
      ),
  ];

  BinderCell? _cellFor(int slot) {
    final index = slot - 1;
    if (index < 0 || index >= cells.length) return null;
    return cells[index];
  }

  /// Les pages qui défilent — trois feuilles en vol, déphasées, montrant le dos
  /// des cartes.
  List<Widget> _sheets(ColorScheme couleurs, double avance) {
    final tours = avance * math.max(0, card.page - 1);
    return [
      for (var k = 0; k < 3; k++) _sheet(couleurs, (tours + k * 0.34) % 1.0),
    ];
  }

  Widget _sheet(ColorScheme couleurs, double local) => Positioned.fromRect(
    rect: RevealMetrics.pageRect,
    child: Transform(
      // Autour du dos : c'est là que les pages d'un classeur sont reliées.
      alignment: Alignment.centerLeft,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0016)
        ..rotateY(-local * math.pi),
      child: Opacity(
        // **Opaque jusqu'au quart de tour, puis effacée.** Une feuille de papier
        // ne laisse pas voir la page d'en dessous — dégressive dès le départ,
        // elle donnait un voile translucide plutôt qu'une page qui tourne. Et
        // passé le quart de tour elle est de l'autre côté du dos, donc hors de
        // vue : la faire disparaître là est plus juste que la traîner jusqu'au
        // demi-tour.
        opacity: local < 0.42 ? 1 : math.max(0, (0.58 - local) / 0.16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: couleurs.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: couleurs.outlineVariant),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 14,
                offset: Offset(6, 0),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(RevealMetrics.pagePad),
            child: GridView.count(
              crossAxisCount: 3,
              childAspectRatio:
                  RevealMetrics.cellWidth / RevealMetrics.cellHeight,
              mainAxisSpacing: RevealMetrics.gap,
              crossAxisSpacing: RevealMetrics.gap,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < 9; i++)
                  _CardBack(key: ValueKey('dos-$i'), couleurs: couleurs),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// La case d'où la carte est sortie : un trou, cerclé de lumière.
  ///
  /// **Le fond est explicite, et il doit l'être.** Une première version laissait
  /// la décoration sans couleur : une `BoxShadow` peint un rectangle plein
  /// *derrière* la boîte, si bien que le halo traversait le vide et remplissait
  /// la case — on lisait « carte présente » là où l'on voulait montrer le trou
  /// qu'elle laisse. Vu sur l'image rendue, pas dans le code.
  Widget _highlight(ColorScheme couleurs) => Positioned.fromRect(
    rect: RevealMetrics.slotRect(card.slot),
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: couleurs.primary, width: 2),
          boxShadow: [
            BoxShadow(
              color: couleurs.primary.withValues(alpha: 0.35),
              blurRadius: 22,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _card(ColorScheme couleurs, double eject) {
    final rect = RevealMetrics.cardRect(card.slot, eject);
    return Positioned.fromRect(
      rect: rect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: couleurs.surfaceContainerHigh,
          boxShadow: [
            BoxShadow(
              color: Color.fromRGBO(0, 0, 0, 0.6 * eject),
              blurRadius: 30 * eject,
              offset: Offset(0, 12 * eject),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CardImage(
            url: card.imageUrl,
            uprightInCell: true,
            placeholder: _fallback(couleurs),
            errorBuilder: (_) => _fallback(couleurs),
          ),
        ),
      ),
    );
  }

  /// Ce qui s'affiche quand l'illustration ne charge pas.
  ///
  /// **Pas le nom de la carte** : la légende le porte déjà, et un test l'a
  /// montré en trouvant deux fois « Ka-Zar » à l'écran. Le numéro de case suffit
  /// à dire de quoi il s'agit sans se répéter.
  Widget _fallback(ColorScheme couleurs) => Center(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        card.collectorNumber == null ? '—' : '#${card.collectorNumber}',
        textAlign: TextAlign.center,
        style: TextStyle(color: couleurs.onSurfaceVariant, fontSize: 15),
      ),
    ),
  );

  Widget _footer(ColorScheme couleurs, int pageAffichee) {
    final ou = [
      if (card.setName != null && card.setName!.isNotEmpty)
        card.setName!
      else if (card.setCode != null)
        card.setCode!.toUpperCase(),
      'page $pageAffichee',
      'case ${card.slot}',
    ].join(' — ');
    final marques = [
      if (card.collectorNumber != null) '#${card.collectorNumber}',
      if (card.copies > 1) '×${card.copies}',
      if (card.priceEur != null)
        '${card.priceEur!.toStringAsFixed(2).replaceAll('.', ',')} €',
    ].join('  ·  ');

    return Positioned(
      left: RevealMetrics.pad,
      right: RevealMetrics.pad,
      bottom: RevealMetrics.pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            card.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: couleurs.onSurface,
              fontSize: 19,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            marques.isEmpty ? ou : '$ou  ·  $marques',
            style: TextStyle(color: couleurs.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: couleurs.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  card.requestedBy == null
                      ? 'demandée dans le chat'
                      : 'demandée par ${card.requestedBy}',
                  style: TextStyle(
                    color: couleurs.onPrimaryContainer,
                    fontSize: 11,
                  ),
                ),
              ),
              const Spacer(),
              // Garde-fou §IV.2 : le crédit est visible de qui regarde, même
              // ici. Un calque est vu par plus d'inconnus qu'un écran « à
              // propos ».
              Text(
                'Données : Scryfall',
                style: TextStyle(
                  color: couleurs.onSurfaceVariant.withValues(alpha: 0.7),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Le dos d'une carte, pendant qu'une page tourne.
///
/// **Dessiné, jamais chargé.** La face cachée d'une carte Magic est une œuvre de
/// l'éditeur ; le projet ne réhéberge aucune illustration (§IV.3), et à
/// vingt-quatre millisecondes la page, un dos générique fait le même effet.
class _CardBack extends StatelessWidget {
  const _CardBack({super.key, required this.couleurs});

  final ColorScheme couleurs;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          couleurs.surfaceContainerHighest,
          couleurs.surfaceContainerHigh,
        ],
      ),
      border: Border.all(color: couleurs.outlineVariant),
    ),
    child: Center(
      child: Transform.rotate(
        angle: math.pi / 4,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: couleurs.outline.withValues(alpha: 0.6),
              width: 1.5,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Une case de la page — le même vocabulaire que l'écran de collection.
///
/// **Pleine : l'illustration. Vide : la même, en fantôme, avec son numéro.**
/// L'écran de classeur montre l'illustration manquante à un quart d'opacité,
/// « un manque qu'on montre, pas une carte » : le numéro seul nommait la case et
/// non la carte, et il fallait chercher ailleurs pour savoir quoi acheter.
class _Slot extends StatelessWidget {
  const _Slot({
    required this.cell,
    required this.couleurs,
    required this.sortie,
  });

  final BinderCell? cell;
  final ColorScheme couleurs;

  /// Vrai pour la case dont la carte est en train de sortir.
  final bool sortie;

  /// Ce qu'il reste d'une carte qu'on ne possède pas. Assez pour la
  /// reconnaître, assez peu pour qu'aucune case vide ne se confonde avec une
  /// case pleine.
  static const double _ghostOpacity = 0.24;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(8);
    final courante = cell;
    final image = courante?.imageUrl;
    final pleine = !sortie && (courante?.owned ?? 0) > 0;

    if (pleine && image != null) {
      return ClipRRect(
        borderRadius: radius,
        child: FoilSheen(
          foil: courante!.hasFoil,
          borderRadius: radius,
          child: CardImage(url: image, uprightInCell: true),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        color: couleurs.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border.all(color: couleurs.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image != null)
              Opacity(
                opacity: _ghostOpacity,
                child: CardImage(url: image, uprightInCell: true),
              ),
            if (courante != null)
              Center(
                child: Text(
                  '#${courante.collectorNumber}',
                  style: TextStyle(
                    color: couleurs.onSurfaceVariant,
                    fontSize: 12,
                    // Sur une illustration, même fantôme, le numéro perdrait
                    // ses contours clairs.
                    shadows: image == null
                        ? null
                        : [Shadow(blurRadius: 4, color: couleurs.surface)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
