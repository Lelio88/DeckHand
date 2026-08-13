/// Reconnaître au fil de la caméra, image après image (#8).
///
/// **Ce module est la couture, pas un nouvel algorithme.** Tout ce qu'il
/// assemble existe et a été mesuré séparément :
///
/// | Pièce | Ce qu'elle décide | Mesurée dans |
/// |---|---|---|
/// | [QuadTracker] | quand redétecter la carte | `tool/stream_bench.dart` |
/// | `findCardInLuma` | où elle est | banc embarqué |
/// | `sampleArtFromLuma` + `artHashFromLuma` | son empreinte | banc embarqué |
/// | [ArtHashIndex] | quelle carte c'est, ou le silence | `art_collisions.py` |
/// | [CardTracker] | quand c'en est une **nouvelle** | ← ici, enfin |
///
/// Les écrire séparément n'était pas un détour : chacune a un banc, et une
/// chaîne qu'on ne peut mesurer que de bout en bout ne se règle pas.
///
/// **Rien n'entre en collection ici.** Le garde-fou §IV.8 est intact : ce module
/// rend ce qu'il a vu, l'écran en fait un panier, et l'utilisateur confirme.
/// C'est la forme de la liste à cocher de l'étalement, déjà éprouvée, et elle a
/// précisément pour rôle de rendre décochable la carte que le seuil laisse
/// passer.
///
/// **Le coût d'une image est connu** : 12,3 ms avec suivi contre 27,4 sans, pour
/// 33 disponibles à 30 images par seconde. Ce module n'ajoute que la recherche
/// dans l'index, déjà comptée dans ces chiffres.
///
/// Exemple canonique :
/// ```dart
/// final scanner = LiveScanner(index: index, game: 'magic');
/// for (final frame in flux) {
///   final seen = scanner.observe(frame.luma, width: ..., height: ...);
///   if (seen.accepted != null) panier.ajouter(seen.accepted!);
/// }
/// ```
library;

import 'dart:typed_data';

import 'art_box.dart';
import 'art_hash.dart';
import 'art_hash_index.dart';
import 'card_bounds.dart';
import 'card_tracker.dart';
import 'camera_frame.dart';
import 'quad_tracker.dart';

/// Pourquoi une image n'a rien donné — ou ce qu'elle a donné.
///
/// **Trois échecs, trois remèdes, et rien ne les distinguait.** « Carte non
/// reconnue » recouvrait jusqu'ici une détection qui n'a pas trouvé de
/// quadrilatère, un index qui n'a rien de proche, et une correspondance
/// refusée faute de marge. Le premier se corrige en recadrant, le deuxième dit
/// que la carte est absente de l'index ou que l'illustration est mal prélevée,
/// le troisième que deux cartes se ressemblent trop. Les confondre fait chercher
/// au mauvais endroit.
enum FrameOutcome {
  /// Aucun quadrilatère : la détection de bords n'a pas trouvé de carte.
  notFound,

  /// Une carte est là, mais rien d'assez proche dans l'index.
  silent,

  /// Un candidat est assez proche, mais un second l'est presque autant :
  /// l'index refuse de trancher, et c'est le comportement voulu.
  unsure,

  /// Reconnue sans réserve. N'entre au panier que si le suivi temporel juge
  /// qu'il s'agit d'un nouveau passage.
  confident,
}

/// Ce qu'une image du flux a donné.
class LiveObservation {
  const LiveObservation({
    this.watching,
    this.streak = 0,
    this.accepted,
    this.detected = false,
    this.located = false,
    this.distance,
    this.margin,
    this.best,
    this.outcome = FrameOutcome.notFound,
  });

  /// Le meilleur candidat, **même quand il est refusé**.
  ///
  /// C'est la valeur qui manque le plus quand une carte n'est pas reconnue :
  /// savoir *qui* l'index a failli dire, et à quelle distance, sépare une
  /// illustration mal prélevée d'une carte réellement absente.
  final String? best;

  /// Écart entre le meilleur candidat et le suivant. `null` s'il est seul.
  final int? margin;

  /// Ce que cette image a produit, et pourquoi.
  final FrameOutcome outcome;

  /// L'identifiant que le flux montre **en ce moment**, avant toute décision.
  ///
  /// Exposé pour l'écran : il doit pouvoir dire ce que l'appareil regarde, pas
  /// seulement ce qu'il a fini par retenir. Sans cela, l'utilisateur ne sait
  /// pas si la carte est mal posée ou si l'application réfléchit encore.
  final String? watching;

  /// Images consécutives déjà vues sur [watching].
  final int streak;

  /// L'identifiant retenu **à cette image précise**, sinon `null`.
  ///
  /// Non nul une seule fois par carte physique : c'est ce que garantit
  /// [CardTracker], et c'est ce qui autorise l'écran à l'ajouter au panier sans
  /// dédoublonner lui-même.
  final String? accepted;

  /// La détection de bords a tourné sur cette image. Pour le diagnostic : c'est
  /// la fraction de ces images qui décide du coût réel du flux.
  final bool detected;

  /// Un quadrilatère était disponible — la carte est dans le champ.
  final bool located;

  /// Distance du meilleur candidat, quand il y en a un. `null` quand l'index
  /// s'est tu, ce qui est un résultat et non une panne.
  final int? distance;
}

/// Reconnaît au fil d'un flux de plans de luminance.
///
/// Objet à état : une instance par session de scan. [reset] la rend à son état
/// initial entre deux boosters.
class LiveScanner {
  LiveScanner({
    required ArtHashIndex index,
    this.game = 'magic',
    QuadTracker? quads,
    CardTracker? cards,
  }) : _index = index,
       _quads = quads ?? QuadTracker(),
       _cards = cards ?? CardTracker();

  final ArtHashIndex _index;
  final String game;
  final QuadTracker _quads;
  final CardTracker _cards;

  /// Ce que l'appareil regarde, pour l'écran.
  String? get watching => _cards.watching;

  /// Une image du flux, du plan de luminance à l'identifiant.
  ///
  /// **L'ordre des trois décisions n'est pas indifférent.** On demande d'abord
  /// au suivi s'il faut redétecter — c'est le poste à 23 ms —, puis on hache
  /// avec le quadrilatère tenu, puis seulement on interroge l'index. Inverser
  /// paierait la détection sur des images que le suivi rendait inutiles.
  LiveObservation observe(
    Uint8List luma, {
    required int width,
    required int height,
    required int rowStride,
    int pixelStride = 1,
  }) {
    var detected = false;
    if (_quads.needsDetection) {
      _quads.adopt(_detect(luma, width, height, rowStride, pixelStride));
      detected = true;
    }

    final quad = _quads.quad;
    if (quad == null) {
      // Rien dans le champ. **Le suivi temporel doit quand même l'apprendre** :
      // c'est le blanc entre deux cartes qui autorise la suivante à être
      // retenue, et le lui cacher ferait passer deux exemplaires pour un.
      _cards.observe(null);
      return LiveObservation(watching: _cards.watching, streak: _cards.streak);
    }

    final hypotheses = _hashesIn(
      luma,
      width: width,
      height: height,
      rowStride: rowStride,
      pixelStride: pixelStride,
      quad: quad,
    );

    // Le suivi de quadrilatère se règle sur l'hypothèse **principale** — cadre
    // droit, sans rotation. Prendre la meilleure de toutes le ferait sauter
    // chaque fois que le vainqueur change d'hypothèse, alors que la scène,
    // elle, n'a pas bougé.
    final anchor = hypotheses.entries.first.value;
    if (_quads.jumped(anchor)) {
      _quads.adopt(_detect(luma, width, height, rowStride, pixelStride));
      detected = true;
      final fresh = _quads.quad;
      if (fresh == null) {
        _cards.observe(null);
        return LiveObservation(
          watching: _cards.watching,
          streak: _cards.streak,
          detected: true,
        );
      }
      return _judge(
        _hashesIn(
          luma,
          width: width,
          height: height,
          rowStride: rowStride,
          pixelStride: pixelStride,
          quad: fresh,
        ),
        detected: detected,
      );
    }
    _quads.keep(anchor);

    return _judge(hypotheses, detected: detected);
  }

  LiveObservation _judge(
    Map<ArtHypothesis, ArtHash> hypotheses, {
    required bool detected,
  }) {
    final outcome = _index.searchAny(hypotheses);
    final result = outcome.result;
    // **Le silence de l'index est une réponse, pas un échec.** Une empreinte
    // trop éloignée ou trop ambiguë ne désigne rien, et le suivi temporel doit
    // le voir comme une image muette — sans quoi une carte à moitié reconnue
    // accumulerait une série qu'elle n'a pas gagnée.
    final confident = result.isConfident;
    final id = confident ? result.best?.oracleId : null;
    final accepted = _cards.observe(id);

    final best = result.best;
    return LiveObservation(
      watching: _cards.watching,
      streak: _cards.streak,
      accepted: accepted,
      detected: detected,
      located: true,
      distance: best?.distance,
      margin: result.margin,
      best: best?.oracleId,
      outcome: confident
          ? FrameOutcome.confident
          // Un candidat sous le seuil mais sans marge n'est pas la même panne
          // qu'un index qui n'a rien de proche : le premier dit que deux cartes
          // se ressemblent, le second que l'illustration prélevée ne ressemble
          // à rien de connu.
          : (best != null && best.distance <= maxTrustedDistance
                ? FrameOutcome.unsure
                : FrameOutcome.silent),
    );
  }

  CardQuad? _detect(
    Uint8List luma,
    int width,
    int height,
    int rowStride,
    int pixelStride,
  ) => findCardInLuma(
    luma,
    width: width,
    height: height,
    rowStride: rowStride,
    pixelStride: pixelStride,
    game: game,
  );

  /// Les empreintes candidates, une par cadre du jeu et par orientation
  /// plausible — les mêmes hypothèses que le mode photo, lues sans construire
  /// d'image.
  ///
  /// La première entrée est l'hypothèse principale, et le suivi s'y ancre.
  Map<ArtHypothesis, ArtHash> _hashesIn(
    Uint8List luma, {
    required int width,
    required int height,
    required int rowStride,
    required int pixelStride,
    required CardQuad quad,
  }) {
    final uprightQuad = quad.aspect <= 1;
    final candidates = <ArtHypothesis, ArtHash>{};
    for (final frame in CardFrame.values) {
      if (frame.game != game) continue;
      // Un cadre couché cherché dans un quadrilatère droit est lu tourné, dans
      // les deux sens : une carte couchée glissée dans une pochette verticale
      // se laisse détecter comme une carte debout, et une empreinte ne survit
      // pas au demi-tour. La réciproque est refusée — un quadrilatère couché
      // autour d'une carte debout signale une détection fausse.
      final turns = frame.landscape && uprightQuad ? const [1, 3] : const [0];
      for (final t in turns) {
        candidates[(frame: frame, quarterTurns: t)] = artHashFromLuma(
          sampleArtFromLuma(
            luma,
            width: width,
            height: height,
            rowStride: rowStride,
            pixelStride: pixelStride,
            quad: quad.quarterTurned(t),
            box: frame.box,
          ),
          width: 256,
          height: 190,
          rowStride: 256,
        );
      }
    }
    return candidates;
  }

  /// Oublie tout. À appeler entre deux lots, sans quoi la première carte du
  /// second compterait comme la suite du premier.
  void reset() {
    _quads.reset();
    _cards.reset();
  }
}
