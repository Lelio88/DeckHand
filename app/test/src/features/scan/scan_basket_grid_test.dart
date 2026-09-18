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
import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
  void Function(String)? onIncrement,
  void Function(String)? onDecrement,
  bool enabled = true,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: ScanBasketGrid(
        cards: cards,
        enabled: enabled,
        onToggle: onToggle ?? (_) {},
        onEnlarge: onEnlarge ?? (_) {},
        onIncrement: onIncrement ?? (_) {},
        onDecrement: onDecrement ?? (_) {},
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

  group('le compte, à la souris', () {
    // **Le stepper n'apparaît que si la tuile a la place** (#44). À quatre
    // par ligne, une tuile fait 76 dp sur un téléphone de 360 : deux cibles
    // de 40 et le nombre n'y tiennent pas, et ce n'est pas une affaire de
    // goût. Sur un poste de travail la même grille donne des tuiles de 250 :
    // la place est là, et c'est là qu'on corrige un compte à la souris. Le
    // téléphone garde ses gestes tels quels, là où tout est mesuré.
    Finder dansLaTuile(String oracleId, Finder quoi) =>
        find.descendant(of: find.byKey(ValueKey(oracleId)), matching: quoi);

    testWidgets('sur une tuile large, un de plus et un de moins', (
      tester,
    ) async {
      // 800 dp de large par défaut : des tuiles de 186, au-dessus du seuil.
      final plus = <String>[];
      final moins = <String>[];
      await pump(tester, onIncrement: plus.add, onDecrement: moins.add);

      await tester.tap(dansLaTuile('b', find.byTooltip('Un de plus')));
      await tester.tap(dansLaTuile('b', find.byTooltip('Un de moins')));
      await tester.pump();

      expect(plus, ['b']);
      expect(moins, ['b']);
    });

    testWidgets('un de moins est inactif sur un seul exemplaire', (
      tester,
    ) async {
      // Descendre à zéro n'est pas ce geste — écarter la ligne l'est.
      final moins = <String>[];
      await pump(tester, onDecrement: moins.add);

      await tester.tap(dansLaTuile('a', find.byTooltip('Un de moins')));
      await tester.pump();

      expect(moins, isEmpty);
    });

    testWidgets('corriger le compte n\'écarte pas la carte', (tester) async {
      // La tuile entière écoute le toucher pour écarter ; les boutons du
      // stepper doivent gagner l'arène, sinon chaque « + » décocherait.
      final bascules = <String>[];
      await pump(tester, onToggle: bascules.add);

      await tester.tap(dansLaTuile('b', find.byTooltip('Un de plus')));
      await tester.pump();

      expect(bascules, isEmpty);
    });

    testWidgets('sur une tuile étroite, pas de stepper', (tester) async {
      // Un téléphone de 360 : tuiles de 76 dp, sous le seuil.
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester);

      expect(find.byTooltip('Un de plus'), findsNothing);
      expect(find.byTooltip('Un de moins'), findsNothing);
      // Le nombre d'exemplaires se lit toujours, sur la pastille.
      expect(find.text('×3'), findsOneWidget);
    });

    testWidgets('une carte écartée n\'a pas de compte à corriger', (
      tester,
    ) async {
      await pump(tester);
      expect(dansLaTuile('c', find.byTooltip('Un de plus')), findsNothing);
    });

    testWidgets('pendant l\'enregistrement, le compte ne bouge plus', (
      tester,
    ) async {
      final plus = <String>[];
      await pump(tester, enabled: false, onIncrement: plus.add);

      await tester.tap(dansLaTuile('b', find.byTooltip('Un de plus')));
      await tester.pump();

      expect(plus, isEmpty);
    });
  });

  group('agrandir, à la souris', () {
    // **L'appui long n'a pas de sens au clic** : maintenir le bouton une
    // seconde, personne ne le fait spontanément. Une loupe apparaît au survol
    // — donc seulement là où il y a un pointeur —, et le tactile garde
    // l'appui long tel quel.
    testWidgets('sans survol, pas de loupe', (tester) async {
      await pump(tester);
      expect(find.byTooltip('Voir en grand'), findsNothing);
    });

    testWidgets('au survol, la loupe agrandit sans écarter', (tester) async {
      final bascules = <String>[];
      final agrandies = <String>[];
      await pump(tester, onToggle: bascules.add, onEnlarge: agrandies.add);

      final souris = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await souris.addPointer(location: Offset.zero);
      addTearDown(souris.removePointer);
      await souris.moveTo(tester.getCenter(find.text('Pym Technologies')));
      await tester.pump();

      final loupe = find.descendant(
        of: find.byKey(const ValueKey('a')),
        matching: find.byTooltip('Voir en grand'),
      );
      expect(loupe, findsOneWidget);

      await tester.tap(loupe);
      await tester.pump();

      expect(agrandies, ['a']);
      expect(bascules, isEmpty);
    });
  });
}
