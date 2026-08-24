/// Pourquoi le contour de la carte perd contre sa bordure ornée (#8).
///
/// **La question que ce banc tranche.** Mesuré, la détection retient souvent le
/// cadre ornemental intérieur plutôt que le bord extérieur de la carte, et
/// `hough_probe` a montré que les droites du bord extérieur *existent* — plus
/// faibles, mais présentes. Trois causes restaient possibles, et elles
/// n'appellent pas le même travail :
///
/// 1. les droites du vrai contour ne sont pas retenues comme dominantes ;
/// 2. elles le sont, mais ne s'apparient jamais en quadrilatère ;
/// 3. elles s'apparient, et un garde-fou écarte le quadrilatère.
///
/// Ce banc reproduit **les conditions d'appariement de `bestQuad`** — écart
/// d'angle, écart de rho, perpendicularité — sur les droites que `dominantLines`
/// rend réellement, et dit laquelle des trois s'applique.
///
/// **La vérité vient de Python, pas d'ici.** Le contour de chaque carte est lu
/// dans `api/.cache/plafond-mesure.json`, où `plafond_empreinte` l'a écrit après
/// l'avoir situé par corrélation. Un banc Dart qui se donnerait sa propre
/// référence ne mesurerait que sa cohérence.
///
/// **Ce que cette sonde ne peut pas dire, et il faut le savoir avant de la
/// croire.** Le contour vrai est reconstruit depuis la fenêtre d'illustration,
/// et le calibrage sur témoin montre qu'il faut lui accorder **20 pixels** de
/// tolérance à la résolution d'analyse. Or le bord de la carte et sa bordure
/// ornée n'y sont distants que de huit. La sonde sait donc dire « une droite
/// existe près du contour » — elle **ne sait pas** dire laquelle des deux. Le
/// verdict « absente » (plus de 20 px) est solide ; le verdict « appariée » ne
/// prouve pas que c'est le bord extérieur qui était disponible.
///
/// Usage :
///
///     cd app && dart run tool/assemblage.dart
///     cd app && dart run tool/assemblage.dart --photo IMG_20260822_191448222.jpg
library;

// Banc lancé à la main : sa sortie EST son résultat.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:deckhand/src/features/scan/domain/card_edges.dart';
import 'package:image/image.dart' as img;

const String _mesure = '../api/.cache/plafond-mesure.json';
const String _photos = '../../.deckhand-bench/photos/carte-seule';

/// Les seuils d'appariement de `bestQuad`, recopiés pour être appliqués ici.
///
/// **Recopiés, donc susceptibles de dériver** — `bestQuad` les porte en dur dans
/// sa boucle, sans les exposer. Si elle change les siens, ce banc mesurera un
/// appariement qui n'existe plus, en silence. C'est la limite connue de cette
/// sonde ; la lever demanderait d'extraire ces trois conditions en fonction
/// nommée, ce qui touche le code le moins tolérant à la dérive du projet.
const double ecartAngleMax = 0.20;
const double ecartRhoMin = 20;
const double perpendiculariteMax = 0.25;

/// Tolérance pour reconnaître une droite du vrai contour parmi les dominantes.
///
/// **Calibrée sur un témoin, jamais choisie.** Le contour vrai est reconstruit
/// depuis la fenêtre d'illustration, et cette reconstruction extrapole : le bord
/// bas de la carte se déduit d'une fenêtre qui s'arrête à 55 % de sa hauteur,
/// si bien qu'une erreur de fenêtre s'y amplifie. Une tolérance trop serrée fait
/// donc conclure « droite absente » là où elle est présente — mesuré, 5 photos
/// sur 12 dont le contour de production est pourtant juste à moins de 5 %.
///
/// Le témoin est précisément ce groupe-là : quand la production a trouvé le bon
/// contour, ses quatre droites **existent forcément** parmi les dominantes,
/// puisqu'elle l'en a bâti. La tolérance retenue est la plus petite qui n'y
/// laisse aucun faux manquant.
const double toleranceAngle = 0.10; // ~6°

/// Écart de contour en deçà duquel la production a manifestement trouvé la
/// carte — donc en deçà duquel ses droites doivent être trouvables.
const double contourJuste = 0.05;

/// Une droite du contour vrai, exprimée comme `bestQuad` les manipule.
typedef Bord = ({double theta, double rho, String nom});

/// Les quatre côtés d'un quadrilatère, en coordonnées polaires.
///
/// `rho = x·cos(theta) + y·sin(theta)`, `theta` dans [0, π) — la convention de
/// `EdgeLine`, reprise à la lettre pour que la comparaison ait un sens.
List<Bord> bordsDe(List<List<double>> coins) {
  const noms = ['haut', 'droit', 'bas', 'gauche'];
  final bords = <Bord>[];
  for (var n = 0; n < 4; n++) {
    final p = coins[n];
    final q = coins[(n + 1) % 4];
    var theta = math.atan2(q[0] - p[0], -(q[1] - p[1]));
    var rho = p[0] * math.cos(theta) + p[1] * math.sin(theta);
    if (theta < 0) {
      theta += math.pi;
      rho = -rho;
    }
    if (theta >= math.pi) {
      theta -= math.pi;
      rho = -rho;
    }
    bords.add((theta: theta, rho: rho, nom: noms[n]));
  }
  return bords;
}

double _ecartAngle(double a, double b) {
  var d = (a - b).abs();
  if (d > math.pi / 2) d = math.pi - d;
  return d;
}

/// La droite dominante qui porte ce bord, s'il y en a une.
({EdgeLine ligne, int rang})? trouver(
  List<EdgeLine> lignes,
  Bord bord,
  double toleranceRho,
) {
  ({EdgeLine ligne, int rang})? meilleur;
  var pire = double.infinity;
  for (var i = 0; i < lignes.length; i++) {
    final l = lignes[i];
    if (_ecartAngle(l.theta, bord.theta) > toleranceAngle) continue;
    // Deux écritures de la même droite : theta proche de 0 et de π inversent rho.
    final memeSens = (l.theta - bord.theta).abs() < math.pi / 2;
    final rho = memeSens ? l.rho : -l.rho;
    final ecart = (rho - bord.rho).abs();
    if (ecart > toleranceRho) continue;
    // **La plus proche, pas la première.** Deux droites parallèles voisines —
    // le bord de la carte et sa bordure ornée — tombent toutes deux dans la
    // tolérance ; retenir la première venue ferait dire « trouvée » en
    // désignant l'autre.
    if (ecart < pire) {
      pire = ecart;
      meilleur = (ligne: l, rang: i);
    }
  }
  return meilleur;
}

/// La convention polaire de `bordsDe` est-elle celle d'`EdgeLine` ?
///
/// **Un témoin, pas un ornement.** Si les deux divergeaient, aucune droite ne
/// serait jamais reconnue et le banc conclurait « contour absent des dominantes »
/// pour toutes les photos — un verdict faux, et parfaitement crédible.
void verifierConvention() {
  const coins = [
    [10.0, 20.0],
    [110.0, 20.0],
    [110.0, 160.0],
    [10.0, 160.0],
  ];
  for (final bord in bordsDe(coins)) {
    // Le milieu de chaque côté doit satisfaire rho = x·cos(theta) + y·sin(theta).
    final n = ['haut', 'droit', 'bas', 'gauche'].indexOf(bord.nom);
    final p = coins[n], q = coins[(n + 1) % 4];
    final mx = (p[0] + q[0]) / 2, my = (p[1] + q[1]) / 2;
    final ecart = (mx * math.cos(bord.theta) + my * math.sin(bord.theta) -
            bord.rho)
        .abs();
    if (ecart > 1e-9 || bord.theta < 0 || bord.theta >= math.pi) {
      stderr.writeln(
        'convention polaire fausse sur le côté ${bord.nom} : '
        'theta ${bord.theta}, rho ${bord.rho}, écart $ecart',
      );
      exit(70);
    }
  }
}

String? _option(List<String> args, String nom) {
  final i = args.indexOf(nom);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

void main(List<String> args) {
  verifierConvention();
  final mesure = File(_mesure);
  if (!mesure.existsSync()) {
    stderr.writeln(
      'mesure introuvable : $_mesure\n'
      'Jouer d\'abord : cd api && .venv/Scripts/python -m '
      'app.measure.plafond_empreinte',
    );
    exit(64);
  }
  final lignes =
      (jsonDecode(mesure.readAsStringSync()) as List).cast<Map<String, Object?>>();
  final vise = _option(args, '--photo');

  print(
    'Les droites du vrai contour sont-elles trouvees, et s\'apparient-elles ?\n'
    'Seuils de bestQuad : angle <= $ecartAngleMax, |rho| >= $ecartRhoMin, '
    'perpendicularite <= $perpendiculariteMax\n',
  );

  // Les droites d'une photo se calculent une fois ; le balayage de tolérance
  // les rejoue, pas la transformée.
  final champs = <String,
      ({List<EdgeLine> lignes, List<EdgeLine> larges, List<Bord> bords, double coins})>{};

  for (final l in lignes) {
    final nom = l['fichier'] as String;
    if (vise != null && nom != vise) continue;
    final vraie = (l['carte_vraie'] as List?)?.cast<List>();
    if (vraie == null || l['verite_trouvee'] != true) continue;

    final fichier = File('$_photos/$nom');
    if (!fichier.existsSync()) continue;
    final photo = img.decodeImage(fichier.readAsBytesSync());
    if (photo == null) continue;

    // Les mêmes conditions que `findCardByEdges` : même réduction, mêmes
    // droites. Sans cela on mesurerait un autre champ que celui de production.
    final echelle = photo.width > analysisWidth
        ? photo.width / analysisWidth
        : 1.0;
    final petite = echelle > 1
        ? boxReduce(
            photo,
            analysisWidth,
            (photo.height / echelle).round().clamp(1, photo.height),
          )
        : photo;
    final champ = dominantLines(petite, maxLines: defaultMaxLines);
    // Le meme champ, budget quadruple : sert a distinguer « le bord n'est pas
    // dans les droites retenues » de « le bord n'existe pas comme droite ».
    final large = dominantLines(petite, maxLines: defaultMaxLines * 4);

    champs[nom] = (
      lignes: champ.lines,
      larges: large.lines,
      bords: bordsDe([
        for (final p in vraie) [(p[0] as num) / echelle, (p[1] as num) / echelle],
      ]),
      coins: (l['coins'] as num?)?.toDouble() ?? double.infinity,
    );
  }

  // --- Calibrage sur le témoin -------------------------------------------
  final temoin = champs.entries.where((e) => e.value.coins <= contourJuste);
  print(
    'Calibrage — ${temoin.length} photos dont le contour de production est '
    'juste a moins de ${(100 * contourJuste).round()} % : leurs quatre '
    'droites existent forcement, la production les en a baties.\n',
  );
  var retenue = double.nan;
  for (final tol in [4.0, 6.0, 8.0, 12.0, 16.0, 20.0, 25.0, 30.0]) {
    final rates = temoin
        .where((e) => e.value.bords.any((b) => trouver(e.value.lignes, b, tol) == null))
        .length;
    print('  tolerance rho ${tol.toStringAsFixed(0).padLeft(3)} px : '
        '$rates faux manquant(s) sur ${temoin.length}');
    if (rates == 0 && retenue.isNaN) retenue = tol;
  }
  if (retenue.isNaN) {
    print('\nAucune tolerance ne blanchit le temoin : la reconstruction du '
        'contour est trop imprecise pour cette mesure.');
    return;
  }
  print('\nTolerance retenue : ${retenue.toStringAsFixed(0)} px — la plus '
      'petite qui ne laisse aucun faux manquant.\n');

  // --- La mesure ----------------------------------------------------------
  var absentes = 0;
  var apparieesKo = 0;
  var apparieesOk = 0;

  for (final e in champs.entries) {
    final nom = e.key;
    final bords = e.value.bords;
    final lignesDom = e.value.lignes;
    final trouves = [for (final b in bords) trouver(lignesDom, b, retenue)];

    final manquants = [
      for (var n = 0; n < 4; n++)
        if (trouves[n] == null) bords[n].nom,
    ];

    final buffer = StringBuffer('  ${nom.substring(13, 22)}  ');
    if (manquants.isNotEmpty) {
      absentes++;
      // **Absente du budget, ou absente tout court ?** `dominantLines` ne garde
      // qu'un nombre fixé de droites, réparties par famille d'angle. Une carte
      // Magic porte beaucoup d'horizontales internes — bandeau de titre, cadre
      // d'illustration, ligne de type, bloc de texte — et peu de verticales : si
      // le budget est en cause, élargir doit faire réapparaître le bord.
      final larges = e.value.larges;
      final revient = <String>[];
      for (var n = 0; n < 4; n++) {
        if (trouves[n] != null) continue;
        final t = trouver(larges, bords[n], retenue);
        if (t != null) revient.add('${bords[n].nom}@${t.rang}');
      }
      buffer.write('ABSENTES : ${manquants.join(", ")} '
          '(${lignesDom.length} dominantes)');
      buffer.write(revient.isEmpty
          ? '  — aucune ne revient a ${larges.length} droites'
          : '  — revient a ${larges.length} : ${revient.join(", ")}');
      print(buffer);
      continue;
    }

    // Les quatre droites existent : s'apparient-elles comme `bestQuad` l'exige ?
    final h = trouves[0]!.ligne, b = trouves[2]!.ligne;
    final d = trouves[1]!.ligne, g = trouves[3]!.ligne;
    final refus = <String>[];
    if (_ecartAngle(h.theta, b.theta) > ecartAngleMax) {
      refus.add('haut/bas pas paralleles');
    }
    if ((h.rho - b.rho).abs() < ecartRhoMin) refus.add('haut/bas trop proches');
    if (_ecartAngle(g.theta, d.theta) > ecartAngleMax) {
      refus.add('gauche/droit pas paralleles');
    }
    if ((g.rho - d.rho).abs() < ecartRhoMin) {
      refus.add('gauche/droit trop proches');
    }
    final entre = _ecartAngle(h.theta, g.theta);
    if ((entre - math.pi / 2).abs() > perpendiculariteMax) {
      refus.add('paires pas perpendiculaires');
    }

    final rangs = [for (final t in trouves) t!.rang].join('/');
    final votes = [for (final t in trouves) t!.ligne.votes].join('/');
    final etat = e.value.coins <= contourJuste ? 'temoin' : 'a corriger';
    if (refus.isEmpty) {
      apparieesOk++;
      buffer.write('appariees, rangs $rangs votes $votes  [$etat]');
    } else {
      apparieesKo++;
      buffer.write('APPARIEMENT REFUSE : ${refus.join(", ")} '
          '(rangs $rangs, votes $votes)  [$etat]');
    }
    print(buffer);
  }

  print(
    '\n${champs.length} photos.\n'
    '  $absentes : au moins une droite du contour absente des dominantes\n'
    '  $apparieesKo : droites presentes, appariement refuse\n'
    '  $apparieesOk : droites presentes et appariees — un garde-fou aval decide',
  );
}
