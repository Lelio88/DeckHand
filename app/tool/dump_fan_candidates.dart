/// Imprime les lignes de l'éventail mesuré qui survivent au filtrage.
///
/// **Pourquoi cet outil plutôt qu'un filtre réécrit côté Python.** Régler le
/// seuil de score exige de comparer des candidats, or « candidat » est défini
/// par du code Dart — nettoyage des parasites, lignes de type, mots-clés,
/// longueurs. Le réimplémenter ailleurs ferait mesurer autre chose que ce que
/// l'application exécute : une première tentative sans filtre comptait
/// « Éphémere → Ephemerate » comme une fausse carte, alors que le filtre des
/// lignes de type l'écarte bien avant la recherche.
///
/// Usage : dart run tool/dump_fan_candidates.dart
library;

import 'dart:convert';
import 'dart:io';

import '../test/src/features/scan/measured_fan.dart';
import 'package:deckhand/src/features/scan/domain/spread_names.dart';

void main() {
  final candidates = spreadNameCandidates(measuredFan);
  stdout.writeln(
    jsonEncode({
      'lines': measuredFan.length,
      'candidates': candidates.map((c) => c.text).toList(),
      'truth': fanTruth,
    }),
  );
}
