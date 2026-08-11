/// Tests de la vue classeur.
///
/// **Ce que ces tests protègent est la raison d'être de la vue : les cases
/// vides.** Une liste de collection dit ce qu'on possède ; un classeur dit ce
/// qui manque, à sa place, dans l'ordre des numéros. Si les cases vides
/// disparaissaient — parce qu'on partirait de la collection au lieu du
/// catalogue — il ne resterait qu'une liste en grille, et l'intérêt de la vue
/// avec elles.
///
/// Le second point est l'étagère : elle ne doit montrer que les éditions où
/// quelque chose est rangé. Le catalogue en compte 695, dont 690 seraient des
/// classeurs vides.
library;

import 'package:deckhand/src/config/request_timeout.dart';
import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/common/card_image.dart';
import 'package:deckhand/src/features/binders/domain/binder.dart';
import 'package:deckhand/src/features/binders/presentation/binder_view.dart';
import 'package:deckhand/src/features/printings/presentation/foil_decoration.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

BinderShelfEntry shelfEntry({
  String setCode = 'msh',
  String setName = 'Marvel Super Heroes',
  int total = 453,
  int owned = 216,
  int copies = 300,
  String? art,
  String? icon,
}) => BinderShelfEntry(
  setCode: setCode,
  setName: setName,
  totalCells: total,
  ownedCells: owned,
  ownedCopies: copies,
  artCropUrl: art,
  iconSvgUri: icon,
);

/// Une URL d'illustration telle que le catalogue les porte.
const _art =
    'https://cards.scryfall.io/art_crop/front/e/0/e040b456.jpg?1783902897';

/// Le symbole d'une extension, tel que `card_sets` le porte.
///
/// L'URL est celle de Scryfall et non une invention : elle ne se déduit pas du
/// code d'extension — mesuré, la déduction est fausse deux fois sur trois.
const _icon = 'https://svgs.scryfall.io/sets/msh.svg?1786334400';

BinderCell cell({
  required String number,
  int owned = 0,
  String? name,
  bool hasFoil = false,
  String? art,
}) => BinderCell(
  collectorNumber: number,
  owned: owned,
  // Une case occupée désigne une carte du catalogue ; une case vide n'en
  // désigne aucune, et c'est ce qui lui interdit toute action.
  oracleId: owned > 0 ? 'oracle-$number' : null,
  printId: owned > 0 ? 'print-$number' : null,
  name: name ?? (owned > 0 ? 'Agent d\'Atlas' : null),
  hasFoil: hasFoil,
  artCropUrl: art,
);

class FakeBinderRepository implements BinderRepository {
  FakeBinderRepository({
    this.entries = const [],
    this.cells = const [],
    this.pile = const [],
    this.firstFilledPage = 1,
  });

  List<BinderShelfEntry> entries;
  List<BinderCell> cells;
  List<UnsortedCard> pile;

  /// Ce que le serveur répond quand on lui demande où commencer.
  int firstFilledPage;

  /// Lectures demandées, pour vérifier que tri et filtre atteignent le serveur.
  final requested =
      <
        ({
          String setCode,
          int page,
          BinderSort sort,
          FinishFilter finish,
          bool descending,
        })
      >[];

  /// Finitions pour lesquelles la première page non vide a été demandée.
  final jumps = <FinishFilter>[];

  /// Ce que le réseau oppose, tant qu'il l'oppose.
  ///
  /// Persistant, et non levé une seule fois : la vue demande l'étagère plus
  /// d'une fois au montage, et une panne qui s'efface d'elle-même passerait
  /// donc inaperçue. On la lève tant que le test ne l'a pas explicitement
  /// levée — ce qui est aussi la vérité d'un réseau coupé.
  Object? shelfError;

  /// Nombre de fois que l'étagère a été demandée.
  int shelfCalls = 0;

  @override
  Future<List<BinderShelfEntry>> shelf({Game game = Game.magic}) async {
    shelfCalls++;
    final error = shelfError;
    if (error != null) throw error;
    return entries;
  }

  @override
  Future<List<BinderCell>> pageOf(
    String setCode, {
    int page = 1,
    int perPage = binderPageSize,
    BinderSort sort = BinderSort.number,
    FinishFilter finish = FinishFilter.all,
    bool descending = false,
  }) async {
    requested.add((
      setCode: setCode,
      page: page,
      sort: sort,
      finish: finish,
      descending: descending,
    ));
    return cells;
  }

  @override
  Future<int> firstPage(
    String setCode, {
    int perPage = binderPageSize,
    FinishFilter finish = FinishFilter.all,
  }) async {
    jumps.add(finish);
    return firstFilledPage;
  }

  @override
  Future<List<UnsortedCard>> unsorted({
    Game game = Game.magic,
    int page = 1,
    int perPage = binderPageSize,
  }) async => pile;

  /// Cartes trouvées par la recherche, quelle que soit la requête.
  List<BinderFind> found = const [];

  /// Ce qui a été cherché, pour vérifier que la frappe atteint le serveur.
  final searches = <String>[];

  @override
  Future<List<BinderFind>> find(
    String query, {
    Game game = Game.magic,
    int limit = 20,
  }) async {
    searches.add(query);
    return found;
  }
}

Future<FakeBinderRepository> pumpBinder(
  WidgetTester tester, {
  List<BinderShelfEntry> entries = const [],
  List<BinderCell> cells = const [],
  List<UnsortedCard> pile = const [],
  int firstFilledPage = 1,
  int unspecified = 0,
  Object? shelfError,
}) async {
  final repository = FakeBinderRepository(
    entries: entries,
    cells: cells,
    pile: pile,
    firstFilledPage: firstFilledPage,
  )..shelfError = shelfError;
  final collection = FakeCollectionRepository()
    ..totals = CollectionSummary(
      totalCards: 1,
      distinctCards: 1,
      totalValueEur: 0,
      unspecifiedPrints: unspecified,
    );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        binderRepositoryProvider.overrideWithValue(repository),
        collectionRepositoryProvider.overrideWithValue(collection),
        printingRepositoryProvider.overrideWithValue(FakePrintingRepository()),
        // Les totaux — d'où vient le compte des cartes à trier — ne sont
        // demandés que pour une session ouverte.
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: BinderView())),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  group('l\'étagère', () {
    testWidgets('ne montre que les éditions où quelque chose est rangé', (
      tester,
    ) async {
      await pumpBinder(
        tester,
        entries: [
          shelfEntry(),
          shelfEntry(
            setCode: 'msc',
            setName: 'Marvel Super Heroes Commander',
            total: 866,
            owned: 12,
            copies: 12,
          ),
        ],
      );

      expect(find.text('Marvel Super Heroes'), findsOneWidget);
      expect(find.text('Marvel Super Heroes Commander'), findsOneWidget);
    });

    testWidgets('annonce la complétion, pas seulement le nombre de cartes', (
      tester,
    ) async {
      // C'est le taux qui fait regarder un classeur : « 216 cartes » ne dit pas
      // s'il est presque plein ou à peine entamé.
      await pumpBinder(tester, entries: [shelfEntry()]);

      expect(find.textContaining('216 / 453 cases'), findsOneWidget);
      expect(find.text('48 %'), findsOneWidget);
    });

    testWidgets('chaque classeur porte la carte-vedette de son extension', (
      tester,
    ) async {
      // Cinq lignes de texte gris se ressemblent toutes ; un classeur physique
      // se reconnaît de loin. L'illustration est ce qui distingue une édition
      // d'une autre avant même d'avoir lu son nom.
      await pumpBinder(tester, entries: [shelfEntry(art: _art)]);

      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as CardImageProvider).url, _art);
      expect(
        image.fit,
        BoxFit.cover,
        reason: 'une bannière remplit sa tuile, elle ne s\'y encadre pas',
      );
    });

    testWidgets('le symbole officiel de l\'extension coiffe la tuile', (
      tester,
    ) async {
      // Ce que le bundle aurait été : aucune source ne publie les visuels des
      // produits, et le symbole imprimé sur chaque carte est le marqueur qu'un
      // joueur reconnaît avant d'avoir lu le nom.
      await pumpBinder(
        tester,
        entries: [shelfEntry(art: _art, icon: _icon)],
      );

      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('une extension sans symbole n\'affiche pas de médaillon vide', (
      tester,
    ) async {
      // Les extensions ne sont pas toutes ingérées, et un disque creux dirait
      // qu'il manque quelque chose là où il n'y a rien à dire.
      await pumpBinder(tester, entries: [shelfEntry(art: _art)]);

      expect(find.byType(SvgPicture), findsNothing);
    });

    testWidgets('une édition sans illustration reste une tuile', (
      tester,
    ) async {
      // Réseau absent, impression sans illustration connue : la tuile doit
      // rester une tuile plutôt que devenir un trou dans l'étagère.
      await pumpBinder(tester, entries: [shelfEntry()]);

      expect(find.byType(Image), findsNothing);
      expect(find.text('Marvel Super Heroes'), findsOneWidget);
      expect(find.text('48 %'), findsOneWidget);
    });

    testWidgets('sans classeur, explique pourquoi plutôt que rester vide', (
      tester,
    ) async {
      // Une carte sans édition précisée n'a pas de case. Le dire évite de
      // laisser croire à une collection vide.
      await pumpBinder(tester, unspecified: 3);

      expect(find.text('Aucun classeur'), findsOneWidget);
      expect(
        find.textContaining('À trier'),
        findsWidgets,
        reason:
            'le classeur ouvrant l\'onglet, il doit indiquer la sortie '
            'plutôt que laisser croire à une collection vide',
      );
    });

    testWidgets('sans classeur, la pile à trier reste atteignable', (
      tester,
    ) async {
      // C'est l'état du premier jour, ou d'une collection dictée : aucune
      // carte n'a d'édition, donc aucune n'a de case. La tuile « À trier »
      // est alors la seule sortie — la masquer enfermait l'utilisateur dans
      // un écran qui lui disait d'aller ailleurs sans lui en donner le moyen.
      await pumpBinder(tester, unspecified: 3);

      await tester.tap(find.text('À trier'));
      await tester.pumpAndSettle();

      expect(
        find.text('Aucun classeur'),
        findsNothing,
        reason: 'la tuile doit ouvrir la pile, pas rester sur le message',
      );
    });

    testWidgets('sans classeur ni carte à trier, le message ne renvoie pas '
        'vers une pile inexistante', (tester) async {
      // La tuile « À trier » s'efface quand rien n'attend. Y envoyer
      // l'utilisateur répéterait la faute de l'ancien renvoi vers la vue
      // Liste : nommer une sortie qui n'existe pas.
      await pumpBinder(tester);

      expect(find.text('À trier'), findsNothing);
      expect(find.textContaining('onglet Ajouter'), findsOneWidget);
    });
  });

  group('une page de classeur', () {
    testWidgets('les cases vides occupent leur place', (tester) async {
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [
          cell(number: '1', owned: 1),
          cell(number: '2'),
          cell(number: '3', owned: 2),
        ],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      // Les trois numéros sont affichés, y compris celui qu'on ne possède pas :
      // c'est toute la différence avec une liste de collection.
      expect(find.textContaining('#1'), findsWidgets);
      expect(
        find.textContaining('#2'),
        findsWidgets,
        reason: 'une case vide est ce que le classeur a de plus à dire',
      );
      expect(find.textContaining('#3'), findsWidgets);
    });

    testWidgets('une case vide montre en fantôme la carte qui manque', (
      tester,
    ) async {
      // « #2 » nomme la case, pas la carte : il fallait chercher ailleurs pour
      // savoir laquelle acheter. Le catalogue portant déjà l'illustration de
      // toutes les cases, la montrer ne coûte aucune requête de plus.
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '2', art: _art)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(
        find.textContaining('#2'),
        findsWidgets,
        reason:
            'le numéro reste : le fantôme le complète, il ne le remplace pas',
      );
      final ghost = tester.widget<Opacity>(
        find.ancestor(of: find.byType(Image), matching: find.byType(Opacity)),
      );
      expect(
        ghost.opacity,
        lessThan(0.5),
        reason: 'une case vide ne doit jamais se confondre avec une pleine',
      );
    });

    testWidgets('le fantôme se coupe sans recharger la page', (tester) async {
      // Le réglage ne change pas ce que le serveur rend : l'inscrire dans la
      // clé des pages ferait retélécharger le classeur à chaque bascule.
      final repository = await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '2', art: _art)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();
      final before = repository.requested.length;

      await tester.tap(find.byTooltip('Masquer les cartes manquantes'));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(repository.requested.length, before);
    });

    testWidgets('le brillant se montre, il ne se dit pas', (tester) async {
      // Un symbole annonce qu'une carte est brillante ; un reflet le montre.
      // C'est ce qu'on reconnaît d'un classeur ouvert — une pochette qui
      // accroche la lumière au milieu de cartes mates. Deux cases pour le même
      // numéro, elles, casseraient la grille physique.
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1, hasFoil: true, art: _art)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      final sheen = tester.widget<FoilSheen>(find.byType(FoilSheen));
      expect(sheen.foil, isTrue);
      expect(
        find.byIcon(Icons.auto_awesome),
        findsNothing,
        reason: 'le reflet remplace le symbole, il ne s\'y ajoute pas',
      );
    });

    testWidgets('une carte ordinaire n\'a pas de reflet', (tester) async {
      // Le reflet perdrait tout pouvoir de signal s'il habillait aussi les
      // cartes qu'il doit distinguer.
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1, art: _art)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      expect(tester.widget<FoilSheen>(find.byType(FoilSheen)).foil, isFalse);
    });

    testWidgets('la case montre la carte entière, pas son illustration', (
      tester,
    ) async {
      // Une case de classeur contient une carte — cadre, nom, numéro compris.
      // N'en montrer que l'illustration donnait une planche-contact, jolie mais
      // impossible à reconnaître comme sa propre collection.
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1, art: _art)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as CardImageProvider).url,
        contains('/normal/'),
        reason: 'l\'illustration recadrée est un détail, pas une carte',
      );
    });

    testWidgets('tourner la page atteint le serveur', (tester) async {
      // Un classeur de 453 cases fait 51 pages : les charger toutes pour n'en
      // montrer neuf serait aussi lent qu'inutile.
      final repository = await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Page suivante'));
      await tester.pumpAndSettle();

      // `any` et non `last` : les feuilles voisines sont préchargées, donc la
      // dernière requête est celle d'une voisine.
      expect(
        repository.requested.any((r) => r.setCode == 'msh' && r.page == 2),
        isTrue,
      );
    });

    testWidgets('la première page n\'a pas de précédente', (tester) async {
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      final previous = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.chevron_left),
          matching: find.byType(IconButton),
        ),
      );
      expect(previous.onPressed, isNull);
    });

    testWidgets('on revient à l\'étagère', (tester) async {
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1)],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Retour à l\'étagère'));
      await tester.pumpAndSettle();

      expect(find.textContaining('216 / 453 cases'), findsOneWidget);
    });
  });

  group('les deux régimes de lecture', () {
    Future<FakeBinderRepository> openBinder(WidgetTester tester) async {
      final repository = await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 1, art: _art)],
        firstFilledPage: 42,
      );
      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();
      return repository;
    }

    /// Choisit une option dans l'un des deux menus.
    ///
    /// Les six puces d'autrefois débordaient de l'écran et volaient la hauteur
    /// d'une rangée de cartes ; deux menus tiennent sur une ligne. Le libellé
    /// choisi s'affiche aussi dans le champ, d'où le `last` : c'est l'entrée du
    /// menu déroulé qu'on vise, pas son écho.
    Future<void> choose(WidgetTester tester, Finder menu, String label) async {
      await tester.tap(menu);
      await tester.pumpAndSettle();
      // `textContaining` et non `text` : l'entrée déjà choisie porte en plus
      // la phrase qui annonce le renversement — « Valeur — Les moins chères
      // d'abord ».
      await tester.tap(find.textContaining(label).last);
      await tester.pumpAndSettle();
    }

    final sortMenu = find.byType(DropdownButtonFormField<BinderSort>);
    final finishMenu = find.byType(DropdownButtonFormField<FinishFilter>);

    testWidgets('le tri atteint le serveur', (tester) async {
      // Trier neuf cases côté application trierait une page, pas un classeur.
      final repository = await openBinder(tester);

      await choose(tester, sortMenu, 'Valeur');

      expect(repository.requested.last.sort, BinderSort.price);
    });

    testWidgets('changer d\'ordre ramène à la première page', (tester) async {
      // La page 42 par numéro n'est pas la page 42 par valeur : garder le
      // numéro de page d'un ordre dans un autre n'a aucun sens.
      final repository = await openBinder(tester);

      await tester.tap(find.byTooltip('Page suivante'));
      await tester.pumpAndSettle();
      await choose(tester, sortMenu, 'Nom');

      expect(
        repository.requested.any(
          (r) => r.page == 1 && r.sort == BinderSort.name,
        ),
        isTrue,
      );
    });

    testWidgets('re-choisir un critère renverse le classeur', (tester) async {
      // Le geste de l'ancienne liste : re-sélectionner un tri l'inverse. Sans
      // lui, impossible de partir de la dernière page ou des cartes les moins
      // chères.
      final repository = await openBinder(tester);

      await choose(tester, sortMenu, 'Valeur');
      expect(repository.requested.last.descending, isFalse);

      await choose(tester, sortMenu, 'Valeur');
      expect(repository.requested.last.descending, isTrue);
    });

    testWidgets('changer de critère repart dans son sens naturel', (
      tester,
    ) async {
      final repository = await openBinder(tester);

      await choose(tester, sortMenu, 'Valeur');
      await choose(tester, sortMenu, 'Valeur');
      await choose(tester, sortMenu, 'Nom');

      expect(repository.requested.last.descending, isFalse);
    });

    testWidgets('trier par exemplaires atteint le serveur', (tester) async {
      // Trier neuf cases côté application trierait une page, pas un classeur :
      // les doublons d'une édition sont éparpillés sur cinquante feuilles.
      final repository = await openBinder(tester);

      await choose(tester, sortMenu, 'Exemplaires');

      expect(repository.requested.last.sort, BinderSort.copies);
      expect(
        repository.requested.last.descending,
        isFalse,
        reason: 'le sens naturel est « les plus nombreuses d\'abord »',
      );
    });

    testWidgets('trier par date d\'ajout atteint le serveur', (tester) async {
      // Le geste qui vérifie une saisie : « qu'est-ce que je viens de rentrer ».
      final repository = await openBinder(tester);

      await choose(tester, sortMenu, 'Ajout');

      expect(repository.requested.last.sort, BinderSort.recent);
      expect(
        repository.requested.last.descending,
        isFalse,
        reason: 'le sens naturel est « les dernières entrées d\'abord »',
      );
    });

    testWidgets('trier par exemplaires ne saute nulle part', (tester) async {
      // Comme la valeur et le nom, ce tri inventorie : les cases vides ayant
      // disparu, la première page est pleine par construction.
      final repository = await openBinder(tester);
      repository.jumps.clear();

      await choose(tester, sortMenu, 'Exemplaires');

      expect(repository.jumps, isEmpty);
    });

    testWidgets('le filtre de finition atteint le serveur', (tester) async {
      final repository = await openBinder(tester);

      await choose(tester, finishMenu, 'Brillantes');

      expect(repository.requested.last.finish, FinishFilter.foil);
    });

    testWidgets('filtrer saute à la première feuille non vide', (tester) async {
      // Restreindre au brillant laisse des feuilles entièrement creuses : sur
      // 97 feuilles, ouvrir à la première serait ouvrir sur du vide.
      final repository = await openBinder(tester);

      await choose(tester, finishMenu, 'Brillantes');

      expect(repository.jumps, contains(FinishFilter.foil));
      expect(
        repository.requested.any(
          (r) => r.page == 42 && r.finish == FinishFilter.foil,
        ),
        isTrue,
      );
    });

    testWidgets('trier par valeur ne saute nulle part', (tester) async {
      // Hors du rangement les cases vides disparaissent : la première page est
      // pleine par construction, et la question ne se pose pas.
      final repository = await openBinder(tester);
      repository.jumps.clear();

      await choose(tester, sortMenu, 'Valeur');

      expect(repository.jumps, isEmpty);
    });
  });

  group('la pile à trier', () {
    testWidgets('elle n\'apparaît que s\'il y a quelque chose à trier', (
      tester,
    ) async {
      await pumpBinder(tester, entries: [shelfEntry()]);
      expect(find.text('À trier'), findsNothing);

      await pumpBinder(tester, entries: [shelfEntry()], unspecified: 4);
      expect(find.text('À trier'), findsOneWidget);
    });

    testWidgets('elle ouvre les cartes sans case', (tester) async {
      // Ces cartes n'ont ni extension ni numéro : sans cette pile, elles
      // seraient invisibles dès qu'on regarde sa collection en classeur.
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        unspecified: 2,
        pile: [
          const UnsortedCard(oracleId: 'o1', name: 'Roxxon Brutes', owned: 2),
        ],
      );

      await tester.tap(find.text('À trier'));
      await tester.pumpAndSettle();

      expect(find.text('Roxxon Brutes'), findsOneWidget);
      expect(find.textContaining('lui donner son édition'), findsOneWidget);
    });

    testWidgets('une pile vide se félicite plutôt que de rester muette', (
      tester,
    ) async {
      await pumpBinder(tester, entries: [shelfEntry()], unspecified: 1);

      await tester.tap(find.text('À trier'));
      await tester.pumpAndSettle();

      expect(find.text('Rien à trier'), findsOneWidget);
    });
  });

  group('chercher une carte', () {
    // C'est la seule chose qu'une liste faisait mieux qu'un classeur, et la
    // dernière raison qu'on avait de la garder.
    testWidgets('la frappe atteint le serveur, après l\'anti-rebond', (
      tester,
    ) async {
      final repository = await pumpBinder(tester, entries: [shelfEntry()]);

      await tester.enterText(find.byType(TextField), 'hulk');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(repository.searches, contains('hulk'));
    });

    testWidgets('le résultat dit la page, pas seulement la case', (
      tester,
    ) async {
      // Connaître l'extension et le numéro ne suffit pas : il resterait 97
      // feuilles à tourner.
      final repository = await pumpBinder(tester, entries: [shelfEntry()]);
      repository.found = const [
        BinderFind(
          oracleId: 'o1',
          name: 'World War Hulk',
          setCode: 'msh',
          setName: 'Marvel Super Heroes',
          collectorNumber: '197',
          page: 22,
          owned: 1,
        ),
      ];

      await tester.enterText(find.byType(TextField), 'hulk');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('World War Hulk'), findsOneWidget);
      expect(find.textContaining('page 22'), findsOneWidget);
    });

    testWidgets(
      'revenir d\'un classeur retrouve le champ tel qu\'on l\'a laissé',
      (tester) async {
        // Le défaut : ouvrir un classeur démonte l'étagère et emporte le
        // contrôleur du champ ; en revenant, un nouveau naissait vide alors que
        // la requête survivait dans son provider. L'écran montrait donc les
        // résultats d'une recherche dont le champ paraissait effacé, et il
        // fallait retaper puis vider pour retrouver ses classeurs.
        final repository = await pumpBinder(
          tester,
          entries: [shelfEntry()],
          cells: [cell(number: '197', owned: 1, art: _art)],
        );
        repository.found = const [
          BinderFind(
            oracleId: 'o1',
            name: 'World War Hulk',
            setCode: 'msh',
            collectorNumber: '197',
            page: 22,
            owned: 1,
          ),
        ];

        await tester.enterText(find.byType(TextField), 'hulk');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        await tester.tap(find.text('World War Hulk'));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Retour à l\'étagère'));
        await tester.pumpAndSettle();

        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'hulk',
          reason:
              'le champ et les résultats affichés doivent dire la même chose',
        );
        expect(find.text('World War Hulk'), findsOneWidget);
      },
    );

    testWidgets('effacer le champ ramène les classeurs', (tester) async {
      final repository = await pumpBinder(tester, entries: [shelfEntry()]);
      repository.found = const [
        BinderFind(
          oracleId: 'o1',
          name: 'World War Hulk',
          setCode: 'msh',
          collectorNumber: '197',
          page: 22,
          owned: 1,
        ),
      ];

      await tester.enterText(find.byType(TextField), 'hulk');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // La croix n'apparaissait qu'au prochain rebuild venu d'ailleurs : sans
      // écoute du contrôleur, elle restait absente pendant la frappe.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('Marvel Super Heroes'), findsOneWidget);
    });

    testWidgets('toucher un résultat ouvre le classeur à sa page', (
      tester,
    ) async {
      final repository = await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '197', owned: 1, art: _art)],
      );
      repository.found = const [
        BinderFind(
          oracleId: 'o1',
          name: 'World War Hulk',
          setCode: 'msh',
          collectorNumber: '197',
          page: 22,
          owned: 1,
        ),
      ];

      await tester.enterText(find.byType(TextField), 'hulk');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('World War Hulk'));
      await tester.pumpAndSettle();

      expect(
        repository.requested.any((r) => r.setCode == 'msh' && r.page == 22),
        isTrue,
      );
    });
  });

  group('les gestes sur une case', () {
    // Ajouter, retirer, corriger l'édition vivaient dans la liste, qui n'existe
    // plus. Les perdre aurait été une régression déguisée en simplification —
    // le retrait, notamment, n'existe nulle part ailleurs.
    Future<void> openActions(WidgetTester tester) async {
      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();
    }

    testWidgets('toucher une case ouvre ce qu\'on peut en faire', (
      tester,
    ) async {
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '1', owned: 2, art: _art)],
      );

      await openActions(tester);

      // Le libellé porte la finition : on peut posséder la version normale et
      // vouloir ajouter la brillante, qui se range dans la même case.
      expect(find.text('Ajouter un exemplaire normal'), findsOneWidget);
      expect(find.text('Retirer un exemplaire normal'), findsOneWidget);
      expect(find.text('Corriger l\'édition'), findsOneWidget);
      expect(find.text('Brillante'), findsOneWidget);
    });

    testWidgets('une case vide n\'ouvre rien', (tester) async {
      // Il n'y a rien à ajouter ni à retirer d'une carte qu'on ne possède pas.
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        cells: [cell(number: '2')],
      );

      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('#2').last);
      await tester.pumpAndSettle();

      expect(find.textContaining('Ajouter un exemplaire'), findsNothing);
    });
  });

  group('le compte des pages', () {
    test('une édition se découpe en feuilles de neuf', () {
      expect(shelfEntry(total: 453).pages, 51);
      expect(shelfEntry(total: 866).pages, 97);
      expect(shelfEntry(total: 9).pages, 1);
      expect(shelfEntry(total: 10).pages, 2);
      expect(shelfEntry(total: 0).pages, 0);
    });

    test('la complétion est une part, pas un compte', () {
      expect(shelfEntry(total: 100, owned: 25).completion, 0.25);
      expect(shelfEntry(total: 0, owned: 0).completion, 0);
    });
  });

  group('quand le réseau lâche', () {
    testWidgets('la panne se dit, au lieu de tourner sans fin', (tester) async {
      await pumpBinder(
        tester,
        entries: [shelfEntry()],
        shelfError: const RequestTimedOut(),
      );

      // Ce que l'utilisateur voyait auparavant : un indicateur immobile, pour
      // toujours, sans message ni recours.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Étagère illisible'), findsOneWidget);
      expect(
        find.textContaining('Vérifiez votre connexion'),
        findsOneWidget,
        reason: 'le message doit nommer la cause probable, pas le type Dart',
      );
    });

    testWidgets('un second essai suffit à repartir', (tester) async {
      final repository = await pumpBinder(
        tester,
        entries: [shelfEntry()],
        shelfError: const RequestTimedOut(),
      );
      final before = repository.shelfCalls;

      // Le réseau revient : c'est tout ce qui a changé entre les deux essais.
      repository.shelfError = null;
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();

      expect(
        repository.shelfCalls,
        greaterThan(before),
        reason: 'le bouton doit redemander, pas seulement effacer le message',
      );
      expect(find.text('Marvel Super Heroes'), findsOneWidget);
    });
  });
}
