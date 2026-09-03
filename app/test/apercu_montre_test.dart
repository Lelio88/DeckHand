/// Aperçu : rend le feuilletage de `!montre` en images, pour le REGARDER.
///
/// **Ce n'est pas un test de non-régression** — il n'assère rien, il fabrique
/// des captures. `tool/apercu_montre.dart` montre déjà l'animation en
/// mouvement, mais il faut Chrome, un œil et de la mémoire : une page qui
/// tourne dure deux cent quarante millisecondes, et ce qui cloche dedans ne se
/// laisse pas rattraper à l'œil nu. Ces images figent le mouvement aux instants
/// où il se juge.
///
/// **Ce qu'il ne remplace pas** : `tool/apercu_montre.dart`. Une image ne dit
/// rien du tempo, et le pliage se juge autant sur la continuité d'une image à
/// l'autre que sur chacune.
///
/// Il est **sauté par `flutter test`**, comme `apercu_tuiles_test.dart` : sans
/// police réelle le texte se rend en rectangles. Pour le jouer :
///
///     cd app && DECKHAND_FONTS=<flutter>/bin/cache/artifacts/material_fonts \
///         flutter test test/apercu_montre_test.dart --update-goldens
///
/// Les images atterrissent dans `test/apercu/`, hors dépôt.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/domain/spotlight_request.dart';
import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:deckhand/src/features/binders/presentation/card_mat.dart';
import 'package:deckhand/src/features/binders/presentation/sheet_face.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apercu_tuiles_test.dart' show chargerRoboto;

final _cases = <BinderCell>[
  for (var i = 1; i <= 9; i++)
    BinderCell(
      collectorNumber: '${423 + i}',
      owned: i == 7 || i == 8 ? 1 : 0,
      hasFoil: i == 7,
      artCropUrl: 'https://cards.scryfall.io/art_crop/front/a/b/carte-$i.jpg',
    ),
];

const _carte = SpotlightCard(
  requestId: 1,
  name: 'Daredevil, Man Without Fear',
  printedName: 'Daredevil, Man Without Fear',
  requestedBy: 'alice',
  setCode: 'msh',
  setName: 'Marvel Super Heroes',
  collectorNumber: '431',
  priceEur: 0.39,
  copies: 1,
  page: 48,
  slot: 8,
  pages: 51,
);

void main() {
  setUpAll(chargerRoboto);

  testWidgets(
    'capture le feuilletage, instant par instant',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1600, 1240);
      addTearDown(tester.view.reset);

      const t = RevealTiming(48);
      // Six instants : l'ouverture, quatre prises dans le feuilletage, la page
      // posée. C'est entre la deuxième et la cinquième que tout se joue.
      final instants = <String, double>{
        'ouverture': RevealTiming.open * 0.6,
        'feuilletage-1': RevealTiming.open + t.riffle * 0.20,
        'feuilletage-2': RevealTiming.open + t.riffle * 0.35,
        'feuilletage-3': RevealTiming.open + t.riffle * 0.50,
        'feuilletage-4': RevealTiming.open + t.riffle * 0.65,
        // La sortie en deux temps : on la hisse hors de sa pochette, puis elle
        // s'en va en grandissant.
        'sortie-hissee':
            RevealTiming.open +
            t.riffle +
            RevealTiming.settle +
            RevealTiming.eject * RevealMetrics.liftFraction,
        'sortie-envol':
            RevealTiming.open +
            t.riffle +
            RevealTiming.settle +
            RevealTiming.eject * 0.7,
        'posee': t.total,
      };

      for (final entry in instants.entries) {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFFB8860B),
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
            ),
            home: Scaffold(
              backgroundColor: const Color(0xFF3B3A45),
              body: Center(
                child: RepaintBoundary(
                  child: BinderReveal(
                    request: _carte,
                    cells: _cases,
                    elapsed: entry.value,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await expectLater(
          find.byType(BinderReveal),
          matchesGoldenFile('apercu/montre-${entry.key}.png'),
        );
      }

      // **Ce que `!page` fait monter** : le classeur s'ouvre, feuillette, pose la
      // page — et se tait. Rien n'en sort, et c'est tout ce qui la distingue.
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFB8860B),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: Scaffold(
            backgroundColor: const Color(0xFF3B3A45),
            body: Center(
              child: RepaintBoundary(
                child: BinderReveal(
                  request: const SpotlightPage(
                    requestId: 2,
                    requestedBy: 'bob',
                    setCode: 'msh',
                    setName: 'Marvel Super Heroes',
                    page: 48,
                    pages: 51,
                  ),
                  cells: _cases,
                  elapsed: const RevealTiming.pageOnly(48).total,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await expectLater(
        find.byType(BinderReveal),
        matchesGoldenFile('apercu/montre-page-seule.png'),
      );

      // **Le tapis, à trois comptes.** Sa seule promesse est de tenir moins de
      // place qu'une planche tout en restant lisible ; on la juge à un, quatre
      // et dix — le dernier étant le plafond mesuré.
      for (final n in [1, 4, 10]) {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFFB8860B),
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
            ),
            home: Scaffold(
              backgroundColor: const Color(0xFF3B3A45),
              body: Center(
                child: RepaintBoundary(
                  child: CardMat(
                    strip: SpotlightStrip(
                      requestId: 3,
                      requestedBy: 'carol',
                      entries: [
                        for (var i = 0; i < n; i++)
                          SpotlightCard(
                            requestId: 3,
                            name: 'Forest',
                            printedName: 'Forêt',
                            setCode: 'msh',
                            setName: 'Marvel Super Heroes',
                            collectorNumber: '${285 + i}',
                            artCropUrl: _cases[i % _cases.length].artCropUrl,
                            copies: 2,
                          ),
                      ],
                    ),
                    elapsed: MatTiming(n).total,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await expectLater(
          find.byType(CardMat),
          matchesGoldenFile('apercu/tapis-$n.png'),
        );
      }
    },
    skip: Platform.environment['DECKHAND_FONTS'] == null,
  );

  testWidgets('capture le patron des pages qui défilent', (tester) async {
    // **Le motif se juge à l'arrêt et de près**, sinon on ne sait pas si ce
    // qu'on ne voit pas en mouvement est absent ou seulement trop discret.
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(2000, 1600);
    addTearDown(tester.view.reset);

    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFB8860B),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );

    for (final (nom, pochettes) in [('recto', false), ('verso', true)]) {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            backgroundColor: const Color(0xFF1B1B22),
            body: Center(
              child: SizedBox(
                width: RevealMetrics.pageWidth,
                height: RevealMetrics.pageHeight,
                child: SheetFace(
                  colors: theme.colorScheme,
                  padding: RevealMetrics.pagePad,
                  gap: RevealMetrics.gap,
                  pockets: pochettes,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await expectLater(
        find.byType(SheetFace),
        matchesGoldenFile('apercu/patron-$nom.png'),
      );
    }
    // **Sauté comme ses voisins, et il ne l'était pas.** Ce test compare contre
    // une image de `test/apercu/`, dossier tenu hors dépôt — ce sont des
    // captures à regarder, pas des références de non-régression. Sur une
    // machine propre le fichier n'existe pas et le test échoue ; la CI le
    // rendait rouge depuis le commit qui l'a introduit, sans que rien ne le
    // montre en local, où les images sont là. Le motif ne dépend pourtant
    // d'aucune police : c'est la garde des aperçus qu'il lui manquait, pas
    // celle des polices.
  }, skip: Platform.environment['DECKHAND_FONTS'] == null);

  testWidgets(
    'capture le vrai dos du jeu, quand on lui en donne un',
    (tester) async {
      // **Le seul contrôle qui dise que le dos s'affiche vraiment.** Un test ne
      // va pas sur le réseau ; on lui passe donc un fichier, celui qu'on aura
      // téléchargé une fois de la source qui le publie :
      //
      //     curl -o /tmp/back.jpg \
      //       "https://backs.scryfall.io/normal/0/a/0aeeba...jpg"
      //     DECKHAND_CARD_BACK=/tmp/back.jpg DECKHAND_FONTS=... flutter test ...
      //
      // Sans la variable, la capture est sautée — un fichier hors dépôt ne peut
      // pas être une condition de la suite.
      final chemin = Platform.environment['DECKHAND_CARD_BACK'];
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(2000, 1600);
      addTearDown(tester.view.reset);

      late final ui.Image dos;
      await tester.runAsync(() async {
        final octets = await File(chemin!).readAsBytes();
        dos = (await (await ui.instantiateImageCodec(
          octets,
        )).getNextFrame()).image;
      });

      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB8860B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            backgroundColor: const Color(0xFF1B1B22),
            body: Center(
              child: SizedBox(
                width: RevealMetrics.pageWidth,
                height: RevealMetrics.pageHeight,
                child: SheetFace(
                  colors: theme.colorScheme,
                  padding: RevealMetrics.pagePad,
                  gap: RevealMetrics.gap,
                  back: dos,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await expectLater(
        find.byType(SheetFace),
        matchesGoldenFile('apercu/patron-dos-reel.png'),
      );
      dos.dispose();
    },
    skip: Platform.environment['DECKHAND_CARD_BACK'] == null,
  );
}
