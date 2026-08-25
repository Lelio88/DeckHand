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
/// marché.** Une feuille traverse en cent quatre-vingts millisecondes : le
/// mouvement se lit, son contenu non. Charger quarante-cinq vraies pages
/// coûterait quarante-cinq appels réseau pour du flou. Seule la page qui se
/// pose est réelle.
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
/// **Les pages qui défilent montrent le dos des cartes**, et leur verso les
/// pochettes vides — le vocabulaire du classeur de l'application, repris tel
/// quel. Cela évite la question du contenu : neuf dos génériques ne prétendent
/// être aucune page en particulier. Le dos est **dessiné**, non chargé : la
/// face cachée d'une carte Magic est une œuvre de l'éditeur, et le projet ne
/// réhéberge rien (§IV.3).
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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../common/card_image.dart';
import '../../printings/presentation/foil_decoration.dart';
import '../domain/binder.dart';
import '../domain/spotlight_request.dart';
import 'page_turn.dart';
import 'sheet_face.dart';

/// Le découpage temporel de l'apparition, en millisecondes.
///
/// **Le total est borné par la durée d'affichage du calque.** `overlayLinger`
/// vaut douze secondes ; une intro de plus de deux secondes et demie mangerait
/// le temps qu'on a pour *regarder* la carte, qui est l'objet de tout ceci. D'où
/// un défilé plafonné, quel que soit le nombre de pages à parcourir : au-delà
/// d'une cinquantaine, le flou est déjà du flou.
@immutable
class RevealTiming {
  const RevealTiming(this.page) : ejects = true;

  /// Le tempo d'une **page** demandée : tout est identique, sauf qu'il n'en
  /// sort rien.
  ///
  /// **Et la sortie n'est pas seulement sautée, elle est retirée du total.**
  /// La laisser courir à vide ferait attendre le spectateur cinq cent
  /// cinquante millisecondes devant une page qui ne bouge plus, avant que le
  /// délai d'effacement ne commence.
  const RevealTiming.pageOnly(this.page) : ejects = false;

  /// Le tempo d'une demande, quel qu'en soit le genre.
  ///
  /// **Un seul endroit qui décide.** Le calque a besoin de la durée pour régler
  /// son horloge, `BinderReveal` en a besoin pour dessiner : les laisser la
  /// déduire chacun de son côté, c'est une animation qui s'arrête avant ou
  /// après la fin de son mouvement.
  factory RevealTiming.of(BinderRequest request) => switch (request) {
    SpotlightCard() => RevealTiming(request.page),
    SpotlightPage() => RevealTiming.pageOnly(request.page),
  };

  /// Page à atteindre, à partir de 1.
  final int page;

  /// Vrai si une carte doit sortir de sa case.
  final bool ejects;

  /// Ouverture du classeur.
  static const double open = 300;

  /// Coût d'une page feuilletée.
  static const double perPage = 24;

  /// Le temps qu'une feuille met à traverser, en millisecondes.
  ///
  /// **Découplé du compte des pages, et c'est ce qui rend le feuilletage
  /// visible.** Les feuilles tournaient à raison d'une par page comptée : à
  /// [perPage] millisecondes, un tour de page couvrait **une image et demie** à
  /// soixante hertz. Aucune géométrie ne survit à cela — courbure, profondeur,
  /// ombre portée, tout se réduisait à un scintillement, et c'est très
  /// exactement ce qu'on voyait.
  ///
  /// Cent quatre-vingts millisecondes font une dizaine d'images : le minimum
  /// pour qu'un mouvement se lise comme un mouvement plutôt que comme une
  /// coupe. C'est aussi environ un tiers du tour de page délibéré de
  /// l'application (520 ms sous le doigt) — un feuilletage est plus vif qu'une
  /// page qu'on tourne, pas cinquante fois plus vif.
  ///
  /// **Ce que le découplage ne coûte pas** : les feuilles en vol sont
  /// génériques, elles n'ont jamais prétendu être telle ou telle page. Ce qui
  /// *dit* la distance parcourue, c'est le numéro — il monte bien de 1 à la
  /// page visée, et [pageAt] n'a pas changé. Ce qui reste vrai aussi : une page
  /// lointaine fait défiler plus de feuilles qu'une page proche, puisque le
  /// défilé dure plus longtemps.
  static const double sheetTurn = 180;

  /// Plafond du défilé — cinquante pages tiennent dedans, cinq cents aussi.
  static const double riffleMax = 1200;

  /// Le temps que la case mette à s'allumer, une fois la page posée.
  static const double settle = 250;

  /// La sortie de la carte hors de sa case.
  static const double eject = 550;

  double get riffle => math.min(riffleMax, math.max(0, page - 1) * perPage);

  double get total => open + riffle + settle + (ejects ? eject : 0);

  /// Avancement de l'ouverture, de 0 à 1.
  double openAt(double t) => _unit(t / open);

  /// Avancement du défilé, de 0 à 1. Vaut 1 d'emblée quand il n'y a rien à
  /// feuilleter — la page 1 est déjà la bonne.
  double riffleAt(double t) => riffle <= 0 ? 1 : _unit((t - open) / riffle);

  /// Avancement de la sortie de la carte, de 0 à 1. Vaut toujours 0 quand rien
  /// ne sort : la case visée ne se vide pas, et le halo ne s'allume pas.
  double ejectAt(double t) =>
      ejects ? _unit((t - open - riffle - settle) / eject) : 0;

  /// Combien de feuilles ont fini de tourner à cet instant.
  ///
  /// **C'est ce que le son suit.** Un froissement par feuille, et le compte
  /// vit ici plutôt que chez celui qui joue le son : `BinderReveal` est un
  /// widget pur, le calque et l'aperçu le pilotent chacun de leur côté, et
  /// deux comptes séparés dériveraient. Rendu entier, donc testable sans rien
  /// faire sonner.
  int sheetTurnsAt(double t) =>
      sheetTurn <= 0 ? 0 : (riffleAt(t) * riffle / sheetTurn).floor();

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

  /// La couverture — le classeur lui-même, et ce que rogne le calque.
  static const double coverHeight = pad + pageHeight + 14 + footer + pad;

  /// De combien la carte se hisse hors de sa case, en points.
  ///
  /// **Une hauteur de carte entière**, parce que c'est le geste : on ne tire
  /// pas une carte d'un quart de pochette, on l'en sort. Son bord bas finit là
  /// où son bord haut était — le trou qu'elle laisse est alors entièrement
  /// découvert, et le mouvement se lit sans légende.
  static const double lift = cellHeight;

  /// L'ombre de la carte sortie : flou et décalage.
  static const double cardShadowBlur = 30;
  static const double cardShadowDrop = 12;

  /// Ce dont l'ombre déborde au-dessus de la carte, au pire.
  static const double shadowReach = cardShadowBlur - cardShadowDrop;

  /// La bande transparente réservée **au-dessus** de la couverture.
  ///
  /// **La carte sortie n'appartient plus au classeur.** Hissée d'une hauteur
  /// entière, une carte de la première rangée passe au-dessus de la couverture
  /// — c'est exactement ce qu'on veut voir, et c'est aussi ce qui la ferait
  /// trancher net si la planche s'arrêtait au classeur. On lui réserve donc ce
  /// qui lui manque, ombre comprise : [lift] moins ce qu'elle a déjà
  /// au-dessus d'elle ([gridTop]).
  ///
  /// La planche grandit d'autant, et **la source OBS change de taille** : la
  /// bande est transparente, mais le rectangle à placer dans la scène n'est
  /// plus le même.
  static const double topRoom = lift - gridTop + shadowReach > 0
      ? lift - gridTop + shadowReach
      : 0;

  /// La planche entière : la bande, puis la couverture.
  static const double height = topRoom + coverHeight;

  /// Largeur de la couverture quand rien ne sort du classeur.
  ///
  /// **Une page n'a pas de carte à poser à côté.** La gouttière et l'aire de la
  /// carte sortie ne servent qu'à ça ; les garder laissait un tiers de
  /// couverture vide et sombre à droite de la page — un panneau qui n'attend
  /// rien. Vu sur l'image, pas dans le code.
  static const double coverWidthAlone = pad + spine + pageWidth + pad;

  /// Où la couverture est posée sur la planche.
  ///
  /// **La planche, elle, ne change pas de taille.** C'est un rectangle qu'on
  /// place une fois dans une scène OBS ; le voir se rétrécir d'une commande à
  /// l'autre déplacerait le classeur sous les yeux. Seule la couverture se
  /// resserre, et ce qu'elle libère devient transparent.
  static Rect coverRect({bool withHero = true}) => Rect.fromLTWH(
    0,
    topRoom,
    withHero ? width : coverWidthAlone,
    coverHeight,
  );

  /// La page elle-même, sur laquelle les cases sont posées.
  static Rect get pageRect =>
      Rect.fromLTWH(pad + spine, pad, pageWidth, pageHeight);

  /// De combien une feuille en vol a le droit de grossir.
  ///
  /// **C'est la planche qui le dit, pas le goût.** Une feuille qui se dresse
  /// vient vers l'œil, donc grossit — c'est *ce qui se voit* du mouvement. Mais
  /// elle grossit vers le bas et vers la droite, depuis le coin haut-gauche de
  /// la page, et ce qui dépasse de la couverture est tranché net. Le
  /// renflement admissible est donc exactement ce qu'il reste de hauteur sous
  /// la couverture, une fois la page posée : 489 pour 413, soit 18 %. **Sous la
  /// couverture, et non sous la planche** — celle-ci réserve en plus une bande
  /// au-dessus pour la carte qu'on sort, et l'y compter ferait déborder les
  /// feuilles de moitié.
  ///
  /// L'application, elle, s'en permet 2,4 fois — sa feuille occupe l'écran et
  /// ce qui déborde sort par le bord du téléphone, où personne ne le voit.
  static const double leafBulge = (coverHeight - 2 * pad) / pageHeight;

  /// Force de la perspective d'une feuille en vol.
  ///
  /// **Déduite du renflement, jamais choisie à vue.** Une feuille pivotant
  /// autour de sa reliure s'enfonce vers l'œil d'au plus une largeur de page ;
  /// la perspective divise alors les distances par `1 − p·largeur`, d'où
  /// `p = (1 − 1/renflement) / largeur`. Réglée à la main, elle divergerait de
  /// la boîte au premier changement de géométrie — et une feuille tranchée en
  /// deux ne ressemble plus à rien.
  static const double leafPerspective = (1 - 1 / leafBulge) / pageWidth;

  /// L'espace laissé à une feuille en vol, depuis le coin haut-gauche de la
  /// page. Plus grand que la page, du renflement exactement — une boîte à la
  /// taille de la page trancherait net le bas de la feuille au moment où elle
  /// se soulève. C'est aussi le rectangle qui rogne : voir `_sheet`, qui pose
  /// le `ClipRect` et dit pourquoi il ne peut pas venir d'ailleurs.
  static Size get leafBox =>
      Size(pageWidth * leafBulge, pageHeight * leafBulge);

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

  /// Part du temps de sortie consacrée à l'extraction verticale.
  ///
  /// **Deux gestes, pas un.** Une carte glissée d'un trait de sa case vers la
  /// droite ne sort de rien : elle traverse la page, et le classeur n'est plus
  /// qu'un décor. On la **hisse** d'abord hors de sa pochette, puis on
  /// l'emporte. Un tiers du temps pour le premier geste suffit à le rendre
  /// lisible sans retarder le second.
  static const double liftFraction = 0.35;

  /// La case, une fois la carte tirée hors de sa pochette.
  static Rect liftedRect(int slot) => slotRect(slot).translate(0, -lift);

  /// Où la carte se trouve à cet avancement de sortie.
  ///
  /// **Elle part de sa case et non du bord de la planche** : c'est toute la
  /// différence entre « une carte apparaît » et « cette carte-là sort d'ici ».
  /// Puis elle monte droit, à taille constante — on la sort —, et alors
  /// seulement s'envole vers la droite en grandissant.
  static Rect cardRect(int slot, double eject) {
    final t = eject.clamp(0.0, 1.0);
    final depart = slotRect(slot);
    final hissee = liftedRect(slot);
    // **La même courbe pour les deux temps, et ce n'est pas de la paresse.**
    // Un `easeOut` sur le premier suivi d'un `easeOutCubic' sur le second
    // enchaîne une fin à vitesse nulle sur un départ à vitesse maximale : la
    // carte s'arrête net au-dessus de sa case, puis part d'un coup. Deux
    // `easeInOut` se recollent à vitesse nulle des deux côtés — on la sort, on
    // marque le temps, on l'emporte.
    if (t <= liftFraction) {
      return Rect.lerp(
        depart,
        hissee,
        Curves.easeInOutCubic.transform(t / liftFraction),
      )!;
    }
    final envol = (t - liftFraction) / (1 - liftFraction);
    return Rect.lerp(hissee, heroRect, Curves.easeInOutCubic.transform(envol))!;
  }

  /// La même course, mais en coordonnées **planche**.
  ///
  /// Tout le reste du calque est repéré dans la couverture ; seule la carte en
  /// sort, et la conversion vit ici — une seule fois, à l'endroit où elle a un
  /// sens — plutôt que dispersée dans le dessin.
  static Rect cardOnPlank(int slot, double eject) =>
      cardRect(slot, eject).translate(0, topRoom);
}

/// Début et fin de l'effacement d'une feuille en vol, en tours.
///
/// **La feuille s'efface avant d'avoir fini son tour, et c'est une contrainte,
/// pas un goût.** Un classeur ouvert à plat reçoit la feuille sur sa page de
/// gauche ; le calque n'a pas de page à gauche — il n'a que le dos et le bord
/// de la couverture. À la moitié de son tour la feuille est **de champ** — elle
/// a pivoté d'un quart de tour —, et au-delà elle repart de l'autre côté du dos
/// où plus rien ne l'attend. On la laisse se mettre de champ, c'est là qu'on
/// aperçoit son verso, et on l'éteint juste après. Ce qui a tout de même
/// franchi la reliure est rogné : voir `_sheet`.
const double _fadeFrom = 0.42;
const double _fadeTo = 0.56;

class BinderReveal extends StatelessWidget {
  const BinderReveal({
    super.key,
    required this.request,
    required this.cells,
    required this.elapsed,
    this.sheetBack,
  });

  /// Ce qu'on a demandé de montrer : une carte, ou une page.
  ///
  /// **Un `switch` exhaustif plutôt qu'un drapeau.** Le jour où un troisième
  /// genre arrive, le compilateur montre chaque endroit à compléter — un
  /// booléen, lui, laisserait le troisième cas se ranger silencieusement du
  /// côté de l'un des deux autres.
  final BinderRequest request;

  /// Les neuf cases de la page. Peut être vide — la lecture de la page est un
  /// second appel, et **son échec ne doit pas empêcher la carte de sortir** :
  /// la grille se dessine alors sans savoir quelles voisines sont possédées.
  final List<BinderCell> cells;

  /// Millisecondes écoulées depuis l'arrivée de la demande.
  final double elapsed;

  /// Le vrai dos des cartes du jeu, ou `null` pour le motif dessiné.
  ///
  /// **Donné, jamais chargé ici.** Ce widget est pur : il ne lance pas de
  /// requête, ne tient pas d'état, et rend la même image pour le même
  /// `elapsed`. Le chargement appartient à celui qui tient l'horloge — voir
  /// `card_back.dart`.
  final ui.Image? sheetBack;

  /// La carte demandée, ou `null` quand c'est une page.
  SpotlightCard? get card => switch (request) {
    final SpotlightCard c => c,
    SpotlightPage() => null,
  };

  RevealTiming get timing => RevealTiming.of(request);

  @override
  Widget build(BuildContext context) {
    final t = timing;
    final couleurs = Theme.of(context).colorScheme;
    // **Bâties une fois, données aux trois feuilles.** Chaque feuille les
    // redonne à ses dix lamelles ; construire la face à chaque lamelle, c'était
    // trente pages de neuf cases par image.
    final recto = SheetFace(
      key: const ValueKey('dos-de-feuille'),
      colors: couleurs,
      padding: RevealMetrics.pagePad,
      gap: RevealMetrics.gap,
      back: sheetBack,
    );
    final verso = SheetFace(
      colors: couleurs,
      padding: RevealMetrics.pagePad,
      gap: RevealMetrics.gap,
      pockets: true,
    );
    final ouverture = Curves.easeOutCubic.transform(t.openAt(elapsed));
    final eject = t.ejectAt(elapsed);
    final avance = t.riffleAt(elapsed);
    final posee = avance >= 1;

    // **La carte sortie est dessinée hors de la couverture.** Elle monte d'une
    // hauteur entière : sur la première rangée elle passe au-dessus du
    // classeur, et le rognage de la couverture — celui qui retient les feuilles
    // en vol — la couperait net au moment précis où on la regarde sortir.
    return SizedBox(
      width: RevealMetrics.width,
      height: RevealMetrics.height,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: RevealMetrics.coverRect(withHero: card != null),
            child: _cover(
              couleurs,
              t,
              ouverture,
              eject,
              avance,
              posee,
              recto,
              verso,
            ),
          ),
          if (posee) ..._sortie(couleurs, eject),
        ],
      ),
    );
  }

  /// Le classeur lui-même : couverture, dos, page, feuilles, légende.
  Widget _cover(
    ColorScheme couleurs,
    RevealTiming t,
    double ouverture,
    double eject,
    double avance,
    bool posee,
    Widget recto,
    Widget verso,
  ) {
    return Opacity(
      opacity: ouverture,
      child: Transform(
        // La clef sert à un test : une fois la couverture à plat, la matrice
        // doit être l'identité, et rien dans l'image rendue ne le dit.
        key: const ValueKey('couverture'),
        alignment: Alignment.centerLeft,
        // **Une fois ouvert, la couverture ne porte plus aucune matrice — et
        // c'est un correctif, pas une optimisation.** Une matrice de
        // perspective sans rotation *n'est pas* neutre : elle ne fait rien aux
        // enfants plats, mais elle divise par `1 + p·z` tout ce qui porte une
        // profondeur. Les feuilles en vol en portent une, et elles héritaient
        // donc d'une seconde perspective — celle-ci prise autour du **milieu**
        // de la couverture, là où la leur part du haut de la page. Résultat :
        // la feuille se dilatait vers le haut *et* vers le bas depuis la
        // moitié du classeur, son bord supérieur montait en biais au-dessus de
        // la page, et le tout grossissait d'une bonne moitié de plus que prévu.
        // Rien de visible dans le code de la feuille : le défaut vivait deux
        // widgets plus haut.
        transform: ouverture >= 1
            ? Matrix4.identity()
            : (Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                // Le classeur bascule vers le lecteur en s'ouvrant, comme une
                // couverture qu'on relève.
                ..rotateY(-(1 - ouverture) * 1.15)),
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
                // **Rien ne vole tant que la couverture n'est pas à
                // plat.** Le défilé ne commence qu'à la fin de l'ouverture ;
                // dessiner les feuilles avant, c'était les figer à leur
                // phase de départ pendant trois cents millisecondes — trois
                // pages arrêtées en plein vol dans un classeur qui s'ouvre.
                if (t.riffle > 0 && avance > 0 && avance < 1)
                  ..._sheets(avance, recto, verso),
                if (posee && card != null) _highlight(couleurs, card!.slot),
                _footer(couleurs, t.pageAt(elapsed)),
              ],
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
          // semble sortir d'une case déjà vide. Une page ne vide rien.
          sortie: slot == card?.slot && eject > 0,
        ),
      ),
  ];

  /// La carte qui sort, s'il y en a une.
  List<Widget> _sortie(ColorScheme couleurs, double eject) {
    final carte = card;
    return carte == null ? const [] : [_card(couleurs, carte, eject)];
  }

  BinderCell? _cellFor(int slot) {
    final index = slot - 1;
    if (index < 0 || index >= cells.length) return null;
    return cells[index];
  }

  /// Les pages qui défilent — trois feuilles en vol, déphasées, montrant le dos
  /// des cartes.
  ///
  /// **Le nombre de tours vient du temps, pas du nombre de pages.** Une feuille
  /// met [RevealTiming.sheetTurn] à traverser, quelle que soit la distance à
  /// parcourir ; le défilé en montre donc d'autant plus qu'il dure longtemps.
  /// Voir [RevealTiming.sheetTurn] pour ce que ce découplage règle.
  ///
  /// **Les phases sont triées, et ce n'est pas de la cosmétique.** Elles
  /// bouclent modulo un tour : sans tri, la feuille qui vient de repasser par
  /// zéro se retrouvait dessinée par-dessus des feuilles plus avancées
  /// qu'elle, et la pile sautait une fois par tour. Dans un feuilletage, la
  /// plus avancée est la plus haute.
  List<Widget> _sheets(double avance, Widget recto, Widget verso) {
    final tours = avance * timing.riffle / RevealTiming.sheetTurn;
    final phases = [for (var k = 0; k < 3; k++) (tours + k * 0.34) % 1.0]
      ..sort();
    return [for (final local in phases) _sheet(local, recto, verso)];
  }

  /// Une feuille en vol, pliée comme celle du classeur de l'application.
  ///
  /// **C'est [CurlingLeaf], et pas une rotation écrite ici.** La première
  /// version pivotait un plan rigide de `-local * π` autour de sa reliure : le
  /// signe envoyait la feuille **derrière** le plan de l'écran — elle
  /// rétrécissait en s'enfonçant dans le classeur au lieu de venir vers
  /// l'œil —, et l'absence de courbure la faisait lire comme une carte à jouer
  /// qu'on retourne. Or le produit sait déjà tourner une page :
  /// `page_turn.dart` le fait sous le doigt, à l'écran de collection.
  /// Reprendre son pliage plutôt que d'en écrire un second est la seule façon
  /// que les deux ne divergent pas — ils avaient déjà divergé.
  ///
  /// **La boîte est plus grande que la page, et elle rogne.** Une feuille
  /// dressée grossit sous la perspective — c'est *ce qui se voit* quand elle
  /// vient vers nous —, d'où une boîte au renflement près
  /// ([RevealMetrics.leafBox]). Elle rogne pour deux raisons distinctes : vers
  /// le bas, pour que le renflement s'arrête avec la couverture ; et surtout à
  /// **gauche**, sur la reliure. Passé le quart de tour, les lamelles du bord
  /// libre se rabattent de l'autre côté du dos et se peignaient par-dessus les
  /// anneaux, en fragments translucides. Dans un classeur, ce qui a franchi la
  /// reliure passe derrière : ici, il disparaît.
  ///
  /// **Le rognage est explicite, et il doit l'être.** Le `Stack` de
  /// [CurlingLeaf] ne suffit pas : il décide de rogner d'après la *disposition*
  /// de ses enfants, et les lamelles ne sortent de leur boîte qu'au moment de
  /// la *peinture*, par leur matrice. Il ne rogne donc rien du tout.
  Widget _sheet(double local, Widget recto, Widget verso) {
    // Passé le quart de tour, la feuille est de l'autre côté du dos. Le calque
    // n'a pas de page à gauche pour la recevoir : on l'efface là plutôt que de
    // la traîner jusqu'au demi-tour. Opaque jusque-là — une feuille de papier
    // ne laisse pas voir la page d'en dessous.
    final visible = local < _fadeFrom
        ? 1.0
        : math.max(0.0, (_fadeTo - local) / (_fadeTo - _fadeFrom));
    if (visible <= 0) return const SizedBox.shrink();

    final page = RevealMetrics.pageRect;
    return Positioned(
      left: page.left,
      top: page.top,
      width: RevealMetrics.leafBox.width,
      height: RevealMetrics.leafBox.height,
      child: Opacity(
        opacity: visible,
        child: ClipRect(
          child: Stack(
            children: [
              // L'ombre que la feuille levée porte sur ce qu'elle découvre —
              // page de destination ou feuille précédente, selon ce qui a déjà
              // été peint. Sans elle, deux feuilles semblent dessinées sur le
              // même plan.
              Positioned.fromRect(
                rect: Offset.zero & page.size,
                // **Atténuée.** Sous le doigt, l'ombre tombe sur une page
                // pleine d'illustrations, qui a de quoi l'encaisser. Ici trois
                // feuilles volent en même temps et le nuancier est déjà sombre :
                // à pleine force, les ombres s'additionnent et la planche vire
                // au noir.
                child: Opacity(opacity: 0.6, child: CastShadow(t: local)),
              ),
              CurlingLeaf(
                t: local,
                width: page.width,
                height: page.height,
                perspective: RevealMetrics.leafPerspective,
                front: recto,
                back: verso,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// La case d'où la carte est sortie : un trou, cerclé de lumière.
  ///
  /// **Le fond est explicite, et il doit l'être.** Une première version laissait
  /// la décoration sans couleur : une `BoxShadow` peint un rectangle plein
  /// *derrière* la boîte, si bien que le halo traversait le vide et remplissait
  /// la case — on lisait « carte présente » là où l'on voulait montrer le trou
  /// qu'elle laisse. Vu sur l'image rendue, pas dans le code.
  Widget _highlight(ColorScheme couleurs, int slot) => Positioned.fromRect(
    rect: RevealMetrics.slotRect(slot),
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

  Widget _card(ColorScheme couleurs, SpotlightCard carte, double eject) {
    final rect = RevealMetrics.cardOnPlank(carte.slot, eject);
    // **L'ombre suit le décollement, pas la course entière.** Elle est le seul
    // indice qui dise « cette carte est devant la page, plus dedans ». Calée
    // sur `eject`, elle n'avait qu'un tiers de sa force à la fin du hissement :
    // la carte, montée d'une case pile, se lisait alors comme *glissée dans la
    // pochette du dessus* plutôt que sortie de la sienne. Vu sur l'image, pas
    // dans le code.
    final decolle = (eject / RevealMetrics.liftFraction).clamp(0.0, 1.0);
    return Positioned.fromRect(
      rect: rect,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: couleurs.surfaceContainerHigh,
          boxShadow: [
            BoxShadow(
              color: Color.fromRGBO(0, 0, 0, 0.6 * decolle),
              blurRadius: RevealMetrics.cardShadowBlur * decolle,
              offset: Offset(0, RevealMetrics.cardShadowDrop * decolle),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CardImage(
            url: carte.imageUrl,
            uprightInCell: true,
            placeholder: _fallback(couleurs, carte),
            errorBuilder: (_) => _fallback(couleurs, carte),
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
  Widget _fallback(ColorScheme couleurs, SpotlightCard carte) => Center(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        carte.collectorNumber == null ? '—' : '#${carte.collectorNumber}',
        textAlign: TextAlign.center,
        style: TextStyle(color: couleurs.onSurfaceVariant, fontSize: 15),
      ),
    ),
  );

  /// L'extension, telle qu'on la nomme : son nom complet, sinon son code.
  String get _ou {
    final nom = request.setName;
    if (nom != null && nom.isNotEmpty) return nom;
    return request.setCode?.toUpperCase() ?? '';
  }

  /// Le titre et sa ligne de détail, selon ce qu'on montre.
  ///
  /// **Une page se nomme par son extension, pas par une carte.** Mettre en
  /// titre l'une des neuf laisserait croire que c'est elle qu'on a demandée.
  /// Et le détail dit ce que la page apprend : combien de ses cases sont
  /// pleines — le même « 4/9 » que le chat, mais à côté de l'image qui le
  /// montre.
  (String, String) _legende(int pageAffichee) {
    final carte = card;
    if (carte == null) {
      final tenues = cells.where((c) => c.owned > 0).length;
      final detail = [
        'page $pageAffichee sur ${request.pages}',
        // Rien quand la lecture des cases n'est pas revenue : un « 0 sur 9 »
        // annoncerait une page vide là où l'on ne sait simplement pas encore.
        if (cells.isNotEmpty) '$tenues cases sur ${cells.length}',
      ].join('  ·  ');
      return (_ou, detail);
    }

    final ou = [
      if (_ou.isNotEmpty) _ou,
      'page $pageAffichee',
      'case ${carte.slot}',
    ].join(' — ');
    final marques = [
      if (carte.collectorNumber != null) '#${carte.collectorNumber}',
      if (carte.copies > 1) '×${carte.copies}',
      if (carte.priceEur != null)
        '${carte.priceEur!.toStringAsFixed(2).replaceAll('.', ',')} €',
    ].join('  ·  ');
    return (carte.displayName, marques.isEmpty ? ou : '$ou  ·  $marques');
  }

  Widget _footer(ColorScheme couleurs, int pageAffichee) {
    final (titre, detail) = _legende(pageAffichee);

    return Positioned(
      left: RevealMetrics.pad,
      right: RevealMetrics.pad,
      bottom: RevealMetrics.pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            titre,
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
            detail,
            style: TextStyle(color: couleurs.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              // **Le pseudonyme cède, le crédit jamais.** La base autorise
              // quarante caractères, et la couverture se resserre quand rien
              // ne sort du classeur : sans cette souplesse, la ligne débordait
              // — mesuré à 49 px. Le crédit, lui, est un garde-fou (§IV.2) et
              // ne peut pas être ce qui disparaît.
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: couleurs.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    request.requestedBy == null
                        ? 'demandée dans le chat'
                        : 'demandée par ${request.requestedBy}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: couleurs.onPrimaryContainer,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
