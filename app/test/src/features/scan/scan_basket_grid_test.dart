/// Tests de la grille des cartes retenues (#8).
///
/// **Ce que ces cas protègent.** La grille est ce qui rend le §IV.8 praticable :
/// une carte annoncée à tort doit se voir et se décocher. Un rendu qui
/// n'afficherait pas la carte, ou qui n'écouterait pas le geste, laisserait
/// entrer en collection ce que l'utilisateur croit avoir écarté.
///
/// L'écran, lui, n'est pas testable — `availableCameras()` n'a pas de réponse
/// hors d'un téléphone. C'est la raison d'être de ce composant séparé.
library;

import 'package:deckhand/src/common/card_image.dart';
import 'package:deckhand/src/features/scan/presentation/scan_basket_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _cards = [
  ScannedCard(
    oracleId: 'a',
    label: 'Pym Technologies',
    imageUrl: 'https://exemple.test/normal/a.jpg',
  ),
  ScannedCard(oracleId: 'b', label: 'Spider-Man, à la rescousse', quantity: 3),
  ScannedCard(oracleId: 'c', label: 'Kamiz, oculus des Obscura', keep: false),
];

Future<void> pump(
  WidgetTester tester, {
  List<ScannedCard> cards = _cards,
  void Function(String)? onToggle,
  void Function(String)? onEnlarge,
  bool enabled = true,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: ScanBasketGrid(
        cards: cards,
        enabled: enabled,
        onToggle: onToggle ?? (_) {},
        onEnlarge: onEnlarge ?? (_) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('chaque carte retenue porte son nom', (tester) async {
    await pump(tester);

    expect(find.text('Pym Technologies'), findsOneWidget);
    expect(find.text('Spider-Man, à la rescousse'), findsOneWidget);
    expect(find.text('Kamiz, oculus des Obscura'), findsOneWidget);
  });

  testWidgets('la carte est montrée en entier, redressée comme en case', (
    tester,
  ) async {
    // **`uprightInCell` n'est pas un détail de style.** Une carte couchée —
    // 210 chez Riftbound et Wankul — remplie en `cover` dans une case debout
    // perdrait les deux tiers de sa largeur, et ce qui resterait serait moitié
    // illustration moitié pavé de texte.
    await pump(tester, cards: [_cards.first]);

    final image = tester.widget<CardImage>(find.byType(CardImage));
    expect(image.url, 'https://exemple.test/normal/a.jpg');
    expect(image.uprightInCell, isTrue);
  });

  testWidgets('une carte sans image garde sa place et son nom', (tester) async {
    // L'absence d'image n'est pas une panne : la liste doit rester lisible,
    // sans quoi une carte devient indécochable faute d'être affichée.
    await pump(tester, cards: [_cards[1]]);

    expect(find.text('Spider-Man, à la rescousse'), findsOneWidget);
  });

  testWidgets('les exemplaires multiples s\'annoncent', (tester) async {
    await pump(tester);

    expect(find.text('×3'), findsOneWidget);
  });

  testWidgets('un appui écarte la carte', (tester) async {
    // Le geste courant de cette liste : on parcourt un booster fraîchement
    // scanné en retirant ce que la reconnaissance a inventé. Le geste courant
    // va au toucher simple, le geste rare — regarder — à l'appui long.
    final bascules = <String>[];
    final agrandies = <String>[];
    await pump(tester, onToggle: bascules.add, onEnlarge: agrandies.add);

    await tester.tap(find.text('Pym Technologies'));
    await tester.pump();

    expect(bascules, ['a']);
    expect(agrandies, isEmpty);
  });

  testWidgets('l\'appui long agrandit, il n\'écarte pas', (tester) async {
    // **Le geste doit dire ici ce qu'il dit partout ailleurs.** Une case de
    // classeur et une ligne du sélecteur d'édition agrandissent sur appui
    // long ; il a un temps supprimé ici, et qui voulait regarder une carte la
    // perdait.
    final bascules = <String>[];
    final agrandies = <String>[];
    await pump(tester, onToggle: bascules.add, onEnlarge: agrandies.add);

    await tester.longPress(find.text('Pym Technologies'));
    await tester.pump();

    expect(agrandies, ['a']);
    expect(bascules, isEmpty, reason: 'un appui long n\'écarte pas la carte');
  });

  testWidgets('pendant l\'enregistrement, plus rien ne bouge', (tester) async {
    // On ne modifie pas une liste en cours d'écriture : la moitié des cartes
    // seraient déjà parties en collection.
    final touches = <String>[];
    await pump(tester, enabled: false, onToggle: touches.add);

    await tester.tap(find.text('Pym Technologies'));
    await tester.pump();

    expect(touches, isEmpty);
  });
}
