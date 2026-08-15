/// La rotation d'une carte couchée dans une case de classeur.
///
/// **Ce que ces tests protègent, et ce qui l'a rendu nécessaire.** Une case de
/// classeur est debout (0,72 de large pour 1 de haut) ; une carte couchée fait
/// 1,4. `BoxFit.cover` y jetait les deux tiers de la largeur, et ce qui restait
/// était moitié illustration moitié pavé de texte — vérifié en composant une
/// page depuis les images réellement servies, pour Riftbound comme pour Wankul.
///
/// **L'orientation se lit sur l'image, jamais sur un champ.** C'est ce qui règle
/// les deux jeux du même geste, et ce qui interdit à la décision de se
/// désynchroniser de ce qu'on affiche : un `layout` en base peut mentir, une
/// image non.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:deckhand/src/common/card_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un PNG de 8 × 4 — la forme d'un Terrain ou d'un champ de bataille.
final Uint8List _couchee = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAIAAAA8r+mnAAAAFUlEQVR42mM8oaHBgA0wMeAApEsA'
  'AG3EASCmem8OAAAAAElFTkSuQmCC',
);

/// Un PNG de 4 × 8 — la forme de l'immense majorité des cartes.
final Uint8List _debout = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAICAIAAABRUclSAAAAFElEQVR42mM8oaHBAANMDEiAuhwA'
  'c9gBKI0x1AoAAAAASUVORK5CYII=',
);

/// Décode l'image avant de monter le widget.
///
/// Le décodage est asynchrone et `pumpWidget` ne le laisse pas se faire ; on le
/// force donc dans `runAsync`, après quoi le fournisseur répond depuis le cache
/// de Flutter — c'est-à-dire de façon synchrone, comme pour une carte déjà vue.
Future<ImageProvider<Object>> _prechargee(
  WidgetTester tester,
  Uint8List bytes,
) async {
  final provider = MemoryImage(bytes);
  await tester.runAsync(() async {
    final pret = Completer<void>();
    provider
        .resolve(ImageConfiguration.empty)
        .addListener(
          ImageStreamListener((_, _) {
            if (!pret.isCompleted) pret.complete();
          }),
        );
    await pret.future;
  });
  return provider;
}

Future<void> _monter(WidgetTester tester, ImageProvider<Object> probe) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 100,
          height: 139, // les proportions d'une case, 63 × 88
          child: UprightInCell(
            probe: probe,
            child: const ColoredBox(key: Key('contenu'), color: Colors.blue),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('une carte couchée est tournée pour remplir la case', (
    tester,
  ) async {
    await _monter(tester, await _prechargee(tester, _couchee));

    final boite = tester.widget<RotatedBox>(find.byType(RotatedBox));
    expect(boite.quarterTurns, UprightInCell.quarterTurns);
  });

  testWidgets('le quart de tour est anti-horaire, comme la source', (
    tester,
  ) async {
    // Le Wankuldex tourne ainsi ses propres vignettes de Terrain : le texte se
    // lit de bas en haut, et la case reproduit ce à quoi l'utilisateur est
    // habitué. `RotatedBox` compte dans le sens horaire, d'où 3 et non 1.
    expect(UprightInCell.quarterTurns, 3);
  });

  testWidgets('une carte debout n\'est pas touchée', (tester) async {
    await _monter(tester, await _prechargee(tester, _debout));

    expect(find.byType(RotatedBox), findsNothing);
    expect(find.byKey(const Key('contenu')), findsOneWidget);
  });

  testWidgets('la case tournée garde la place qu\'on lui donne', (
    tester,
  ) async {
    // `RotatedBox` tourne pendant la mise en page : il échange les contraintes
    // de l'enfant, mais rend au parent la taille qu'il attendait. Sans quoi la
    // grille du classeur se recomposerait autour d'un Terrain.
    await _monter(tester, await _prechargee(tester, _couchee));

    expect(tester.getSize(find.byType(RotatedBox)), const Size(100, 139));
    // L'enfant, lui, a bien reçu une boîte couchée.
    expect(tester.getSize(find.byKey(const Key('contenu'))), const Size(139, 100));
  });

  testWidgets('une sonde qui ne répond pas laisse la carte droite', (
    tester,
  ) async {
    // C'est l'état d'avant : rien ne se casse, et la grande image s'affichera
    // peut-être quand même.
    await _monter(tester, MemoryImage(Uint8List.fromList([0, 1, 2, 3])));

    expect(find.byType(RotatedBox), findsNothing);
  });
}
