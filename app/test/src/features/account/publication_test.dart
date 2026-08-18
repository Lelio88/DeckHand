/// Tests du partage d'une collection.
///
/// **Ce qu'ils protègent, c'est une collection qu'on croit privée** — ou une
/// portée qu'on croit restreinte. Un réglage est un objet dangereux quand il
/// ment : s'il s'affiche sur « partagé » sans que le serveur l'ait su, on montre
/// sa collection en croyant l'avoir refermée ; et décocher un classeur sans que
/// rien ne parte laisse ouvert ce qu'on pense avoir masqué. Les assertions
/// portent donc sur **ce que le dépôt a reçu**, jamais sur ce que l'écran
/// affiche.
///
/// Le second point est la distinction entre **« tout »** et **« rien »** : la
/// portée nulle partage l'intégralité, la liste vide ne partage rien. Les
/// aplatir en un seul cas ouvrirait une collection entière par accident.
library;

import 'package:deckhand/src/features/account/presentation/account_screen.dart';
import 'package:deckhand/src/features/account/presentation/sharing_screen.dart';
import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';
import '../binders/binder_view_test.dart' show FakeBinderRepository, shelfEntry;

Future<FakeCollectionRepository> pump(
  WidgetTester tester, {
  required Widget screen,
  bool isPublic = false,
  String? handle,
  List<String>? sharedSets,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1400);
  addTearDown(tester.view.reset);

  final collection = FakeCollectionRepository()
    ..totals = const CollectionSummary(
      totalCards: 451,
      distinctCards: 343,
      totalValueEur: 115.5,
      unspecifiedPrints: 0,
    )
    ..publication_ = Publication(
      collectionId: 'collection-1',
      isPublic: isPublic,
      handle: handle,
      sharedSets: sharedSets,
    );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        collectionRepositoryProvider.overrideWithValue(collection),
        binderRepositoryProvider.overrideWithValue(
          FakeBinderRepository(
            entries: [
              shelfEntry(),
              shelfEntry(setCode: 'mar', setName: 'Marvel Universe'),
            ],
          ),
        ),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: screen)),
    ),
  );
  await tester.pumpAndSettle();

  // **La porte du partage vit sous le sélecteur de jeu**, et celui-ci occupe
  // désormais quatre rangées de tuiles illustrées au lieu de huit lignes de
  // texte. Sur la fenêtre de 800 × 600 du banc de test, elle sort du champ — et
  // un widget hors champ d'une `ListView` n'est pas construit, donc `find.text`
  // ne le voit pas. Le défilement n'est pas une commodité : sans lui, le test
  // échouerait sur une mise en page parfaitement correcte.
  await tester.drag(find.byType(ListView), const Offset(0, -900));
  await tester.pumpAndSettle();
  return collection;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('la porte, depuis le compte', () {
    testWidgets('dit ce qui est partagé sans qu\'on l\'ouvre', (tester) async {
      await pump(tester, screen: const AccountScreen());
      expect(find.text('Vous seul voyez votre collection.'), findsOneWidget);

      await pump(tester, screen: const AccountScreen(), isPublic: true);
      expect(find.text('Partagé — tous vos classeurs'), findsOneWidget);

      await pump(
        tester,
        screen: const AccountScreen(),
        isPublic: true,
        sharedSets: const ['msh'],
      );
      expect(find.text('Partagé — 1 classeur'), findsOneWidget);
    });
  });

  group('publier', () {
    testWidgets('rien n\'est partagé tant qu\'on n\'y touche pas', (
      tester,
    ) async {
      final collection = await pump(tester, screen: const SharingScreen());

      expect(find.text('Vous seul voyez votre collection.'), findsOneWidget);
      expect(collection.lastPublish, isNull);
      // Ni adresse ni portée : régler un partage qui n'existe pas donnerait des
      // réglages sans effet et un lien qui ne mène nulle part.
      expect(find.text('Adresse'), findsNothing);
      expect(find.text('Tous mes classeurs'), findsNothing);
    });

    testWidgets('la bascule atteint le serveur', (tester) async {
      final collection = await pump(tester, screen: const SharingScreen());

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(collection.lastPublish?.id, 'collection-1');
      expect(collection.lastPublish?.isPublic, isTrue);
      expect(find.text('Adresse'), findsOneWidget);
    });

    testWidgets('on peut refermer ce qu\'on a ouvert', (tester) async {
      final collection = await pump(
        tester,
        screen: const SharingScreen(),
        isPublic: true,
      );

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(collection.lastPublish?.isPublic, isFalse);
    });
  });

  group('l\'adresse', () {
    testWidgets('l\'identifiant sert tant qu\'aucun nom n\'est choisi', (
      tester,
    ) async {
      await pump(tester, screen: const SharingScreen(), isPublic: true);
      expect(
        find.textContaining('?c=collection-1'),
        findsOneWidget,
        reason: 'le lien doit être complet et copiable, pas un fragment',
      );
    });

    testWidgets('un nom choisi remplace l\'identifiant dans le lien', (
      tester,
    ) async {
      await pump(
        tester,
        screen: const SharingScreen(),
        isPublic: true,
        handle: 'lelio',
      );
      expect(find.textContaining('?c=lelio'), findsOneWidget);
    });

    testWidgets('un nom mal formé est refusé avant d\'atteindre le serveur', (
      tester,
    ) async {
      // La base a une contrainte de forme ; la traduire en message ici évite de
      // montrer une violation de contrainte à quelqu'un qui a juste mis un
      // espace.
      final collection = await pump(
        tester,
        screen: const SharingScreen(),
        isPublic: true,
      );

      await tester.enterText(find.byType(TextField), 'Mon Nom !');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Minuscules'), findsOneWidget);
      expect(collection.handleWritten, isFalse);
    });

    testWidgets('un nom déjà pris se dit, plutôt que d\'échouer en silence', (
      tester,
    ) async {
      final collection = await pump(
        tester,
        screen: const SharingScreen(),
        isPublic: true,
      );
      collection.handleError = Exception('duplicate key');

      await tester.enterText(find.byType(TextField), 'lelio');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(find.text('Ce nom est déjà pris.'), findsOneWidget);
    });
  });

  group('la portée', () {
    testWidgets('« tous » n\'est pas « tous cochés »', (tester) async {
      // Cocher les classeurs du jour figerait la liste : une extension ajoutée
      // plus tard ne serait pas partagée, sans que rien ne le dise.
      final collection = await pump(
        tester,
        screen: const SharingScreen(),
        isPublic: true,
      );

      await tester.tap(find.text('Tous mes classeurs'));
      await tester.pumpAndSettle();

      expect(
        collection.lastSharedSets,
        isEmpty,
        reason:
            'décocher « tous » ne partage plus rien, et ne fige aucune liste',
      );
    });

    testWidgets('cocher un classeur n\'envoie que celui-là', (tester) async {
      final collection = await pump(
        tester,
        screen: const SharingScreen(),
        isPublic: true,
        sharedSets: const [],
      );

      await tester.tap(find.text('Marvel Universe'));
      await tester.pumpAndSettle();

      expect(collection.lastSharedSets, ['mar']);
    });

    testWidgets('décocher un classeur le retire de ce qui part', (
      tester,
    ) async {
      final collection = await pump(
        tester,
        screen: const SharingScreen(),
        isPublic: true,
        sharedSets: const ['msh', 'mar'],
      );

      await tester.tap(find.text('Marvel Universe'));
      await tester.pumpAndSettle();

      expect(collection.lastSharedSets, ['msh']);
    });
  });
}
