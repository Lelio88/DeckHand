/// Le seuil de score, éprouvé sur une photo réelle plutôt qu'à vue.
///
/// **Pourquoi ces tests portent sur des scores figés.** Le seuil décide de ce
/// qu'on retient dans un catalogue où *n'importe quelle* ligne trouve quelque
/// chose. Le régler sur des exemples inventés reviendrait à choisir la réponse
/// avant la question : ce sont les scores que l'appareil obtient réellement qui
/// disent où la trouvaille cesse et où le hasard commence.
///
/// La fixture vient d'un scan de dix-sept cartes posées à plat, comptées sur la
/// table. Le nombre de cartes est donc mesurable des deux côtés — ce qu'on
/// trouve, et ce qu'on rate.
library;

import 'package:deckhand/src/features/scan/domain/spread_names.dart';
import 'package:flutter_test/flutter_test.dart';

import 'measured_flat.dart';

/// Rejoue les deux garde-fous de `recogniseSpread` sur les correspondances
/// mesurées, et rend les cartes distinctes retenues.
Set<String> keptAt(double threshold) {
  final kept = <String>{};
  for (final match in measuredFlatMatches) {
    if (match.score < threshold) continue;
    if (!isPlausibleMatch(match.read, match.matched)) continue;
    kept.add(match.matched);
  }
  return kept;
}

void main() {
  test('le seuil en vigueur retrouve les dix-sept cartes de la photo', () {
    final kept = keptAt(spreadScoreThreshold);

    expect(
      kept.length,
      flatTruthCount,
      reason:
          'la photo portait dix-sept cartes, comptées sur la table ; '
          'toute autre valeur signale une carte ratée ou une carte inventée',
    );
  });

  test('les deux cartes gagnées sont des lectures mutilées, pas du hasard', () {
    // **Ce que l'ancien seuil de 0,72 jetait.** L'appareil confond des lettres
    // sur les noms courts en capitales : « Agents du S.H.LE.LD. » lit L pour I,
    // « Alennifer Walters » lit Al pour J. Les deux correspondances sont
    // exactes ; seul leur score en souffrait.
    final kept = keptAt(spreadScoreThreshold);

    expect(kept, contains('Agents du S.H.I.E.L.D.'));
    expect(kept, contains('Jennifer Walters'));
  });

  test('remonter le seuil à 0,72 reperd exactement ces deux cartes', () {
    // Contre-épreuve : sans elle, le test précédent pourrait passer parce que
    // ces cartes arrivent par un autre chemin, et non grâce au seuil.
    final strict = keptAt(0.72);

    expect(strict.length, flatTruthCount - 2);
    expect(strict, isNot(contains('Agents du S.H.I.E.L.D.')));
    expect(strict, isNot(contains('Jennifer Walters')));
  });

  test('descendre plus bas invente des cartes', () {
    // **La borne inférieure est mesurée, pas supposée.** À 0,53, la ligne
    // « Vieilance » — le mot-clé *vigilance* mal lu sur une carte quelconque —
    // trouve la carte *Vigilance*, qui existe — elle marque 0,5385, et le
    // seuil retenu est le dernier cran qui la refuse.
    expect(
      keptAt(0.53).length,
      greaterThan(flatTruthCount),
      reason:
          'sous le seuil retenu, des lignes de règles deviennent des cartes',
    );
  });

  test('la règle de longueur reste ce qui écarte les fragments', () {
    // Le seuil abaissé ne doit pas laisser passer les fragments : c'est la
    // longueur relative, et non le score, qui les retient. « Lancer » marque
    // 0,91 contre *Lancer de rat* — largement au-dessus du seuil.
    final byLengthOnly = measuredFlatMatches
        .where((m) => m.score >= spreadScoreThreshold)
        .where((m) => !isPlausibleMatch(m.read, m.matched))
        .map((m) => m.matched)
        .toSet();

    expect(
      byLengthOnly,
      isNotEmpty,
      reason:
          'si plus rien ne tombe sur la longueur, le garde-fou est devenu '
          'inopérant et les fragments passent par le score seul',
    );
    expect(keptAt(spreadScoreThreshold).intersection(byLengthOnly), isEmpty);
  });
}
