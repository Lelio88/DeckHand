/// Le classeur qui s'ouvre, mesuré plutôt que regardé (#21).
///
/// **Ce qu'une animation cache.** Elle a l'air juste tant qu'on la regarde
/// distraitement : une carte qui sort du mauvais coin, un numéro de page qui
/// dépasse sa cible, un défilé qui s'allonge sans fin sur une grosse extension
/// — rien de tout cela ne se voit à l'œil sur un direct qui bouge. Le widget est
/// donc **pur**, piloté par un temps qu'on lui donne, et ces tests l'interrogent
/// à des instants choisis.
///
/// **Le contrôle le plus utile est celui de la trajectoire.** Toute la
/// différence entre « une carte apparaît » et « *cette* carte-là sort d'ici »
/// tient à ce que le point de départ soit la case annoncée par `!card`. Une
/// erreur d'un cran dans le calcul de ligne ou de colonne donnerait une
/// animation parfaitement fluide et parfaitement fausse.
library;

import 'package:deckhand/src/common/card_image.dart';
import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/domain/spotlight_request.dart';
import 'package:deckhand/src/features/binders/presentation/binder_reveal.dart';
import 'package:deckhand/src/features/binders/presentation/overlay_screen.dart';
import 'package:deckhand/src/features/binders/presentation/page_turn.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SpotlightCard carte({int page = 3, int slot = 5, String? by = 'alice'}) =>
    SpotlightCard(
      requestId: 1,
      name: 'Ka-Zar',
      printedName: 'Ka-Zar',
      requestedBy: by,
      setCode: 'msh',
      setName: 'Marvel Super Heroes',
      collectorNumber: '185',
      priceEur: 2.4,
      copies: 1,
      page: page,
      slot: slot,
      pages: 51,
    );

/// Neuf cases, celles qu'on désigne étant possédées. Les illustrations sont
/// des URL de forme réaliste : `CardImage` les compose, aucun octet ne part
/// dans un test.
List<BinderCell> pageDe(List<int> possedees) => [
  for (var i = 1; i <= 9; i++)
    BinderCell(
      collectorNumber: '$i',
      owned: possedees.contains(i) ? 1 : 0,
      artCropUrl: 'https://cards.scryfall.io/art_crop/front/a/b/carte-$i.jpg',
    ),
];

/// Une page demandée, sans carte : ce que `!page` fait monter.
SpotlightPage unePage({int page = 3, int pages = 51, String? by = 'bob'}) =>
    SpotlightPage(
      requestId: 2,
      requestedBy: by,
      setCode: 'msh',
      setName: 'Marvel Super Heroes',
      page: page,
      pages: pages,
    );

void main() {
  group('une page demandée', () {
    test('rien n_en sort, et le tempo le sait', () {
      // **La sortie n_est pas seulement sautée, elle est retirée du total.** La
      // laisser courir à vide ferait attendre le spectateur devant une page qui
      // ne bouge plus, avant que l_effacement ne commence.
      const carte = RevealTiming(12);
      const page = RevealTiming.pageOnly(12);
      expect(page.total, carte.total - RevealTiming.eject);
      expect(page.riffle, carte.riffle);
      // Et la carte ne bouge jamais : la case ne se vide pas, le halo reste
      // éteint.
      expect(page.ejectAt(page.total), 0);
      expect(page.ejectAt(page.total * 10), 0);
    });

    test('le genre choisit le tempo, en un seul endroit', () {
      // Le calque règle son horloge, `BinderReveal` dessine : les laisser
      // déduire la durée chacun de son côté, c_est une animation qui s_arrête
      // avant ou après la fin de son mouvement.
      expect(RevealTiming.of(unePage(page: 12)).ejects, isFalse);
      expect(RevealTiming.of(carte(page: 12)).ejects, isTrue);
      expect(
        RevealTiming.of(unePage(page: 12)).total,
        const RevealTiming.pageOnly(12).total,
      );
    });

    testWidgets('la planche nomme l_extension, pas une carte', (tester) async {
      // **Mettre une des neuf en titre laisserait croire que c_est elle qu_on a
      // demandée.** Ce que `!page` répond, c_est l_état de la page entière.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BinderReveal(
                request: unePage(),
                cells: pageDe([1, 2, 5]),
                elapsed: const RevealTiming.pageOnly(3).total,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Marvel Super Heroes'), findsOneWidget);
      expect(find.textContaining('page 3 sur 51'), findsOneWidget);
      // Le même « 4/9 » que le chat, mais à côté de l_image qui le montre.
      expect(find.textContaining('3 cases sur 9'), findsOneWidget);
      expect(find.textContaining('demandée par bob'), findsOneWidget);
      // Et aucune case n_est désignée : il n_y a pas de case.
      expect(find.textContaining('case '), findsNothing);
    });

    testWidgets('aucune carte ne sort, et aucune case ne se vide', (
      tester,
    ) async {
      const t = RevealTiming.pageOnly(3);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BinderReveal(
                request: unePage(),
                cells: pageDe([1, 2, 5]),
                elapsed: t.total,
              ),
            ),
          ),
        ),
      );
      // Les trois cases possédées le restent — une page ne prête rien.
      expect(find.text('#1'), findsNothing);
      expect(find.text('#5'), findsNothing);
      // Et les six vides portent toujours leur numéro.
      expect(find.text('#3'), findsOneWidget);
    });

    testWidgets('sans les cases, elle n_invente pas une page vide', (
      tester,
    ) async {
      // La lecture des cases est un second appel. Tant qu_elle n_est pas
      // revenue, « 0 sur 9 » annoncerait une page vide là où l_on ne sait
      // simplement pas encore.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: BinderReveal(
                request: unePage(),
                cells: const [],
                elapsed: const RevealTiming.pageOnly(3).total,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('page 3 sur 51'), findsOneWidget);
      expect(find.textContaining('cases sur'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('le tempo', () {
    test("l'intro laisse le temps de regarder la carte", () {
      // **La contrainte dure, et elle vient d'ailleurs.** Le calque efface la
      // carte au bout d'`overlayLinger` : une intro qui mange ce délai
      // priverait le spectateur de ce pour quoi il a tapé la commande.
      final pire = RevealTiming(500).total;
      expect(pire, lessThanOrEqualTo(2400));
      expect(pire, lessThan(overlayLinger.inMilliseconds / 4));
    });

    test('la page 1 ne feuillette pas', () {
      // Feuilleter pour rester sur place serait un mensonge, et une seconde
      // perdue.
      expect(RevealTiming(1).riffle, 0);
      expect(RevealTiming(1).riffleAt(0), 1);
    });

    test('le défilé est plafonné, pas proportionnel', () {
      // Une extension de cinq cents pages ne doit pas coûter douze secondes de
      // feuilletage. Au-delà du plafond, le flou est déjà du flou.
      expect(RevealTiming(20).riffle, lessThan(RevealTiming(51).riffle));
      expect(RevealTiming(51).riffle, RevealTiming(500).riffle);
    });

    test('le numéro monte et s_arrête sur le bon', () {
      const t = RevealTiming(46);
      expect(t.pageAt(0), 1);
      expect(
        t.pageAt(RevealTiming.open + t.riffle / 2),
        inInclusiveRange(2, 45),
      );
      expect(t.pageAt(RevealTiming.open + t.riffle), 46);
      // **Il ne dépasse jamais.** Un compteur qui afficherait 47 une frame
      // avant de se poser rendrait tout le procédé suspect.
      expect(t.pageAt(t.total), 46);
      expect(t.pageAt(t.total * 10), 46);
    });

    test('les phases ne se chevauchent pas', () {
      const t = RevealTiming(10);
      // La carte ne bouge pas tant que la page n_est pas posée.
      expect(t.ejectAt(RevealTiming.open + t.riffle), 0);
      expect(t.ejectAt(t.total), 1);
    });
  });

  group('la trajectoire', () {
    test('la carte part de SA case', () {
      // Le contrôle qui vaut tous les autres : une erreur d_un cran donnerait
      // une animation fluide et fausse.
      for (var slot = 1; slot <= 9; slot++) {
        expect(RevealMetrics.cardRect(slot, 0), RevealMetrics.slotRect(slot));
      }
    });

    test('elle se hisse hors de sa case avant de partir', () {
      // **Deux gestes, et le premier a un sens.** Une carte qui glisse d'un
      // trait vers la droite traverse la page ; elle ne sort de rien, et le
      // classeur n'est plus qu'un décor. Tant qu'elle se hisse, elle garde sa
      // taille et sa colonne : elle monte, un point c'est tout.
      for (var slot = 1; slot <= 9; slot++) {
        final case_ = RevealMetrics.slotRect(slot);
        final mi = RevealMetrics.cardRect(slot, RevealMetrics.liftFraction / 2);
        expect(mi.left, closeTo(case_.left, 1e-9));
        expect(mi.width, closeTo(case_.width, 1e-9));
        expect(mi.height, closeTo(case_.height, 1e-9));
        expect(mi.top, lessThan(case_.top));

        expect(
          RevealMetrics.cardRect(slot, RevealMetrics.liftFraction),
          RevealMetrics.liftedRect(slot),
        );
      }
    });

    test('puis grandit en s_en allant, et pas avant', () {
      const slot = 5;
      final case_ = RevealMetrics.slotRect(slot);
      // Rien n_a grandi tant qu_elle se hisse.
      expect(
        RevealMetrics.cardRect(slot, RevealMetrics.liftFraction).width,
        closeTo(case_.width, 1e-9),
      );
      // Puis la largeur monte, sans jamais redescendre.
      var precedente = case_.width;
      for (var i = 0; i <= 20; i++) {
        final t =
            RevealMetrics.liftFraction +
            (1 - RevealMetrics.liftFraction) * i / 20;
        final large = RevealMetrics.cardRect(slot, t).width;
        expect(large, greaterThanOrEqualTo(precedente - 1e-9));
        precedente = large;
      }
      expect(precedente, RevealMetrics.heroRect.width);
    });

    test('la carte hissée sort de la couverture, mais pas de la planche', () {
      // **Les deux moitiés d_une même exigence.** Hissée d_une hauteur
      // entière, une carte de la première rangée passe **au-dessus** du
      // classeur : c_est ce qu_on veut voir, et c_est pour cela qu_elle est
      // dessinée hors du rognage. Mais la planche, elle, borne pour de bon —
      // si elle ne réserve pas la place, la carte est tranchée net au moment
      // précis où on la regarde sortir.
      expect(
        RevealMetrics.liftedRect(1).top,
        lessThan(0),
        reason: 'sinon le hissement ne sort pas du classeur',
      );
      for (var slot = 1; slot <= 9; slot++) {
        final hissee = RevealMetrics.cardOnPlank(
          slot,
          RevealMetrics.liftFraction,
        );
        expect(hissee.top, greaterThanOrEqualTo(0));
        expect(hissee.bottom, lessThanOrEqualTo(RevealMetrics.height));
      }
    });

    test('la planche réserve exactement ce que le hissement demande', () {
      // Un chiffre qui se déduit : la hauteur d_une carte, moins ce que la
      // première rangée a déjà au-dessus d_elle, plus la portée de l_ombre.
      expect(
        RevealMetrics.height - RevealMetrics.coverHeight,
        RevealMetrics.topRoom,
      );
      expect(
        RevealMetrics.topRoom,
        RevealMetrics.lift - RevealMetrics.gridTop + RevealMetrics.shadowReach,
      );
      // La couverture, elle, n_a pas bougé : c_est toujours le classeur.
      expect(RevealMetrics.coverRect().height, RevealMetrics.coverHeight);
      expect(RevealMetrics.coverRect().bottom, RevealMetrics.height);
      // **Sans carte à poser à droite, la couverture se resserre** — et la
      // planche, elle, garde sa taille : c_est un rectangle placé une fois
      // dans une scène OBS, le voir se rétrécir déplacerait le classeur.
      expect(
        RevealMetrics.coverRect(withHero: false).width,
        lessThan(RevealMetrics.coverRect().width),
      );
      expect(
        RevealMetrics.coverRect(withHero: false).width,
        greaterThan(RevealMetrics.pageRect.right),
      );
    });

    test('et finit toujours au même endroit', () {
      for (var slot = 1; slot <= 9; slot++) {
        expect(RevealMetrics.cardRect(slot, 1), RevealMetrics.heroRect);
      }
    });

    test('les neuf cases sont distinctes et en lecture occidentale', () {
      final vues = <Rect>{};
      for (var slot = 1; slot <= 9; slot++) {
        vues.add(RevealMetrics.slotRect(slot));
      }
      expect(vues.length, 9);
      // 1 2 3 sur la première ligne, 4 au début de la seconde.
      expect(RevealMetrics.slotRect(1).top, RevealMetrics.slotRect(3).top);
      expect(RevealMetrics.slotRect(1).left, RevealMetrics.slotRect(4).left);
      expect(
        RevealMetrics.slotRect(4).top,
        greaterThan(RevealMetrics.slotRect(1).top),
      );
    });

    test('la grille tient dans la couverture', () {
      // **Dans la couverture, et non dans la planche** : celle-ci réserve en
      // plus une bande au-dessus pour la carte qu_on sort, et s_y mesurer
      // laisserait passer une grille qui déborde du classeur.
      for (var slot = 1; slot <= 9; slot++) {
        final r = RevealMetrics.slotRect(slot);
        expect(r.right, lessThanOrEqualTo(RevealMetrics.width));
        expect(r.bottom, lessThanOrEqualTo(RevealMetrics.coverHeight));
      }
      expect(
        RevealMetrics.heroRect.right,
        lessThanOrEqualTo(RevealMetrics.width),
      );
      expect(
        RevealMetrics.heroRect.bottom,
        lessThanOrEqualTo(RevealMetrics.coverHeight),
      );
    });
  });

  group('les feuilles qui volent', () {
    test('la feuille emprunte le pliage du classeur, elle ne le réécrit pas', () {
      // **Le contrôle qui dit le défaut d'origine.** Le calque pivotait un plan
      // rigide *de l'autre sens* : la feuille s'enfonçait dans le classeur au
      // lieu de venir vers l'œil. `page_turn.dart` sait tourner une page — c'est
      // ce qu'on voit sous le doigt à l'écran de collection — et deux
      // géométries pour un même geste divergent, comme celles-ci avaient
      // divergé. Le contrôle vit dans le groupe qui dessine, ci-dessous ; ici on
      // fixe la propriété qui compte : la profondeur va vers l'œil.
      for (final t in [0.1, 0.25, 0.4, 0.6, 0.9]) {
        for (final p in stripePlacements(t: t, width: 308)) {
          expect(p.z, lessThanOrEqualTo(0), reason: 'à t=$t');
        }
      }
    });

    test('la feuille en vol tient sous la couverture', () {
      // Elle grossit en se dressant, et ce qui déborde est tranché net. La
      // boîte est calculée depuis la place disponible : si la planche change de
      // proportions sans que ce calcul suive, une feuille se fera couper en
      // deux — et personne ne le verra dans le code.
      final page = RevealMetrics.pageRect;
      final boite = RevealMetrics.leafBox;
      expect(boite.width, greaterThan(page.width));
      expect(boite.height, greaterThan(page.height));
      expect(
        page.left + boite.width,
        lessThanOrEqualTo(RevealMetrics.width - RevealMetrics.pad),
      );
      expect(
        page.top + boite.height,
        lessThanOrEqualTo(RevealMetrics.coverHeight - RevealMetrics.pad),
      );
    });

    test('un tour de feuille dure assez longtemps pour se voir', () {
      // **Le contrôle qui garde le défilé observable.** Les feuilles tournaient
      // à raison d'une par page comptée, soit 24 ms le tour : une image et
      // demie à soixante hertz. Aucune géométrie ne survit à cela — courbure,
      // profondeur, ombre portée se réduisaient à un scintillement. Huit images
      // est le plancher en deçà duquel un mouvement se lit comme une coupe.
      const uneImage = 1000 / 60;
      expect(RevealTiming.sheetTurn, greaterThanOrEqualTo(8 * uneImage));
      // Et pas au point d'avaler le défilé : une page lointaine doit en montrer
      // plusieurs.
      expect(
        RevealTiming(51).riffle / RevealTiming.sheetTurn,
        greaterThanOrEqualTo(3),
      );
    });

    test('la perspective est déduite du renflement, pas réglée à côté', () {
      // Les deux constantes disent la même chose de deux façons ; les laisser
      // se contredire, c'est se retrouver avec une boîte trop petite pour la
      // feuille qu'elle doit contenir.
      final renflement =
          1 / (1 - RevealMetrics.leafPerspective * RevealMetrics.pageWidth);
      expect(renflement, closeTo(RevealMetrics.leafBulge, 1e-9));
    });
  });

  group('ce qui se dessine', () {
    Future<void> poser(
      WidgetTester tester, {
      required double elapsed,
      SpotlightCard? card,
      List<BinderCell> cells = const [],
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: BinderReveal(
              request: card ?? carte(),
              cells: cells,
              elapsed: elapsed,
            ),
          ),
        ),
      ),
    );

    testWidgets('la légende nomme la carte, sa case et son demandeur', (
      tester,
    ) async {
      await poser(tester, elapsed: RevealTiming(3).total);
      expect(find.text('Ka-Zar'), findsOneWidget);
      expect(find.textContaining('page 3'), findsOneWidget);
      expect(find.textContaining('case 5'), findsOneWidget);
      expect(find.textContaining('alice'), findsOneWidget);
      expect(find.textContaining('2,40 €'), findsOneWidget);
    });

    testWidgets('le nom ne s_affiche qu_une fois', (tester) async {
      // **Un défaut trouvé par ce test, pas à l_œil.** Le repli de
      // l_illustration affichait le nom de la carte, que la légende porte
      // déjà : deux « Ka-Zar » à l_écran, dont un dans le carton.
      await poser(tester, elapsed: RevealTiming(3).total);
      expect(find.text('Ka-Zar'), findsOneWidget);
    });

    testWidgets('le numéro de page affiché suit le défilé', (tester) async {
      const t = RevealTiming(46);
      await poser(tester, elapsed: 0, card: carte(page: 46));
      expect(find.textContaining('page 1'), findsOneWidget);

      await poser(tester, elapsed: t.total, card: carte(page: 46));
      expect(find.textContaining('page 46'), findsOneWidget);
    });

    testWidgets('la planche se dessine sans connaître les voisines', (
      tester,
    ) async {
      // La lecture de la page est un second appel : son échec ne doit pas
      // empêcher la carte de sortir.
      await poser(tester, elapsed: RevealTiming(3).total);
      expect(find.text('Ka-Zar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('et elle les montre quand elles arrivent', (tester) async {
      await poser(
        tester,
        elapsed: RevealTiming(3).total,
        cells: pageDe([1, 2, 5]),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(BinderReveal), findsOneWidget);
    });

    testWidgets('un demandeur inconnu ne s_invente pas un nom', (tester) async {
      await poser(
        tester,
        elapsed: RevealTiming(3).total,
        card: carte(by: null),
      );
      expect(find.textContaining('demandée dans le chat'), findsOneWidget);
    });

    testWidgets("l_attribution est visible, garde-fou §IV.2", (tester) async {
      await poser(tester, elapsed: RevealTiming(3).total);
      expect(find.textContaining('Scryfall'), findsOneWidget);
    });

    testWidgets('les feuilles sont celles du classeur de l_application', (
      tester,
    ) async {
      const t = RevealTiming(30);
      await poser(
        tester,
        elapsed: RevealTiming.open + t.riffle * 0.4,
        card: carte(page: 30),
      );
      expect(find.byType(CurlingLeaf), findsWidgets);
    });

    testWidgets('rien ne vole avant que la couverture soit à plat', (
      tester,
    ) async {
      // Les feuilles étaient dessinées dès la première frame, figées à leur
      // phase de départ : trois pages arrêtées en plein vol dans un classeur
      // qui s_ouvre encore.
      await poser(
        tester,
        elapsed: RevealTiming.open * 0.5,
        card: carte(page: 30),
      );
      expect(find.byType(CurlingLeaf), findsNothing);
    });

    testWidgets('la couverture ouverte ne porte plus aucune matrice', (
      tester,
    ) async {
      // **Le défaut le plus coûteux du chantier, et invisible en lecture.** Une
      // matrice de perspective sans rotation ne fait rien aux enfants plats,
      // mais elle divise par `1 + p·z` tout ce qui porte une profondeur. Les
      // feuilles en vol en portent une : elles héritaient d_une seconde
      // perspective, prise autour du milieu de la couverture, et leur bord
      // supérieur montait en biais au-dessus de la page.
      Matrix4 couverture() => tester
          .widget<Transform>(find.byKey(const ValueKey('couverture')))
          .transform;

      await poser(tester, elapsed: RevealTiming.open * 0.5);
      expect(couverture().isIdentity(), isFalse);

      await poser(tester, elapsed: RevealTiming(3).total);
      expect(couverture().isIdentity(), isTrue);
    });
  });

  group('le vocabulaire de la page', () {
    Future<void> poser(
      WidgetTester tester, {
      required double elapsed,
      SpotlightCard? card,
      List<BinderCell> cells = const [],
    }) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFB8860B),
            brightness: Brightness.dark,
          ),
        ),
        home: Scaffold(
          body: Center(
            child: BinderReveal(
              request: card ?? carte(),
              cells: cells,
              elapsed: elapsed,
            ),
          ),
        ),
      ),
    );

    testWidgets('une case vide porte son numéro, une case pleine non', (
      tester,
    ) async {
      // **Le vocabulaire de l_écran de collection**, repris tel quel : le
      // numéro nomme un manque. Sur une case possédée il ne dirait rien que la
      // carte ne dise déjà.
      await poser(
        tester,
        elapsed: RevealTiming(3).total,
        cells: pageDe([1, 5]),
      );
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('#1'), findsNothing);
    });

    testWidgets('la case visée ne se vide qu_au départ de la carte', (
      tester,
    ) async {
      // **Sinon la carte sort d_une case déjà vide.** Le trou doit apparaître
      // avec le mouvement, pas avant.
      const t = RevealTiming(3);
      final avant = RevealTiming.open + t.riffle + RevealTiming.settle * 0.5;
      await poser(tester, elapsed: avant, cells: pageDe([5]));
      expect(t.ejectAt(avant), 0);
      expect(find.text('#5'), findsNothing);

      await poser(tester, elapsed: t.total, cells: pageDe([5]));
      expect(find.text('#5'), findsOneWidget);
    });

    testWidgets('le dos des cartes ne se voit que pendant le feuilletage', (
      tester,
    ) async {
      final carteLoin = carte(page: 30);
      const t = RevealTiming(30);

      await poser(
        tester,
        elapsed: RevealTiming.open + t.riffle * 0.4,
        card: carteLoin,
        cells: pageDe([5]),
      );
      expect(find.byKey(const ValueKey('dos-de-feuille')), findsWidgets);

      await poser(
        tester,
        elapsed: t.total,
        card: carteLoin,
        cells: pageDe([5]),
      );
      expect(find.byKey(const ValueKey('dos-de-feuille')), findsNothing);
    });

    testWidgets('la page de destination est dessous dès le feuilletage', (
      tester,
    ) async {
      // Ne la peupler qu_à la fin faisait apparaître ses neuf cartes d_un coup.
      final carteLoin = carte(page: 30);
      const t = RevealTiming(30);
      await poser(
        tester,
        elapsed: RevealTiming.open + t.riffle * 0.4,
        card: carteLoin,
        cells: pageDe([5]),
      );
      expect(find.text('#2'), findsOneWidget);
    });

    testWidgets('les illustrations passent par CardImage', (tester) async {
      // **Jamais `Image.network`.** `CardImage` est le point de passage unique
      // où l_URL est composée ; le contourner a déjà coûté 20 964 cartes
      // Pokémon dont aucune ne s_affichait.
      await poser(
        tester,
        elapsed: RevealTiming(3).total,
        cells: pageDe([1, 5]),
      );
      expect(find.byType(CardImage), findsWidgets);
      // `CardImage` rend lui-même des `Image` : ce qui compte est leur
      // **fournisseur**. Un `Image.network` y poserait un `NetworkImage`, et
      // l'URL ne passerait plus par le point de composition unique.
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images, isNotEmpty);
      for (final image in images) {
        expect(image.image, isA<CardImageProvider>());
      }
    });
  });
}
