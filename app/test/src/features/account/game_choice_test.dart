/// Le choix des jeux joués, et ce qu'il change au sélecteur.
///
/// **Ce que ces tests protègent.** La promesse est « si je ne joue qu'à Pokémon,
/// Pokémon est en premier », et elle se tient en deux endroits qui peuvent
/// mentir séparément : l'écran de choix, qui doit **enregistrer l'ordre coché**,
/// et le sélecteur, qui doit **le rendre**. Un écran qui affiche le bon ordre en
/// écrivant le mauvais serait invisible jusqu'au prochain lancement.
///
/// Les assertions portent donc sur ce que le dépôt a reçu, comme celles du
/// partage, et non sur ce que l'écran montre après coup.
///
/// **Le cas qui compte le plus est celui de la panne** : un réglage de confort
/// posé devant la porte de l'application ne doit jamais empêcher d'entrer.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/account/data/profile_repository.dart';
import 'package:deckhand/src/features/account/presentation/account_screen.dart';
import 'package:deckhand/src/features/account/presentation/game_tile.dart';
import 'package:deckhand/src/features/account/presentation/pick_games_screen.dart';
import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';
import '../binders/binder_view_test.dart' show FakeBinderRepository;

/// Les noms des jeux réellement construits, dans l'ordre de l'écran.
List<String> tileNames(WidgetTester tester) => tester
    .widgetList<GameTile>(find.byType(GameTile))
    .map((tile) => tile.name)
    .toList();

Future<FakeProfileRepository> pumpPicker(
  WidgetTester tester, {
  List<Game>? declared,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(tester.view.reset);

  final profile = FakeProfileRepository(declared: declared);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileRepositoryProvider.overrideWithValue(profile),
        playedGamesProvider.overrideWith((ref) async => declared),
        collectionRepositoryProvider.overrideWithValue(
          FakeCollectionRepository(),
        ),
        binderRepositoryProvider.overrideWithValue(FakeBinderRepository()),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: AccountScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return profile;
}

Future<FakeProfileRepository> pumpChoice(
  WidgetTester tester, {
  List<Game> initial = const [],
  Object? saveError,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(tester.view.reset);

  final profile = FakeProfileRepository()..error = saveError;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileRepositoryProvider.overrideWithValue(profile),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: MaterialApp(home: PickGamesScreen(initial: initial)),
    ),
  );
  await tester.pumpAndSettle();
  return profile;
}

/// Le jeu courant, tel que l'application l'ouvrirait.
Game currentGame(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(PickGamesScreen)),
).read(selectedGameProvider);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('le sélecteur', () {
    testWidgets('met les jeux déclarés devant et replie les autres', (
      tester,
    ) async {
      await pumpPicker(tester, declared: const [Game.pokemon]);

      // Un repli fermé ne construit pas ses tuiles : ce qui est trouvé est
      // exactement ce que l'utilisateur voit.
      expect(tileNames(tester), ['Pokémon']);
      expect(find.text('Autres jeux (7)'), findsOneWidget);
    });

    testWidgets('l\'ordre déclaré est celui de la page', (tester) async {
      await pumpPicker(
        tester,
        declared: const [Game.wankul, Game.magic, Game.lorcana],
      );

      expect(tileNames(tester), [
        'Wankul',
        'Magic: The Gathering',
        'Disney Lorcana',
      ]);
    });

    testWidgets('le repli rend les autres jeux atteignables', (tester) async {
      // **Relégués, jamais masqués.** Un jeu décoché garde une collection et
      // des classeurs ; le rendre introuvable enfermerait l'utilisateur.
      await pumpPicker(tester, declared: const [Game.pokemon]);
      await tester.tap(find.text('Autres jeux (7)'));
      await tester.pumpAndSettle();

      expect(tileNames(tester).length, Game.values.length);
      expect(tileNames(tester), contains('Magic: The Gathering'));
    });

    testWidgets('sans préférence, les huit jeux restent à plat', (
      tester,
    ) async {
      await pumpPicker(tester, declared: null);

      expect(tileNames(tester).length, Game.values.length);
      expect(find.textContaining('Autres jeux'), findsNothing);
    });
  });

  group('l\'étape de choix', () {
    testWidgets('numérote les jeux dans l\'ordre où on les coche', (
      tester,
    ) async {
      await pumpChoice(tester);

      await tester.tap(find.text('Pokémon'));
      await tester.pump();
      await tester.tap(find.text('Magic: The Gathering'));
      await tester.pump();

      final pokemon = find.ancestor(
        of: find.text('Pokémon'),
        matching: find.byType(GameTile),
      );
      expect(
        find.descendant(of: pokemon, matching: find.text('1')),
        findsOneWidget,
      );
      final magic = find.ancestor(
        of: find.text('Magic: The Gathering'),
        matching: find.byType(GameTile),
      );
      expect(
        find.descendant(of: magic, matching: find.text('2')),
        findsOneWidget,
      );
    });

    testWidgets('enregistre l\'ordre coché, pas celui de l\'application', (
      tester,
    ) async {
      final profile = await pumpChoice(tester);

      await tester.tap(find.text('Pokémon'));
      await tester.pump();
      await tester.tap(find.text('Magic: The Gathering'));
      await tester.pump();
      await tester.tap(find.text('Continuer avec 2 jeux'));
      await tester.pumpAndSettle();

      expect(profile.saved.single, [Game.pokemon, Game.magic]);
    });

    testWidgets('le premier jeu déclaré devient celui qu\'on ouvre', (
      tester,
    ) async {
      // Sans cela, on ouvrirait l'application sur Magic après avoir déclaré ne
      // jouer qu'à Pokémon — la promesse tomberait au premier lancement.
      await pumpChoice(tester);

      await tester.tap(find.text('Pokémon'));
      await tester.pump();
      await tester.tap(find.text('Continuer avec Pokémon'));
      await tester.pumpAndSettle();

      expect(currentGame(tester), Game.pokemon);
    });

    testWidgets('décocher puis recocher remet le jeu en dernier', (
      tester,
    ) async {
      final profile = await pumpChoice(tester);

      await tester.tap(find.text('Pokémon'));
      await tester.pump();
      await tester.tap(find.text('Magic: The Gathering'));
      await tester.pump();
      await tester.tap(find.text('Pokémon')); // décoché
      await tester.pump();
      await tester.tap(find.text('Pokémon')); // recoché, donc second
      await tester.pump();
      await tester.tap(find.text('Continuer avec 2 jeux'));
      await tester.pumpAndSettle();

      expect(profile.saved.single, [Game.magic, Game.pokemon]);
    });

    testWidgets('« Plus tard » enregistre une réponse vide', (tester) async {
      // Une réponse vide n'est pas une absence de réponse : la ligne existe,
      // donc l'étape ne reviendra pas au prochain lancement.
      final profile = await pumpChoice(tester);

      await tester.tap(find.text('Plus tard'));
      await tester.pumpAndSettle();

      expect(profile.saved.single, isEmpty);
    });

    testWidgets('on ne peut pas continuer sans avoir rien coché', (
      tester,
    ) async {
      await pumpChoice(tester);

      expect(find.text('Choisissez au moins un jeu'), findsOneWidget);
      final bouton = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(bouton.onPressed, isNull);
    });

    testWidgets('une panne d\'enregistrement se dit et ne bloque pas', (
      tester,
    ) async {
      // L'écran est posé devant la porte de l'application : il doit rester
      // utilisable quand Supabase ne répond pas, et surtout laisser « Plus
      // tard » ouvert.
      await pumpChoice(tester, saveError: Exception('réseau'));

      await tester.tap(find.text('Pokémon'));
      await tester.pump();
      await tester.tap(find.text('Continuer avec Pokémon'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Choix non enregistré'), findsOneWidget);
      final bouton = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(bouton.onPressed, isNotNull);
    });

    testWidgets('rouvert pour modifier, il repart du choix enregistré', (
      tester,
    ) async {
      await pumpChoice(tester, initial: const [Game.lorcana]);

      final lorcana = find.ancestor(
        of: find.text('Disney Lorcana'),
        matching: find.byType(GameTile),
      );
      expect(
        find.descendant(of: lorcana, matching: find.text('1')),
        findsOneWidget,
      );
    });
  });
}
