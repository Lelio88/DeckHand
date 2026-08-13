/// Quand faut-il redétecter la carte, et quand suffit-il de la suivre ? (#8)
///
/// **Le problème que ce module résout.** Détecter les bords d'une carte coûte
/// 23 ms sur l'appareil, contre 4,5 ms pour découper, hacher et chercher. Or
/// *une carte posée ne bouge pas de 33 ms en 33 ms* : redétecter à chaque image
/// refait un travail dont le résultat est déjà connu. Ce module décide quand ce
/// travail est nécessaire.
///
/// **C'est le cousin spatial de [CardTracker]**, qui décide, lui, quand une
/// *carte* change. Celui-ci décide quand un *quadrilatère* a cessé d'être
/// valable. Les deux sont indépendants : un même quadrilatère peut voir passer
/// deux cartes, et une même carte peut être vue sous deux quadrilatères.
///
/// **Deux garde-fous, et il en faut deux.** Mesuré par
/// `app/tool/stream_bench.dart` :
///
/// - **le saut** ([jumpBits]) — une empreinte qui bondit signale que la scène a
///   changé. Sur une carte immobile, l'empreinte varie de 1 à 2 bits d'une
///   image à l'autre ; quand la carte est remplacée, elle bondit de 35. Le
///   fossé est large, et c'est lui qui rend un seuil possible.
/// - **l'âge** ([maxAge]) — une dérive lente ne saute jamais. Chaque pas reste
///   sous le seuil, et pourtant ils s'accumulent : mesuré, un quadrilatère
///   laissé en place pendant une dérive s'écarte de **35 bits** de ce qu'une
///   détection fraîche aurait donné, sans qu'aucun saut ne se soit produit.
///   Aucun seuil de saut, si bas soit-il, ne peut voir cela — c'est
///   structurel, et c'est pourquoi l'âge n'est pas une précaution mais la
///   seconde moitié de la règle.
///
/// **Ce que la dérive coûte n'est pas une erreur, mais un silence.** Une
/// empreinte trop éloignée ne ressemble plus à rien : l'index se tait, ce qui
/// est le comportement voulu. Mesuré sur la séquence du banc, aucune stratégie
/// n'annonce jamais une carte fausse — elles perdent des reconnaissances, elles
/// n'en inventent pas. Le réglage arbitre donc entre du calcul et des cartes
/// manquées, jamais entre du calcul et des cartes inventées.
///
/// Exemple canonique :
/// ```dart
/// final tracker = QuadTracker();
/// for (final frame in flux) {
///   if (tracker.needsDetection) {
///     tracker.adopt(findCardInLuma(frame, ...));
///   }
///   final quad = tracker.quad;
///   if (quad == null) continue;
///
///   var hash = hashWith(frame, quad);
///   if (tracker.jumped(hash)) {
///     // La scène a changé sous le quadrilatère : on le refait, puis on rehache.
///     tracker.adopt(findCardInLuma(frame, ...));
///     final fresh = tracker.quad;
///     if (fresh == null) continue;
///     hash = hashWith(frame, fresh);
///   }
///   tracker.keep(hash);
/// }
/// ```
library;

import 'art_hash.dart';
import 'card_bounds.dart';

/// Écart d'empreinte, en bits, au-delà duquel la scène est tenue pour changée.
///
/// **Provisoire, et voici ce qui est mesuré autour.** Sur des images
/// synthétiques, le plancher de bruit d'une carte immobile à quadrilatère gelé
/// vaut 1 à 2 bits, et un échange de carte en produit 35. Le seuil peut donc
/// être placé n'importe où entre les deux, et 12 le met au milieu du fossé —
/// c'est aussi `maxTrustedDistance`, au-delà duquel l'index refuse déjà de
/// répondre : une empreinte qui s'en écarte autant ne désigne plus rien.
///
/// **Ce que la mesure ne donne pas** : le plancher d'un *vrai* capteur, plus
/// bruyant qu'une image composée. C'est la seule raison de revoir cette valeur,
/// et elle demande un flux réel.
const int defaultJumpBits = 12;

/// Images pendant lesquelles un quadrilatère reste valable sans être revérifié.
///
/// **Provisoire, et c'est l'arbitrage principal.** Mesuré sur la séquence du
/// banc, à seuil de saut égal : un âge de 3 images ne perd aucune
/// reconnaissance pour 14,5 ms par image ; un âge de 5 en perd 3 pour 12,3 ms ;
/// un âge de 10 en perd 8 pour 10,7 ms. Redétecter à chaque image coûte
/// 27,4 ms. Cinq images — un sixième de seconde — garde l'essentiel du gain
/// sans lâcher grand-chose.
const int defaultMaxAge = 5;

/// Tient un quadrilatère entre deux détections, et dit quand le refaire.
///
/// Objet à état : une instance par session de flux. [reset] le rend à son état
/// initial.
class QuadTracker {
  QuadTracker({this.jumpBits = defaultJumpBits, this.maxAge = defaultMaxAge});

  /// Écart d'empreinte au-delà duquel [jumped] rend `true`.
  final int jumpBits;

  /// Nombre d'images après lequel le quadrilatère est abandonné d'office.
  final int maxAge;

  CardQuad? _quad;
  ArtHash? _previous;
  int _age = 0;

  /// Le quadrilatère tenu, ou `null` s'il faut détecter.
  CardQuad? get quad => _quad;

  /// Nombre d'images pendant lesquelles le quadrilatère courant a servi.
  int get age => _age;

  /// Faut-il détecter avant de hacher cette image ?
  ///
  /// Vrai quand aucun quadrilatère n'est tenu, ou quand celui-ci a atteint son
  /// âge maximal. **L'âge est vérifié ici et non dans [jumped]** : une dérive
  /// ne se voit pas dans l'empreinte, seulement dans le temps écoulé.
  bool get needsDetection => _quad == null || _age >= maxAge;

  /// Adopte le résultat d'une détection, `null` compris.
  ///
  /// **L'empreinte de référence est effacée à chaque adoption**, et pas
  /// seulement quand la détection échoue. Deux empreintes prises à travers deux
  /// quadrilatères différents ne se comparent pas : mesuré, une redétection
  /// déplace le quadrilatère assez pour faire bouger l'empreinte de 11 bits sur
  /// une carte pourtant immobile. Les garder comparables déclenchait un faux
  /// saut juste après chaque détection forcée par l'âge, donc une seconde
  /// détection sur la même image — 68 détections là où l'âge seul en imposait
  /// 52. Le défaut ne se voyait qu'au compteur : aucune carte fausse, aucune
  /// carte perdue, seulement du calcul dépensé deux fois.
  void adopt(CardQuad? quad) {
    _quad = quad;
    _age = 0;
    _previous = null;
  }

  /// L'empreinte [hash], obtenue avec le quadrilatère tenu, signale-t-elle que
  /// la scène a changé ?
  ///
  /// Rend `false` sur la première empreinte suivant une détection : il n'y a
  /// alors rien à comparer, et le quadrilatère vient d'être établi sur cette
  /// image même.
  bool jumped(ArtHash hash) {
    final previous = _previous;
    return previous != null && hash.distanceTo(previous) > jumpBits;
  }

  /// Retient [hash] comme référence de la prochaine image, et vieillit le
  /// quadrilatère d'un cran.
  void keep(ArtHash hash) {
    _previous = hash;
    _age++;
  }

  /// Oublie tout. À appeler quand le flux s'interrompt.
  void reset() {
    _quad = null;
    _previous = null;
    _age = 0;
  }
}
