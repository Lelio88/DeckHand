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
/// **Les huit voisines sont des aplats, pas des images.** À la taille d'un
/// calque, neuf illustrations font neuf bouillies qui se disputent le regard —
/// et neuf téléchargements par désignation. Une seule vraie image : celle qui
/// sort.
///
/// **Une case vide porte son numéro, une case pleine non.** C'est ce qui rend
/// les voisines utiles plutôt que décoratives : « il te manque le #424 » se lit
/// d'un coup d'œil, alors qu'un carré sombre ne dit rien. Le numéro d'une case
/// pleine, lui, n'apprendrait rien — la carte est là.
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
              // La couverture : sombre, mate, un peu plus chaude que le noir.
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xF21A1720), Color(0xF20E0D13)],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x2EFFFFFF)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x88000000),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _spine(),
                _page(),
                ..._slots(posee),
                if (t.riffle > 0 && avance < 1) ..._sheets(avance),
                if (posee) _highlight(),
                if (posee) _card(eject),
                _footer(t.pageAt(elapsed)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Le dos et ses anneaux — le signal « classeur ».
  Widget _spine() => Positioned.fromRect(
    rect: RevealMetrics.spineRect,
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF241F2C), Color(0xFF151220)],
        ),
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
                color: const Color(0xFF0A0910),
                border: Border.all(color: const Color(0x66C9CCE0), width: 1.4),
              ),
            ),
        ],
      ),
    ),
  );

  /// La page, d'une autre matière que la couverture.
  Widget _page() => Positioned.fromRect(
    rect: RevealMetrics.pageRect,
    child: DecoratedBox(
      decoration: BoxDecoration(
        // Plus claire que la couverture : sans cet écart, la planche entière se
        // lisait comme un seul panneau sombre.
        color: const Color(0xFF37313F),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x33FFFFFF)),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(2, 3)),
        ],
      ),
    ),
  );

  List<Widget> _slots(bool posee) => [
    for (var slot = 1; slot <= 9; slot++)
      Positioned.fromRect(
        rect: RevealMetrics.slotRect(slot),
        child: _Slot(
          // Rien n'est rempli tant que la page n'est pas posée : le contenu
          // d'une page qui défile n'existe pas.
          cell: posee ? _cellFor(slot) : null,
          owned: posee && _owned(slot),
          // La case visée reste creuse une fois la carte sortie : c'est le
          // trou qu'elle laisse, et il rend la trajectoire lisible.
          target: slot == card.slot,
        ),
      ),
  ];

  BinderCell? _cellFor(int slot) {
    final index = slot - 1;
    if (index < 0 || index >= cells.length) return null;
    return cells[index];
  }

  bool _owned(int slot) {
    // La carte demandée est possédée par construction : la base refuse de
    // désigner une case vide.
    if (slot == card.slot) return true;
    return (_cellFor(slot)?.owned ?? 0) > 0;
  }

  /// Les pages qui défilent — trois feuilles en vol, déphasées.
  List<Widget> _sheets(double avance) {
    final tours = avance * math.max(0, card.page - 1);
    return [for (var k = 0; k < 3; k++) _sheet((tours + k * 0.34) % 1.0)];
  }

  Widget _sheet(double local) => Positioned.fromRect(
    rect: RevealMetrics.pageRect,
    child: Transform(
      // Autour du dos : c'est là que les pages d'un classeur sont reliées.
      alignment: Alignment.centerLeft,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0016)
        ..rotateY(-local * math.pi),
      child: Opacity(
        // **Opaque presque jusqu'au bout.** Une feuille de papier ne laisse pas
        // voir la page d'en dessous ; la première version, dégressive dès le
        // départ, donnait un voile translucide plutôt qu'une page qui tourne.
        // Elle ne s'efface qu'en fin de course, pour ne pas disparaître d'un
        // coup et faire clignoter le défilé.
        opacity: local < 0.78 ? 1 : (1 - local) / 0.22,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF3E3747),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0x33FFFFFF)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 14,
                offset: Offset(6, 0),
              ),
            ],
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
  Widget _highlight() => Positioned.fromRect(
    rect: RevealMetrics.slotRect(card.slot),
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF15111E),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0xFF8FA0FF), width: 2),
          boxShadow: const [
            BoxShadow(color: Color(0x558FA0FF), blurRadius: 22, spreadRadius: 1),
          ],
        ),
      ),
    ),
  );

  Widget _card(double eject) {
    final rect = RevealMetrics.cardRect(card.slot, eject);
    final image = card.imageUrl;
    return Positioned.fromRect(
      rect: rect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: const Color(0xFF15151C),
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
          child: image == null
              ? _fallback()
              : Image.network(
                  image,
                  fit: BoxFit.cover,
                  // Une illustration qui ne charge pas ne doit pas trouer le
                  // calque : le numéro tient la place.
                  errorBuilder: (_, _, _) => _fallback(),
                ),
        ),
      ),
    );
  }

  /// Ce qui s'affiche quand l'illustration ne charge pas.
  ///
  /// **Pas le nom de la carte** : la légende le porte déjà, et un test l'a
  /// montré en trouvant deux fois « Ka-Zar » à l'écran. Le numéro de case suffit
  /// à dire de quoi il s'agit sans se répéter — et il désigne précisément la
  /// case d'où la carte vient de sortir.
  Widget _fallback() => Center(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        card.collectorNumber == null ? '—' : '#${card.collectorNumber}',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 15),
      ),
    ),
  );

  Widget _footer(int pageAffichee) {
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
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            marques.isEmpty ? ou : '$ou  ·  $marques',
            style: const TextStyle(color: Color(0xFFB9BCC6), fontSize: 12),
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
                  color: const Color(0xFF2F3E7A),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  card.requestedBy == null
                      ? 'demandée dans le chat'
                      : 'demandée par ${card.requestedBy}',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
              const Spacer(),
              // Garde-fou §IV.2 : le crédit est visible de qui regarde, même
              // ici. Un calque est vu par plus d'inconnus qu'un écran « à
              // propos ».
              const Text(
                'Données : Scryfall',
                style: TextStyle(color: Color(0x99FFFFFF), fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Une case de la page.
///
/// **Pleine et vide doivent se distinguer de loin.** Une première version les
/// dessinait dans deux gris voisins : sur la capture, une case possédée à côté
/// de la carte demandée était indiscernable d'un trou — c'est-à-dire que les
/// voisines ne servaient à rien. Le pochoir est donc franc, et une case vide
/// porte son numéro.
class _Slot extends StatelessWidget {
  const _Slot({required this.cell, required this.owned, required this.target});

  final BinderCell? cell;
  final bool owned;
  final bool target;

  @override
  Widget build(BuildContext context) {
    // La case visée se dessine comme un trou : la carte en est sortie.
    final creuse = !owned || target;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: creuse ? const Color(0xFF1A1622) : const Color(0xFF5B5470),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: creuse ? const Color(0x2BFFFFFF) : const Color(0x59FFFFFF),
        ),
        boxShadow: creuse
            ? null
            : const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
      ),
      child: creuse && !target && cell != null
          ? Center(
              child: Text(
                '#${cell!.collectorNumber}',
                style: const TextStyle(color: Color(0x77FFFFFF), fontSize: 12),
              ),
            )
          : null,
    );
  }
}
