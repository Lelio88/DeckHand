/// Le cadre dessiné doit être là où la carte est **à l'écran** (#8).
///
/// **Ce que ce test protège.** Les coins arrivent dans le repère du capteur,
/// qui livre son image en paysage quel que soit le sens du téléphone ; l'écran
/// de scan, lui, est verrouillé en portrait. Un tracé qui oublierait cette
/// rotation entourerait le vide avec assurance — et l'utilisateur corrigerait
/// un geste qui n'a rien à se reprocher.
library;

import 'dart:ui';

import 'package:deckhand/src/features/scan/presentation/quad_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

({double x, double y}) _redresse(int turns) => QuadOverlay(
  corners: const [],
  quarterTurns: turns,
).redresse((x: 0.1, y: 0.2));

void main() {
  test('sans rotation, les coins ne bougent pas', () {
    final p = _redresse(0);
    expect(p.x, closeTo(0.1, 1e-9));
    expect(p.y, closeTo(0.2, 1e-9));
  });

  test('un quart de tour horaire redresse le capteur', () {
    // C'est le cas de la quasi-totalité des Android : le buffer arrive en
    // paysage, l'écran est en portrait.
    final p = _redresse(1);
    expect(p.x, closeTo(0.8, 1e-9));
    expect(p.y, closeTo(0.1, 1e-9));
  });

  test('sans coins, le peintre ne dessine rien plutôt que n’importe quoi', () {
    const overlay = QuadOverlay(corners: null, quarterTurns: 1);
    final recorder = PictureRecorder();

    expect(
      () => overlay.paint(Canvas(recorder), const Size(100, 100)),
      returnsNormally,
    );
  });

  test('un quadrilatère incomplet est ignoré', () {
    // Trois coins ne font pas un cadre : mieux vaut ne rien montrer qu'une
    // forme qui n'a jamais été détectée.
    const overlay = QuadOverlay(
      corners: [(x: 0.1, y: 0.1), (x: 0.9, y: 0.1)],
      quarterTurns: 0,
    );
    final recorder = PictureRecorder();

    expect(
      () => overlay.paint(Canvas(recorder), const Size(100, 100)),
      returnsNormally,
    );
  });
}
