/// Tests de l'écran de collection.
///
/// **Ce que ces tests surveillent a changé avec la pagination.** Le calcul des
/// agrégats est passé en SQL ; le risque n'est plus une addition fausse mais un
/// critère qui n'atteint pas la base — l'écran affiche « trié par valeur », le
/// dépôt reçoit « par nom », et rien ne le signale : la liste est plausible.
/// C'est le défaut déjà rencontré sur les filtres de decks, invisible à
/// `flutter analyze` comme à l'œil.
///
/// Second point de vigilance : le bandeau de totaux porte sur la collection
/// entière. Filtrer la liste ne doit pas le faire varier, sans quoi chercher une
/// carte donnerait l'impression d'en avoir perdu mille.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:deckhand/src/features/collection/presentation/collection_screen.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';
import '../binders/binder_view_test.dart' show FakeBinderRepository;

CollectionEntry entry({
  String oracleId = 'oracle-1',
  String name = 'Lightning Bolt',
  String? printedName = 'Foudre',
  int quantity = 2,
  double? unitPrice = 1.12,
  String? printId,
  String? setCode,
  String? setName,
  String? collectorNumber,
  bool isFoil = false,
}) => CollectionEntry(
  oracleId: oracleId,
  name: name,
  printedName: printedName,
  typeLine: 'Instant',
  quantity: quantity,
  unitPriceEur: unitPrice,
  linePriceEur: unitPrice == null ? null : unitPrice * quantity,
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  printId: printId,
  setCode: setCode,
  setName: setName,
  collectorNumber: collectorNumber,
  isFoil: isFoil,
);

CardPrinting printing({
  String printId = 'print-mh2',
  String setCode = 'mh2',
  String? setName = 'Modern Horizons 2',
  String? collectorNumber = '123',
  double? price = 3.40,
  int owned = 0,
}) => CardPrinting(
  printId: printId,
  setCode: setCode,
  setName: setName,
  collectorNumber: collectorNumber,
  lang: 'en',
  priceEur: price,
  owned: owned,
);

/// Dernier faux dépôt d'éditions posé, pour les tests qui ouvrent le sélecteur.
late FakePrintingRepository printings;

/// Force la vue liste, dont le classeur a pris la place par défaut.
///
/// Les tests ci-dessous portent sur la liste — recherche, tris, filtres — et
/// non sur la vue qui ouvre l'onglet. Les écrire en tapant d'abord sur la puce
/// « Liste » aurait ajouté un geste sans rapport à chacun d'eux.
class ListModeFirst extends SelectedCollectionMode {
  @override
  CollectionMode build() => CollectionMode.list;
}

Future<FakeCollectionRepository> pumpCollection(
  WidgetTester tester, {
  List<CollectionEntry> entries = const [],
  CollectionSummary? totals,
  List<CardPrinting> availablePrintings = const [],
}) async {
  final repository = FakeCollectionRepository()
    ..entries = entries
    ..totals =
        totals ??
        (entries.isEmpty
            ? CollectionSummary.empty
            : CollectionSummary(
                totalCards: entries.fold(0, (sum, e) => sum + e.quantity),
                distinctCards: entries.length,
                totalValueEur: entries.fold(
                  0.0,
                  (sum, e) => sum + (e.linePriceEur ?? 0),
                ),
              ));

  printings = FakePrintingRepository()..printings = availablePrintings;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        collectionRepositoryProvider.overrideWithValue(repository),
        printingRepositoryProvider.overrideWithValue(printings),
        collectionModeProvider.overrideWith(ListModeFirst.new),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: CollectionScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

/// Saisit une recherche et laisse passer l'anti-rebond.
Future<void> search(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('une collection vide invite à commencer', (tester) async {
    await pumpCollection(tester);
    expect(find.textContaining('collection est vide'), findsOneWidget);
  });

  testWidgets('les totaux affichés sont ceux de la collection entière', (
    tester,
  ) async {
    // La page ne porte qu'une carte, la collection en compte 54 : c'est le
    // serveur qui fait foi, pas ce qui est affiché.
    await pumpCollection(
      tester,
      entries: [entry()],
      totals: const CollectionSummary(
        totalCards: 54,
        distinctCards: 20,
        totalValueEur: 49.40,
      ),
    );

    expect(find.text('54 cartes'), findsOneWidget);
    expect(find.textContaining('20 références distinctes'), findsOneWidget);
    expect(find.text('49.40 €'), findsOneWidget);
  });

  testWidgets('le nom français prime, le nom oracle reste visible', (
    tester,
  ) async {
    await pumpCollection(tester, entries: [entry()]);

    expect(find.text('Foudre'), findsOneWidget);
    expect(find.text('Lightning Bolt'), findsOneWidget);
  });

  testWidgets(
    'le nom oracle n\'est pas répété quand il n\'y a pas de traduction',
    (tester) async {
      await pumpCollection(
        tester,
        entries: [entry(name: 'Sol Ring', printedName: null)],
      );

      expect(find.text('Sol Ring'), findsOneWidget);
    },
  );

  testWidgets('une carte sans cote s\'affiche sans prix inventé', (
    tester,
  ) async {
    await pumpCollection(
      tester,
      entries: [entry(quantity: 3, unitPrice: null)],
    );

    expect(
      find.text('—'),
      findsOneWidget,
      reason:
          'un tiret dit l\'absence de cote ; un zéro ferait croire à une '
          'carte sans valeur',
    );
  });

  testWidgets('ajouter un exemplaire passe par le dépôt', (tester) async {
    final repository = await pumpCollection(tester, entries: [entry()]);

    await tester.tap(find.byTooltip('Ajouter un exemplaire'));
    await tester.pumpAndSettle();

    expect(repository.quantities[('oracle-1', null)], 1);
  });

  testWidgets('retirer un exemplaire passe par le dépôt', (tester) async {
    final repository = await pumpCollection(tester, entries: [entry()]);
    await repository.add('oracle-1', quantity: 2);

    await tester.tap(find.byTooltip('Retirer un exemplaire'));
    await tester.pumpAndSettle();

    expect(repository.quantities[('oracle-1', null)], 1);
  });

  testWidgets('l\'onglet ouvre sur le classeur, pas sur la liste', (
    tester,
  ) async {
    // Le classeur est la vue qui montre ce qui manque ; la liste reste
    // atteignable parce qu'elle seule cherche par nom, trie par valeur, et
    // donne accès aux cartes sans édition — lesquelles n'ont aucune case.
    final repository = FakeCollectionRepository()
      ..entries = [entry()]
      ..totals = const CollectionSummary(
        totalCards: 2,
        distinctCards: 1,
        totalValueEur: 2.24,
      );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          collectionRepositoryProvider.overrideWithValue(repository),
          printingRepositoryProvider.overrideWithValue(
            FakePrintingRepository(),
          ),
          binderRepositoryProvider.overrideWithValue(FakeBinderRepository()),
          sessionProvider.overrideWith(
            (ref) => Stream<Session?>.value(fakeSession()),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: CollectionScreen())),
      ),
    );
    await tester.pumpAndSettle();

    // L'étagère est vide dans ce fake : c'est son message qui prouve qu'on est
    // bien dans le classeur, et non dans la liste.
    expect(find.text('Aucun classeur'), findsOneWidget);
    expect(find.byTooltip('Trier'), findsNothing);
  });

  group('la consultation atteint le dépôt', () {
    testWidgets('la recherche est transmise, pas seulement affichée', (
      tester,
    ) async {
      final repository = await pumpCollection(tester, entries: [entry()]);

      await search(tester, 'foudre');

      expect(
        repository.lastQuery,
        'foudre',
        reason:
            'filtrer côté écran seulement afficherait une liste non filtrée',
      );
    });

    testWidgets('le tri est transmis au dépôt', (tester) async {
      final repository = await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valeur').last);
      await tester.pumpAndSettle();

      expect(repository.lastSort, CollectionSort.price);
    });

    testWidgets('ranger par numéro est un tri offert', (tester) async {
      // Les autres tris répondent à des questions d'inventaire ; celui-ci
      // répond à « où va cette carte ? », une carte à la main devant sa boîte.
      final repository = await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Numéro').last);
      await tester.pumpAndSettle();

      expect(repository.lastSort, CollectionSort.number);
    });

    testWidgets('ranger comme un classeur est un tri offert', (tester) async {
      // Le numéro seul mêle les classeurs : MAR #43 et MSH #43 se suivraient,
      // alors qu'ils sont dans deux volumes différents. Ce tri-ci range par
      // extension d'abord, comme on range une boîte.
      final repository = await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Classeur').last);
      await tester.pumpAndSettle();

      expect(repository.lastSort, CollectionSort.binder);
      expect(
        repository.lastDescending,
        isFalse,
        reason: 'un classeur se lit de la première page à la dernière',
      );
    });

    testWidgets('re-choisir le même critère inverse la liste', (tester) async {
      // Le geste qu'on fait sans y penser. Il évite un second contrôle
      // « croissant / décroissant » qui n'aurait de sens qu'accolé au premier.
      final repository = await pumpCollection(tester, entries: [entry()]);

      Future<void> chooseValeur() async {
        await tester.tap(find.byTooltip('Trier'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Valeur').last);
        await tester.pumpAndSettle();
      }

      await chooseValeur();
      expect(
        repository.lastDescending,
        isTrue,
        reason: 'on cherche d\'abord ses cartes les plus chères',
      );

      await chooseValeur();
      expect(repository.lastDescending, isFalse);
    });

    testWidgets('changer de critère repart dans son sens naturel', (
      tester,
    ) async {
      final repository = await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valeur').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nom').last);
      await tester.pumpAndSettle();

      expect(
        repository.lastDescending,
        isFalse,
        reason:
            'les noms se lisent de A à Z, pas dans le sens hérité du '
            'critère précédent',
      );
    });

    testWidgets('la rareté est un tri offert', (tester) async {
      final repository = await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rareté').last);
      await tester.pumpAndSettle();

      expect(repository.lastSort, CollectionSort.rarity);
    });

    testWidgets('la finition et la pleine illustration sont transmises', (
      tester,
    ) async {
      final repository = await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.text('Brillantes'));
      await tester.pumpAndSettle();
      expect(repository.lastFinish, FinishFilter.foil);

      await tester.tap(find.text('Pleine illustration'));
      await tester.pumpAndSettle();
      expect(repository.lastFullArt, isTrue);
    });

    testWidgets('le tri choisi reste affiché', (tester) async {
      await pumpCollection(tester, entries: [entry()]);

      await tester.tap(find.byTooltip('Trier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quantité').last);
      await tester.pumpAndSettle();

      expect(find.text('Quantité'), findsOneWidget);
    });

    testWidgets('une recherche sans résultat le dit', (tester) async {
      final repository = await pumpCollection(tester, entries: [entry()]);
      repository.entries = const [];

      await search(tester, 'zzzz');

      expect(find.textContaining('Aucune carte ne correspond'), findsOneWidget);
    });

    testWidgets('filtrer ne modifie pas les totaux de la collection', (
      tester,
    ) async {
      final repository = await pumpCollection(
        tester,
        entries: [entry()],
        totals: const CollectionSummary(
          totalCards: 54,
          distinctCards: 20,
          totalValueEur: 49.40,
        ),
      );
      repository.entries = const [];

      await search(tester, 'zzzz');

      expect(
        find.text('54 cartes'),
        findsOneWidget,
        reason:
            'le bandeau porte sur la collection entière : le voir tomber à zéro '
            'en cherchant donnerait l\'impression d\'avoir tout perdu',
      );
    });
  });

  group('atteindre ce qui reste à préciser', () {
    // Compter les exemplaires sans édition sans donner le moyen de les
    // atteindre laissait un chantier visible et inaccessible : sur une
    // collection de deux mille cartes, les retrouver un par un dans la liste
    // n'est pas un geste qu'on fait.
    CollectionSummary totalsWith(int unspecified) => CollectionSummary(
      totalCards: 10,
      distinctCards: 8,
      totalValueEur: 12,
      unspecifiedPrints: unspecified,
    );

    testWidgets('le filtre restreint la liste côté dépôt', (tester) async {
      final repository = await pumpCollection(
        tester,
        entries: [
          entry(printId: 'print-mh2', setCode: 'mh2'),
          entry(),
        ],
        totals: totalsWith(3),
      );

      await tester.tap(find.text('À préciser · 3'));
      await tester.pumpAndSettle();

      expect(
        repository.lastUnspecifiedOnly,
        isTrue,
        reason:
            'filtrer la page reçue viderait les pages où rien n\'est à '
            'préciser en croyant la collection épuisée',
      );
    });

    testWidgets('sans rien à préciser, le filtre ne s\'affiche pas', (
      tester,
    ) async {
      await pumpCollection(
        tester,
        entries: [entry(printId: 'print-mh2', setCode: 'mh2')],
        totals: totalsWith(0),
      );

      expect(find.textContaining('À préciser'), findsNothing);
    });

    testWidgets('le filtre reste retirable une fois le travail fait', (
      tester,
    ) async {
      // Il ne suffit pas de l'afficher quand il reste des cartes : après avoir
      // précisé la dernière, le bouton disparaîtrait en laissant la liste
      // filtrée et vide, sans moyen d'en sortir.
      final repository = await pumpCollection(
        tester,
        entries: [entry()],
        totals: totalsWith(1),
      );

      await tester.tap(find.text('À préciser · 1'));
      await tester.pumpAndSettle();

      repository.totals = totalsWith(0);
      await tester.tap(find.byType(RefreshIndicator));
      await tester.pumpAndSettle();

      expect(find.textContaining('À préciser'), findsOneWidget);
    });

    testWidgets('une liste filtrée vide dit ce qu\'elle cherchait', (
      tester,
    ) async {
      await pumpCollection(
        tester,
        entries: [entry(printId: 'print-mh2', setCode: 'mh2')],
        totals: totalsWith(1),
      );

      await tester.tap(find.text('À préciser · 1'));
      await tester.pumpAndSettle();

      expect(
        find.text('Toutes vos cartes ont leur édition précisée.'),
        findsOneWidget,
        reason: 'sans cela la collection paraîtrait vide',
      );
    });
  });

  group('le brillant se voit sans se lire', () {
    // Un « · foil » en petits caractères ne se lit qu'une fois qu'on l'a
    // cherché — or on ne cherche pas en faisant défiler. Le brillant vaut
    // couramment le double ou le triple de sa jumelle, et c'est ce qui
    // distingue deux lignes par ailleurs identiques.
    BoxDecoration decorationOf(WidgetTester tester) =>
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.text('Foudre'),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;

    CollectionEntry foilEntry({bool isFoil = true}) => entry(
      printId: 'print-mh2',
      setCode: 'mh2',
      setName: 'Modern Horizons 2',
      collectorNumber: '123',
      isFoil: isFoil,
    );

    testWidgets('une ligne brillante porte un fond irisé', (tester) async {
      await pumpCollection(tester, entries: [foilEntry()]);

      final decoration = decorationOf(tester);
      expect(decoration.gradient, isNotNull);
      expect(decoration.border, isNotNull);
    });

    testWidgets('une ligne ordinaire garde son fond uni', (tester) async {
      await pumpCollection(tester, entries: [foilEntry(isFoil: false)]);

      final decoration = decorationOf(tester);
      expect(
        decoration.gradient,
        isNull,
        reason: 'un fond irisé partout ne distinguerait plus rien',
      );
      expect(decoration.color, isNotNull);
    });

    testWidgets('le mot accompagne le fond, sans icône', (tester) async {
      // L'icône a été retirée : le fond irisé porte déjà le signal, et le mot
      // le nomme. Une troisième marque pour la même information encombrait une
      // ligne qui doit tenir sur la largeur d'un téléphone.
      await pumpCollection(tester, entries: [foilEntry()]);
      expect(find.textContaining('foil'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsNothing);

      await pumpCollection(tester, entries: [foilEntry(isFoil: false)]);
      expect(find.textContaining('foil'), findsNothing);
    });
  });

  group('les éditions', () {
    testWidgets('une édition connue est affichée sur la ligne', (tester) async {
      await pumpCollection(
        tester,
        entries: [
          entry(
            printId: 'print-mh2',
            setCode: 'mh2',
            setName: 'Modern Horizons 2',
            collectorNumber: '123',
          ),
        ],
      );

      expect(find.textContaining('Modern Horizons 2'), findsOneWidget);
      expect(
        find.text('#123'),
        findsOneWidget,
        reason: 'le numéro accompagne le nom, là où on le cherche pour ranger',
      );
    });

    testWidgets('une édition inconnue invite à la préciser', (tester) async {
      await pumpCollection(tester, entries: [entry()]);

      expect(find.text('Édition non précisée'), findsOneWidget);
    });

    testWidgets('choisir une édition la transmet au dépôt', (tester) async {
      final repository = await pumpCollection(
        tester,
        entries: [entry()],
        availablePrintings: [printing()],
      );

      await tester.tap(find.text('Édition non précisée'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Modern Horizons 2').last);
      await tester.pumpAndSettle();

      expect(
        repository.lastPrintingMove,
        (oracleId: 'oracle-1', from: null, to: 'print-mh2', quantity: null),
        reason:
            'sans ce déplacement, le choix resterait affiché mais non enregistré',
      );
    });

    testWidgets('ajouter un exemplaire vise la bonne édition', (tester) async {
      final repository = await pumpCollection(
        tester,
        entries: [entry(printId: 'print-mh2', setCode: 'mh2')],
      );

      await tester.tap(find.byTooltip('Ajouter un exemplaire'));
      await tester.pumpAndSettle();

      expect(
        repository.quantities[('oracle-1', 'print-mh2')],
        1,
        reason:
            'ajouter depuis une ligne d\'édition ne doit pas créer une '
            'ligne sans édition',
      );
    });

    testWidgets('les exemplaires sans édition sont signalés dans les totaux', (
      tester,
    ) async {
      await pumpCollection(
        tester,
        entries: [entry()],
        totals: const CollectionSummary(
          totalCards: 54,
          distinctCards: 20,
          totalValueEur: 49.40,
          unspecifiedPrints: 12,
        ),
      );

      expect(find.textContaining('12 sans édition'), findsOneWidget);
    });
  });
}
