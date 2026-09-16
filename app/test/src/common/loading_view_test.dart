/// Les trois âges d'une attente.
///
/// **Ce que ce test protège, c'est le silence du début.** Mesuré sous le rôle
/// réel, le chemin tiède rend l'étagère en 0,43 s et une feuille en 0,15 s : si
/// le squelette paraissait tout de suite, il apparaîtrait puis disparaîtrait
/// dans le même souffle, à chaque ouverture d'onglet. Une grille grise qui
/// clignote agite l'écran plus qu'un vide — c'est pourquoi le premier état ne
/// montre rien, et pourquoi ce n'est pas un oubli.
///
/// Le deuxième et le troisième protègent l'autre extrémité : le premier appel
/// d'une session froide a été mesuré à 7,4 s, et un indicateur muet s'y lit
/// comme une panne.
library;

import 'package:deckhand/src/common/loading_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Monte le dévoilement seul, avec un squelette reconnaissable.
Future<void> monter(WidgetTester tester) => tester.pumpWidget(
  const MaterialApp(
    home: Scaffold(
      body: LoadingView(skeleton: BinderGridSkeleton()),
    ),
  ),
);

void main() {
  testWidgets('avant 800 ms, rien ne paraît', (tester) async {
    await monter(tester);
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byType(BinderGridSkeleton), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Le serveur se réveille…'), findsNothing);
  });

  testWidgets('passé 800 ms, le squelette prend la forme de l\'écran', (
    tester,
  ) async {
    await monter(tester);
    await tester.pump(avantSquelette + const Duration(milliseconds: 50));

    expect(find.byType(BinderGridSkeleton), findsOneWidget);
    // **Neuf cases annoncées, au rapport d'une carte** : c'est le contrat, et
    // c'est ce qui fait que rien ne saute quand les cartes arrivent. On
    // l'assertit sur la grille et non sur le nombre de blocs rendus — une
    // `GridView.builder` ne bâtit que le visible, et ce compte-là dépend du
    // gabarit d'écran du test, pas du widget.
    final grille = tester.widget<GridView>(find.byType(GridView));
    final decoupe =
        grille.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(grille.semanticChildCount, 9);
    expect(decoupe.crossAxisCount, 3);
    expect(decoupe.childAspectRatio, closeTo(63 / 88, 0.001));
    expect(find.byType(SkeletonBox), findsWidgets);
    // Le mot n'arrive pas encore — l'attente est longue, pas anormale.
    expect(find.text('Le serveur se réveille…'), findsNothing);
  });

  testWidgets('passé 3 s, l\'attente s\'explique', (tester) async {
    await monter(tester);
    await tester.pump(avantMot + const Duration(milliseconds: 50));

    expect(find.byType(BinderGridSkeleton), findsOneWidget);
    expect(find.text('Le serveur se réveille…'), findsOneWidget);

    // Le squelette reste : le mot s'ajoute, il ne remplace pas.
    expect(find.byType(SkeletonBox), findsWidgets);
  });

  testWidgets('sans squelette, c\'est l\'indicateur qui tient la place', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LoadingView())),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('le message se remplace', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LoadingView(message: 'Index en cours de lecture…')),
      ),
    );
    await tester.pump(avantMot + const Duration(milliseconds: 50));

    expect(find.text('Index en cours de lecture…'), findsOneWidget);
    expect(find.text('Le serveur se réveille…'), findsNothing);
  });

  testWidgets('démonté avant l\'échéance, il ne réveille personne', (
    tester,
  ) async {
    // **Le cas courant, et le seul qui pourrait lever.** L'attente se résout
    // presque toujours avant 800 ms : le widget est alors démonté avec ses
    // minuteries en vol, et un `setState` après coup ferait tomber l'écran.
    await monter(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('ok'))));
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('ok'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('une reprise ne doit pas cacher une panne', () {
    // **Riverpod 3 réessaie tout seul un provider qui a échoué.** Pendant
    // chaque reprise, l'état repasse « en cours » tout en gardant l'erreur —
    // mesuré, cinq tentatives en trois secondes. `when()` rend alors sa branche
    // `loading`, et un réseau coupé donne un écran qui tourne indéfiniment au
    // lieu du message et du bouton « Réessayer ». C'est précisément la panne que
    // `request_timeout.dart` avait supprimée, revenue par un autre chemin.
    //
    // **Le piège lui-même se vérifie sur l'écran, pas ici.** Une reprise
    // reconstituée à la main ne reproduit pas l'`AsyncValue` que Riverpod
    // fabrique — essayé, `when()` y rend la branche d'erreur. Ce sont les tests
    // « quand le réseau lâche » de `binder_view_test.dart` qui tiennent la
    // garantie de bout en bout : ils tombaient avec `when`, ils passent avec
    // `settled`.
    test('settled() montre la panne', () {
      expect(
        AsyncError<int>('réseau coupé', StackTrace.empty).settled(
            data: (_) => 'données', error: (_, _) => 'panne',
            loading: () => 'chargement'),
        'panne',
      );
    });

    test('un chargement sans erreur reste un chargement', () {
      expect(
        const AsyncLoading<int>().settled(
            data: (_) => 'données', error: (_, _) => 'panne',
            loading: () => 'chargement'),
        'chargement',
      );
    });

    test('des données restent des données', () {
      expect(
        const AsyncData<int>(7).settled(
            data: (v) => 'données $v', error: (_, _) => 'panne',
            loading: () => 'chargement'),
        'données 7',
      );
    });
  });
}
