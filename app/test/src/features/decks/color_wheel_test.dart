/// Tests de la roue chromatique.
///
/// **Ce qui se vérifie ici est la sémantique du filtre, pas son dessin.** Cinq
/// pastilles posaient une question ambiguë — « des decks rouges » ou
/// « uniquement rouges » ? — et ne permettaient pas de dire « du rouge, mais pas
/// de bleu ». Les trois états doivent donc s'atteindre par appuis successifs, et
/// la phrase du bas doit dire ce que le filtre demande vraiment.
library;

import 'package:deckhand/src/features/decks/domain/mana_color.dart';
import 'package:deckhand/src/features/decks/presentation/color_wheel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

/// Repère une couleur de la roue par son nom.
///
/// **La lettre a cédé la place au symbole imprimé**, et une image ne se trouve
/// pas par son texte. La sémantique reste le repère juste : c'est aussi par
/// elle qu'un lecteur d'écran désigne la pastille.
Finder colorFace(String symbol) => find.bySemanticsLabel(
  RegExp('^${manaColors.firstWhere((c) => c.symbol == symbol).label} —'),
);

/// Ouvre la roue et rend ce qu'elle produit après [taps] appuis sur [symbol].
Future<(Set<String>, Set<String>)?> pumpWheel(
  WidgetTester tester, {
  required String symbol,
  int taps = 1,
  bool apply = true,
}) async {
  (Set<String>, Set<String>)? result;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ColorWheelButton(
            wanted: const {},
            banned: const {},
            onChanged: (w, b) => result = (w, b),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.byType(ColorWheelButton));
  await tester.pumpAndSettle();

  // La position est relevée une fois : le libellé sémantique porte l'état
  // choisi, et la pastille ne se retrouverait plus sous le même nom au
  // deuxième appui.
  final centre = tester.getCenter(colorFace(symbol));
  for (var i = 0; i < taps; i++) {
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
  }

  if (apply) {
    await tester.tap(find.text('Appliquer'));
    await tester.pumpAndSettle();
  }
  return result;
}

void main() {
  testWidgets('un appui veut la couleur', (tester) async {
    // Les champs se comparent un à un : l'égalité d'un enregistrement portant
    // des ensembles est celle des instances, pas du contenu.
    final result = await pumpWheel(tester, symbol: 'R');
    expect(result?.$1, {'R'});
    expect(result?.$2, isEmpty);
  });

  testWidgets('deux appuis la bannissent', (tester) async {
    // C'est le geste demandé : une pression pour vouloir, deux pour refuser,
    // sans second contrôle à côté ni mode à choisir avant.
    final result = await pumpWheel(tester, symbol: 'R', taps: 2, apply: false);
    expect(result, isNull, reason: 'rien n\'est appliqué sans validation');
  });

  testWidgets('trois appuis reviennent au départ', (tester) async {
    final result = await pumpWheel(tester, symbol: 'R', taps: 3);
    expect(result?.$1, isEmpty);
    expect(result?.$2, isEmpty);
  });

  testWidgets('deux appuis puis validation bannissent', (tester) async {
    final result = await pumpWheel(tester, symbol: 'R', taps: 2);
    expect(result?.$1, isEmpty);
    expect(result?.$2, {'R'});
  });

  testWidgets('les pastilles portent le symbole imprimé, pas une lettre', (
    tester,
  ) async {
    // « W » ne veut rien dire à qui regarde ses cartes : c'est le symbole du
    // mana qui y est imprimé, et celui que le joueur reconnaît sans lire.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ColorWheelButton(
              wanted: const {},
              banned: const {},
              onChanged: _ignore,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ColorWheelButton));
    await tester.pumpAndSettle();

    expect(find.byType(SvgPicture), findsNWidgets(5));
    for (final letter in ['W', 'U', 'B', 'R', 'G']) {
      expect(
        find.text(letter),
        findsNothing,
        reason: 'la lettre $letter doit avoir cédé la place à son symbole',
      );
    }
  });

  testWidgets('la phrase dit ce que le filtre demande', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ColorWheelButton(
              wanted: const {'R'},
              banned: const {'U'},
              onChanged: _ignore,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ColorWheelButton));
    await tester.pumpAndSettle();

    // Sans phrase, la forme seule laisserait deviner si le rouge est voulu ou
    // seulement autorisé.
    expect(find.text('Decks contenant rouge, sans bleu'), findsOneWidget);
  });

  testWidgets('les cinq couleurs sont dans l\'ordre du jeu', (tester) async {
    // WUBRG, celui du dos des cartes : un joueur y lit les alliances sans
    // réfléchir, et le pentagone perd tout sens dans un autre ordre.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ColorWheelButton(
              wanted: const {},
              banned: const {},
              onChanged: _ignore,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ColorWheelButton));
    await tester.pumpAndSettle();

    final centres = [
      for (final s in ['W', 'U', 'B', 'R', 'G']) tester.getCenter(colorFace(s)),
    ];
    // Le blanc au sommet, puis le sens horaire : chaque couleur est plus basse
    // ou plus à droite que la précédente sur la moitié haute.
    expect(centres[0].dy, lessThan(centres[1].dy));
    expect(centres[1].dx, greaterThan(centres[0].dx));
    expect(centres[4].dx, lessThan(centres[0].dx));
  });
}

void _ignore(Set<String> _, Set<String> _) {}
