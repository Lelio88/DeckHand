/// Tests du classeur partagé.
///
/// **Ce qu'ils protègent est double.** D'abord qu'un lien de partage interroge
/// bien la collection *désignée* : sans cela la page montrerait celle du
/// visiteur sous le nom d'un autre — ou rien, ce qui ressemble à une panne.
/// Ensuite qu'on n'y modifie rien : les gestes d'écriture du classeur n'ont pas
/// de sens chez quelqu'un d'autre, et le serveur les refuserait de toute façon,
/// mais un bouton qui échoue vaut moins qu'un bouton absent.
library;

import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/binders/presentation/public_binder_screen.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fakes.dart';
import 'binder_view_test.dart' show FakeBinderRepository, cell, shelfEntry;

Future<FakeBinderRepository> pumpPublic(
  WidgetTester tester, {
  String collectionId = 'collection-2',
  int unspecified = 3,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1000);
  addTearDown(tester.view.reset);

  final repository = FakeBinderRepository(
    entries: [shelfEntry()],
    cells: [cell(number: '1', owned: 1)],
  );
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
      ],
      child: MaterialApp(home: PublicBinderScreen(collectionId: collectionId)),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('lire une adresse de partage', () {
    test('le paramètre se trouve dans la requête', () {
      expect(collectionFromUrl(Uri.parse('https://x.app/?c=abc')), 'abc');
    });

    test('et aussi derrière le dièse', () {
      // Flutter sert ses routes tantôt derrière un `#`, tantôt non : un lien ne
      // doit pas cesser de fonctionner parce que la stratégie d'URL a changé.
      expect(collectionFromUrl(Uri.parse('https://x.app/#/?c=abc')), 'abc');
    });

    test('une adresse ordinaire ne désigne rien', () {
      expect(collectionFromUrl(Uri.parse('https://x.app/')), isNull);
      expect(collectionFromUrl(Uri.parse('https://x.app/?c=')), isNull);
    });
  });

  group('le classeur partagé', () {
    testWidgets('interroge la collection désignée, pas celle du visiteur', (
      tester,
    ) async {
      final repository = await pumpPublic(tester);

      expect(
        repository.lastCollection,
        'collection-2',
        reason:
            'sans ce paramètre le serveur rend la collection du visiteur, '
            'donc rien du tout pour un inconnu',
      );
    });

    testWidgets('crédite ses sources à même la page', (tester) async {
      // Le garde-fou §IV.2 tenait par un écran « à propos » qu'un visiteur
      // n'ouvrira jamais.
      await pumpPublic(tester);
      expect(find.textContaining('Scryfall'), findsOneWidget);
    });

    testWidgets('ne montre pas la pile à trier du visiteur', (tester) async {
      await pumpPublic(tester, unspecified: 3);
      expect(
        find.text('À trier'),
        findsNothing,
        reason: 'elle compte les cartes du visiteur, pas celles qu\'on regarde',
      );
    });

    testWidgets('n\'offre pas de chercher dans une collection étrangère', (
      tester,
    ) async {
      await pumpPublic(tester);
      expect(find.textContaining('Chercher une carte'), findsNothing);
    });

    testWidgets('une collection fermée ne se distingue pas d\'une vide', (
      tester,
    ) async {
      // Dire « celle-ci existe mais elle est privée » confirmerait son
      // existence à qui essaie des adresses au hasard. Et la consigne de saisie
      // s'adresse à quelqu'un qui n'est pas là.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1000);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            binderRepositoryProvider.overrideWithValue(FakeBinderRepository()),
            collectionRepositoryProvider.overrideWithValue(
              FakeCollectionRepository(),
            ),
            printingRepositoryProvider.overrideWithValue(
              FakePrintingRepository(),
            ),
          ],
          child: const MaterialApp(
            home: PublicBinderScreen(collectionId: 'collection-2'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rien à voir ici'), findsOneWidget);
      expect(find.textContaining('onglet Ajouter'), findsNothing);
    });

    testWidgets('toucher une case l\'agrandit au lieu de l\'ouvrir', (
      tester,
    ) async {
      await pumpPublic(tester);
      await tester.tap(find.text('Marvel Super Heroes'));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('#1').first);
      await tester.pumpAndSettle();

      // La feuille d'actions écrirait dans la collection d'un autre.
      expect(find.text('Retirer un exemplaire'), findsNothing);
    });
  });
}
