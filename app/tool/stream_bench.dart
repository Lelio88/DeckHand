/// Banc de flux : détecter à chaque image, ou suivre le quadrilatère ? (#8)
///
/// **La question que ce banc tranche.** Le flux libre tient dans le budget —
/// 27,4 ms par image mesurées sur l'appareil, pour 33 disponibles — mais la
/// détection en consomme 23 à elle seule, et *une carte posée ne bouge pas de
/// 33 ms en 33 ms*. Redétecter à chaque image paraît donc du gaspillage. Encore
/// faut-il savoir ce que le raccourci coûte, et il ne se paie pas en
/// millisecondes : il se paie en **cartes annoncées à tort**, le seul résultat
/// que ce pipeline protège.
///
/// **Trois stratégies, sur la même séquence** :
///
/// - `détection` — redétecter à chaque image. La référence : tout écart des
///   deux autres se mesure contre elle.
/// - `période N` — redétecter une image sur N, réutiliser le quadrilatère
///   entre-temps. L'idée naïve, mesurée pour ce qu'elle vaut.
/// - `saut K` — réutiliser le quadrilatère, hacher, et **ne redétecter que si
///   l'empreinte saute de plus de K bits**. La vérification est ici le travail
///   qu'on fait de toute façon : elle ne coûte rien de plus.
///
/// **Trois monnaies, parce que la décision en a trois.** Le nombre de
/// détections évitées (le gain), l'écart d'empreinte avec la référence (la
/// fidélité), et les cartes annoncées avec assurance que la référence
/// n'annonçait pas (le risque). Les deux premières se compensent ; la troisième
/// ne se négocie pas.
///
/// **Ce que la séquence contient, et pourquoi.** Quatre moments, chacun
/// éprouvant un mode de défaillance distinct :
///
/// | Moment | Ce qu'il met à l'épreuve |
/// |---|---|
/// | carte posée, immobile | le cas pour lequel le suivi existe |
/// | dérive lente | le quadrilatère devient faux **sans que rien ne l'annonce** |
/// | échange sur place | la géométrie reste juste, seule l'image change |
/// | retrait | plus rien devant l'objectif |
///
/// L'échange sur place est le cas décisif : un suivi qui ne vérifie que la
/// géométrie ne peut pas le voir.
///
/// **Le bruit de capteur est ajouté, et ce n'est pas un détail.** Sans lui,
/// deux images d'une carte immobile seraient identiques octet pour octet, leur
/// empreinte ne bougerait jamais, et n'importe quel seuil K paraîtrait
/// parfait. C'est précisément le plancher de bruit qu'il faut mesurer pour que
/// K veuille dire quelque chose.
///
/// **Ce que ce banc ne prouve pas.** Les photos sont composées : ni flou de
/// bougé, ni mise au point qui cherche, ni reflet sur un protège-carte. Les
/// durées d'un poste de travail ne transfèrent pas non plus à un téléphone —
/// c'est pourquoi le coût est ici **composé** à partir des durées déjà mesurées
/// sur l'appareil, et non chronométré. Ce qui transfère est le reste : les
/// comptages et les distances sont de l'arithmétique.
///
/// Usage :
/// ```
/// dart run tool/stream_bench.dart               # les trois stratégies
/// dart run tool/stream_bench.dart --cards 6     # séquence plus courte
/// dart run tool/stream_bench.dart --regime "ordinaire + lampe"
/// dart run tool/stream_bench.dart --noise 8    # capteur plus bruyant
/// ```
library;

// Ce fichier n'est pas embarqué : c'est un banc lancé à la main, et sa sortie
// EST son résultat.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/camera_frame.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/quad_tracker.dart';
import 'package:image/image.dart' as img;

import 'synthetic_photo.dart';

/// Durées relevées **sur l'appareil** (issue #8, commit `5a0d05f`), et non ici.
///
/// Un poste de travail est plusieurs fois plus rapide qu'un téléphone et Dart y
/// tourne en JIT : chronométrer ce banc donnerait des millisecondes qui ne
/// veulent rien dire. Ce qu'il mesure honnêtement est le **nombre** de
/// détections ; le coût s'en compose avec ces deux constantes.
const double detectionMillis = 22.9;
const double sampleHashSearchMillis = 4.5;

/// Le budget d'une image à 30 par seconde.
const double frameBudgetMillis = 33.3;

/// Amplitude du bruit de capteur ajouté à chaque image, en niveaux de gris.
///
/// **Mesuré au doigt mouillé, et c'est assumé** : ce banc ne prétend pas
/// reproduire un capteur, il prétend seulement qu'une image n'est jamais deux
/// fois la même. La valeur exacte importe peu tant que le plancher de bruit
/// qu'elle produit reste séparé du saut d'un échange — ce que la sortie
/// vérifie plutôt que de le supposer.
///
/// Réglable par `--noise`, et il faut s'en servir : c'est le paramètre dont
/// dépend le seuil de saut, et le seul que ce banc ne peut pas tirer d'un vrai
/// capteur.
int sensorNoise = 3;

/// Une image du flux : le plan de luminance, et la carte qui s'y trouve.
class Frame {
  Frame(this.luma, this.width, this.height, this.truth, this.moment);

  final Uint8List luma;
  final int width;
  final int height;

  /// L'identifiant de la carte réellement devant l'objectif, ou `null`.
  final String? truth;

  /// Le moment de la séquence, pour la ventilation du rapport.
  final String moment;
}

/// Ce qu'une stratégie a fait d'une image.
class Step {
  Step({
    required this.detected,
    required this.hash,
    required this.announced,
    required this.confident,
  });

  /// Combien de fois la détection a tourné sur cette image.
  ///
  /// **Un compte, pas un booléen.** Une stratégie qui redétecte parce que
  /// l'empreinte a sauté peut le faire *après* avoir déjà détecté sur la même
  /// image ; comptée en oui/non, la seconde disparaît et le coût est
  /// sous-estimé sans que rien ne le dise.
  final int detected;

  /// L'empreinte retenue, ou `null` si aucun quadrilatère n'était disponible.
  final ArtHash? hash;

  /// La carte que l'application annoncerait, ou `null` si elle se tait.
  final String? announced;

  final bool confident;
}

/// Une stratégie de flux : que faire, image après image.
abstract class Strategy {
  String get name;

  Step step(Frame frame, ArtHashIndex index, CardFrame cardFrame, String game);
}

/// Redétecter à chaque image. La référence.
class DetectEveryFrame implements Strategy {
  @override
  String get name => 'détection';

  @override
  Step step(Frame frame, ArtHashIndex index, CardFrame cardFrame, String game) {
    final quad = _detect(frame, game);
    if (quad == null) {
      return Step(detected: 1, hash: null, announced: null, confident: false);
    }
    final hash = _hashWith(frame, quad, cardFrame.box);
    final result = index.search(hash);
    return Step(
      detected: 1,
      hash: hash,
      announced: result.best?.oracleId,
      confident: result.isConfident,
    );
  }
}

/// Redétecter une image sur [period], réutiliser le quadrilatère entre-temps.
///
/// **L'idée naïve, et il faut la mesurer plutôt que l'écarter.** Elle ne coûte
/// aucune logique et divise le travail par [period] ; ce qu'elle ignore, c'est
/// qu'une carte peut bouger entre deux détections, et qu'un quadrilatère périmé
/// ne s'annonce pas.
class DetectPeriodically implements Strategy {
  DetectPeriodically(this.period);

  final int period;
  CardQuad? _quad;
  int _since = 1 << 30;

  @override
  String get name => 'période $period';

  @override
  Step step(Frame frame, ArtHashIndex index, CardFrame cardFrame, String game) {
    var detected = 0;
    if (_quad == null || _since >= period) {
      _quad = _detect(frame, game);
      _since = 0;
      detected++;
    }
    _since++;

    final quad = _quad;
    if (quad == null) {
      return Step(detected: detected, hash: null, announced: null, confident: false);
    }
    final hash = _hashWith(frame, quad, cardFrame.box);
    final result = index.search(hash);
    return Step(
      detected: detected,
      hash: hash,
      announced: result.best?.oracleId,
      confident: result.isConfident,
    );
  }
}

/// Réutiliser le quadrilatère, et ne redétecter que si l'empreinte saute.
///
/// **La vérification est le travail qu'on fait déjà.** Hacher coûte une demi-
/// milliseconde là où détecter en coûte vingt-trois ; comparer l'empreinte de
/// cette image à celle de la précédente ne coûte donc rien de plus que ce que
/// la reconnaissance demande de toute façon. Un saut signale que quelque chose
/// a changé — la carte a bougé, ou ce n'est plus la même — sans avoir à
/// distinguer laquelle des deux, puisque la réponse est la même : redétecter.
/// **Le banc mesure la politique du domaine, pas une copie.** `QuadTracker`
/// vit dans `lib/` et c'est lui qui partirait en production ; en mesurer une
/// réplique reviendrait à chronométrer un code que personne n'exécutera, et à
/// laisser les deux diverger en silence — exactement ce que la parité des
/// gabarits d'illustration existe pour éviter.
///
/// [maxAge] à `1 << 30` désactive de fait le garde-fou d'âge, ce qui permet de
/// mesurer ce que le seul seuil de saut sait faire — et ce qu'il ne sait pas.
class TrackUntilJump implements Strategy {
  TrackUntilJump(this.jump, {this.maxAge})
    : _tracker = QuadTracker(jumpBits: jump, maxAge: maxAge ?? 1 << 30);

  final int jump;
  final int? maxAge;
  final QuadTracker _tracker;

  @override
  String get name => maxAge == null ? 'saut $jump' : 'saut $jump + âge $maxAge';

  @override
  Step step(Frame frame, ArtHashIndex index, CardFrame cardFrame, String game) {
    var detected = 0;
    if (_tracker.needsDetection) {
      _tracker.adopt(_detect(frame, game));
      detected++;
    }

    var quad = _tracker.quad;
    if (quad == null) {
      return Step(detected: detected, hash: null, announced: null, confident: false);
    }

    var hash = _hashWith(frame, quad, cardFrame.box);
    if (_tracker.jumped(hash)) {
      // La scène a changé sous le quadrilatère. On ne cherche pas à savoir
      // quoi : la réponse est la même dans tous les cas, redétecter.
      _tracker.adopt(_detect(frame, game));
      detected++;
      quad = _tracker.quad;
      if (quad == null) {
        return Step(detected: 1, hash: null, announced: null, confident: false);
      }
      hash = _hashWith(frame, quad, cardFrame.box);
    }
    _tracker.keep(hash);

    final result = index.search(hash);
    return Step(
      detected: detected,
      hash: hash,
      announced: result.best?.oracleId,
      confident: result.isConfident,
    );
  }
}

CardQuad? _detect(Frame frame, String game) => findCardInLuma(
  frame.luma,
  width: frame.width,
  height: frame.height,
  rowStride: frame.width,
  game: game,
);

ArtHash _hashWith(Frame frame, CardQuad quad, ArtBox box) {
  final art = sampleArtFromLuma(
    frame.luma,
    width: frame.width,
    height: frame.height,
    rowStride: frame.width,
    quad: quad,
    box: box,
  );
  return artHashFromLuma(art, width: 256, height: 190, rowStride: 256);
}

Future<void> main(List<String> args) async {
  final limit = int.tryParse(_option(args, '--cards') ?? '') ?? 4;
  sensorNoise = int.tryParse(_option(args, '--noise') ?? '') ?? sensorNoise;
  final regimeName = _option(args, '--regime') ?? 'ordinaire';
  final regime = regimes.firstWhere(
    (r) => r.name == regimeName,
    orElse: () => regimes[2],
  );

  final root = File.fromUri(Platform.script).parent;
  final setFile = File('${root.path}/framing_set.json');
  if (!setFile.existsSync()) {
    stderr.writeln(
      'tirage absent : ${setFile.path}\n'
      "lancer d'abord : cd api && python -m app.measure.export_framing_set",
    );
    exitCode = 66;
    return;
  }

  final entries = (jsonDecode(setFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>()
      .take(limit)
      .toList();
  final cache = Directory('${root.path}/.framing_cache')
    ..createSync(recursive: true);

  stdout.writeln(
    'Banc de flux — ${entries.length} cartes, régime « ${regime.name} », '
    'bruit ±$sensorNoise',
  );

  final index = _buildIndex(entries);
  final sequence = <Frame>[];
  for (var i = 0; i < entries.length; i++) {
    final card = await _cardImage(entries[i], cache);
    if (card == null) continue;
    final next = i + 1 < entries.length
        ? await _cardImage(entries[i + 1], cache)
        : null;
    sequence.addAll(
      _sequenceFor(entries[i], card, next, entries.elementAtOrNull(i + 1), regime, i),
    );
    stdout.write('  composition ${i + 1}/${entries.length}\r');
  }
  stdout.write('${' ' * 32}\r');
  if (sequence.isEmpty) {
    stderr.writeln('aucune image composée — cache vide et réseau absent ?');
    exitCode = 70;
    return;
  }

  stdout.writeln('${sequence.length} images composées\n');

  // La référence tourne en premier : les deux autres se comparent à elle.
  final reference = _run(DetectEveryFrame(), sequence, index);
  _reportNoiseFloor(sequence, reference);
  _reportQuadJitter(sequence, reference);

  final strategies = <Strategy>[
    DetectPeriodically(5),
    DetectPeriodically(15),
    for (final k in const [2, 4, 6, 8, 12]) TrackUntilJump(k),
    // La synthèse : un seuil de saut voit l'échange, un âge maximal voit la
    // dérive. Aucun des deux ne voit ce que l'autre voit.
    TrackUntilJump(12, maxAge: 3),
    TrackUntilJump(12, maxAge: 5),
    TrackUntilJump(12, maxAge: 10),
  ];

  _header();
  _report('détection', reference, reference, sequence);
  for (final strategy in strategies) {
    _report(strategy.name, _run(strategy, sequence, index), reference, sequence);
  }
}

List<Step> _run(Strategy strategy, List<Frame> sequence, ArtHashIndex index) => [
  for (final frame in sequence)
    strategy.step(frame, index, CardFrame.modern, 'magic'),
];

ArtHashIndex _buildIndex(List<Map<String, dynamic>> entries) {
  // Les vraies empreintes du tirage, plus un remplissage aléatoire pour que la
  // densité de l'index ressemble à celle qu'embarque l'application.
  //
  // **Le remplissage aléatoire flatte tout le monde**, et de la même façon :
  // des empreintes tirées au hasard sont plus éloignées les unes des autres que
  // celles d'un vrai catalogue (`app.measure.art_collisions` mesure 36 % de
  // cartes Magic ayant une voisine sous le seuil). Les annonces à tort sont
  // donc sous-estimées **en valeur absolue** ; leur comparaison d'une stratégie
  // à l'autre, elle, reste juste, et c'est ce que ce banc départage.
  final random = math.Random(20260813);
  final pairs = <({String oracleId, ArtHash hash})>[
    for (final e in entries)
      (oracleId: e['id'] as String, hash: ArtHash.fromHex(e['hash'] as String)),
    for (var i = 0; i < 31600; i++)
      (
        oracleId: 'bourrage-$i',
        hash: ArtHash(
          Uint8List.fromList([
            for (var b = 0; b < hashBytes; b++) random.nextInt(256),
          ]),
        ),
      ),
  ];
  return ArtHashIndex.fromEntries(pairs);
}

/// La séquence jouée pour une carte : posée, qui dérive, retirée, échangée.
List<Frame> _sequenceFor(
  Map<String, dynamic> entry,
  img.Image card,
  img.Image? next,
  Map<String, dynamic>? nextEntry,
  Shot regime,
  int seed,
) {
  final id = entry['id'] as String;
  final frames = <Frame>[];

  void add(img.Image? source, String? truth, Shot shot, String moment, int n) {
    final rng = math.Random(20260813 + seed * 1009 + n * 7);
    final photo = source == null
        ? emptyTable(shot, rng)
        : compose(source, shot, rng);
    frames.add(
      Frame(_toLuma(photo, rng), photo.width, photo.height, truth, moment),
    );
  }

  // 1. Posée : le cadrage ne bouge pas, seul le bruit change.
  for (var n = 0; n < 12; n++) {
    add(card, id, regime, 'posée', n);
  }
  // 2. Échange sur place, **sans blanc avant** : la géométrie reste juste,
  //    seule l'image change. C'est le cas décisif, et il doit suivre
  //    directement une phase où le suivi a un quadrilatère en main —
  //    l'intercaler après un retrait le priverait de tout intérêt, puisque le
  //    suivi aurait déjà lâché prise.
  if (next != null && nextEntry != null) {
    for (var n = 0; n < 12; n++) {
      add(next, nextEntry['id'] as String, regime, 'échange', 100 + n);
    }
  }
  // 3. Dérive : la carte glisse et tourne un peu, image après image. C'est ici
  //    qu'un quadrilatère réutilisé devient faux **sans rien dire** — chaque
  //    pas est trop petit pour déclencher un seuil de saut, et pourtant ils
  //    s'accumulent.
  for (var n = 0; n < 12; n++) {
    add(
      next ?? card,
      (nextEntry ?? entry)['id'] as String,
      regime.moved(
        offset: regime.offset + 0.004 * n,
        rotation: regime.rotation + 0.25 * n,
      ),
      'dérive',
      200 + n,
    );
  }
  // 4. Retrait : plus rien devant l'objectif.
  for (var n = 0; n < 6; n++) {
    add(null, null, regime, 'retrait', 300 + n);
  }
  return frames;
}

/// Plan de luminance, avec le bruit d'un capteur.
///
/// La formule est celle du pipeline (BT.601 en millièmes entiers), et non
/// `img.grayscale` : mesurer dans un espace de luminance que l'empreinte
/// n'emploierait pas reviendrait à mesurer autre chose.
Uint8List _toLuma(img.Image photo, math.Random rng) {
  final out = Uint8List(photo.width * photo.height);
  var i = 0;
  for (var y = 0; y < photo.height; y++) {
    for (var x = 0; x < photo.width; x++) {
      final p = photo.getPixel(x, y);
      final grey =
          (p.r.toInt() * 299 + p.g.toInt() * 587 + p.b.toInt() * 114) ~/ 1000;
      final noise = rng.nextInt(2 * sensorNoise + 1) - sensorNoise;
      out[i++] = (grey + noise).clamp(0, 255);
    }
  }
  return out;
}

/// Le plancher de bruit, et le saut d'un échange — la mesure qui rend K possible.
///
/// **C'est le cœur du banc.** Un seuil de saut n'existe que si les deux
/// distributions sont séparées : ce que fait bouger le bruit d'un capteur doit
/// rester bien en dessous de ce que fait bouger un changement de carte. Sans
/// cette séparation, aucun K ne conviendrait, et le suivi serait à écarter.
void _reportNoiseFloor(List<Frame> sequence, List<Step> reference) {
  final byMoment = <String, List<int>>{};
  for (var i = 1; i < sequence.length; i++) {
    final a = reference[i - 1].hash;
    final b = reference[i].hash;
    if (a == null || b == null) continue;
    // Le premier saut d'un moment est la transition vers lui : c'est
    // précisément ce qu'on veut mesurer pour « échange ».
    final moment = sequence[i].moment == sequence[i - 1].moment
        ? sequence[i].moment
        : 'transition ${sequence[i - 1].moment} -> ${sequence[i].moment}';
    byMoment.putIfAbsent(moment, () => []).add(a.distanceTo(b));
  }

  stdout.writeln("écart d'empreinte d'une image à la suivante, à quadrilatère frais");
  for (final e in byMoment.entries) {
    final values = e.value..sort();
    stdout.writeln(
      '  ${e.key.padRight(34)} '
      'n=${values.length.toString().padLeft(3)}  '
      'médiane ${values[values.length ~/ 2].toString().padLeft(2)}  '
      'max ${values.last.toString().padLeft(2)} bits',
    );
  }
  stdout.writeln('');
}

/// Le tremblement propre à la détection, isolé du bruit du capteur.
///
/// **La question que cette mesure pose.** Sur une carte immobile, l'empreinte
/// de la référence bouge quand même. Deux causes possibles, et elles n'ont pas
/// la même conséquence : le bruit du capteur, que rien ne peut éviter, ou le
/// quadrilatère lui-même, que la détection replace légèrement ailleurs à chaque
/// image. Si c'est la seconde, alors **redétecter à chaque image dégrade la
/// stabilité** au lieu de la garantir, et l'argument en faveur du suivi ne tient
/// plus seulement au coût.
///
/// La méthode gèle le quadrilatère de la première image du moment et rejoue les
/// suivantes avec — tout le reste étant égal, l'écart qui subsiste est le bruit
/// seul.
void _reportQuadJitter(List<Frame> sequence, List<Step> reference) {
  final still = <int>[];
  final frozen = <int>[];
  CardQuad? held;
  ArtHash? heldPrevious;

  for (var i = 1; i < sequence.length; i++) {
    if (sequence[i].moment != 'posée' ||
        sequence[i - 1].moment != 'posée' ||
        sequence[i].truth != sequence[i - 1].truth) {
      held = null;
      heldPrevious = null;
      continue;
    }
    final a = reference[i - 1].hash;
    final b = reference[i].hash;
    if (a != null && b != null) still.add(a.distanceTo(b));

    held ??= _detect(sequence[i - 1], 'magic');
    if (held == null) continue;
    final current = _hashWith(sequence[i], held, CardFrame.modern.box);
    if (heldPrevious != null) frozen.add(current.distanceTo(heldPrevious));
    heldPrevious = current;
  }

  String summary(List<int> values) {
    if (values.isEmpty) return 'aucune mesure';
    final sorted = [...values]..sort();
    return 'médiane ${sorted[sorted.length ~/ 2]}  max ${sorted.last} bits';
  }

  stdout.writeln('carte immobile : ce qui fait bouger l\'empreinte');
  stdout.writeln('  quadrilatère redétecté à chaque image  ${summary(still)}');
  stdout.writeln('  quadrilatère gelé (bruit du capteur seul)  ${summary(frozen)}');
  stdout.writeln('');
}

void _header() {
  stdout.writeln(
    '${'stratégie'.padRight(14)}'
    '${'détections'.padLeft(11)}'
    '${'coût/image'.padLeft(12)}'
    '${'écart p50'.padLeft(11)}'
    '${'écart max'.padLeft(11)}'
    '${'dérive max'.padLeft(12)}'
    '${'échange'.padLeft(9)}'
    '${'perdues'.padLeft(9)}'
    '${'à tort'.padLeft(8)}'
    '${'inédites'.padLeft(10)}',
  );
}

/// Combien d'images pour qu'une stratégie annonce la carte qui vient d'arriver.
///
/// **C'est le prix du suivi, et il se compte en images.** Une stratégie qui ne
/// redétecte jamais finirait par annoncer la carte précédente indéfiniment ;
/// une qui redétecte à chaque image la voit tout de suite. Entre les deux, ce
/// nombre dit combien de temps l'écran montrerait la mauvaise carte.
///
/// Rend `-1` quand la carte n'est jamais annoncée avant la fin du moment.
List<int> _swapLatencies(List<Step> steps, List<Frame> sequence) {
  final out = <int>[];
  for (var i = 1; i < sequence.length; i++) {
    final arriving = sequence[i].truth;
    if (arriving == null || arriving == sequence[i - 1].truth) continue;
    if (sequence[i].moment != 'échange') continue;
    var seen = -1;
    for (var j = i; j < sequence.length && sequence[j].truth == arriving; j++) {
      if (steps[j].confident && steps[j].announced == arriving) {
        seen = j - i;
        break;
      }
    }
    out.add(seen);
  }
  return out;
}

/// Une ligne de rapport, comparée à la référence.
void _report(
  String name,
  List<Step> steps,
  List<Step> reference,
  List<Frame> sequence,
) {
  final detections = steps.fold<int>(0, (n, s) => n + s.detected);
  final cost =
      sampleHashSearchMillis + detectionMillis * detections / steps.length;

  final gaps = <int>[];
  var driftMax = 0;
  var wrong = 0;
  var unseen = 0;
  var lost = 0;
  for (var i = 0; i < steps.length; i++) {
    // **La dérive ne coûte pas des erreurs, elle coûte des reconnaissances.**
    // Une empreinte trop éloignée ne ressemble plus à rien : l'index se tait,
    // ce qui est le comportement voulu. La mesurer en « annonces à tort »
    // rendrait donc zéro et laisserait croire que la dérive est gratuite.
    if (reference[i].confident &&
        reference[i].announced == sequence[i].truth &&
        !(steps[i].confident && steps[i].announced == sequence[i].truth)) {
      lost++;
    }
    final mine = steps[i].hash;
    final theirs = reference[i].hash;
    if (mine != null && theirs != null) {
      final gap = mine.distanceTo(theirs);
      gaps.add(gap);
      // La dérive est mesurée à part : c'est le moment où un quadrilatère
      // réutilisé se périme sans qu'aucun saut ne le signale, et donc le seul
      // endroit où le maximum veut dire quelque chose de précis.
      if (sequence[i].moment == 'dérive' && gap > driftMax) driftMax = gap;
    }
    if (!steps[i].confident) continue;
    // Une annonce est fausse si elle ne désigne pas la carte réellement
    // présente — y compris quand il n'y en a aucune.
    if (steps[i].announced != sequence[i].truth) wrong++;
    // Et « inédite » si la référence, sur la même image, n'annonçait pas cela :
    // c'est le risque **propre** à la stratégie, celui qu'elle ajoute.
    if (!reference[i].confident ||
        reference[i].announced != steps[i].announced) {
      unseen++;
    }
  }
  gaps.sort();

  final latencies = _swapLatencies(steps, sequence);
  final missed = latencies.where((l) => l < 0).length;
  final seen = latencies.where((l) => l >= 0).toList()..sort();
  final swap = seen.isEmpty
      ? 'jamais'
      : '${seen[seen.length ~/ 2]}${missed > 0 ? ' (+$missed)' : ''}';

  stdout.writeln(
    '${name.padRight(14)}'
    '${detections.toString().padLeft(11)}'
    '${'${cost.toStringAsFixed(1)} ms'.padLeft(12)}'
    '${(gaps.isEmpty ? '-' : gaps[gaps.length ~/ 2].toString()).padLeft(11)}'
    '${(gaps.isEmpty ? '-' : gaps.last.toString()).padLeft(11)}'
    '${driftMax.toString().padLeft(12)}'
    '${swap.padLeft(9)}'
    '${lost.toString().padLeft(9)}'
    '${wrong.toString().padLeft(8)}'
    '${unseen.toString().padLeft(10)}',
  );
}

/// Carte entière, depuis le cache disque ou depuis Scryfall.
Future<img.Image?> _cardImage(
  Map<String, dynamic> entry,
  Directory cache,
) async {
  final id = entry['id'] as String;
  final file = File('${cache.path}/$id.jpg');
  if (file.existsSync()) {
    return img.decodeImage(file.readAsBytesSync());
  }
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(entry['url'] as String));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'DeckHand/1.0 (banc de mesure; contact via github.com/Lelio88/DeckHand)',
    );
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final bytes = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    file.writeAsBytesSync(bytes.takeBytes());
    return img.decodeImage(file.readAsBytesSync());
  } on Exception {
    return null;
  } finally {
    client.close();
  }
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
