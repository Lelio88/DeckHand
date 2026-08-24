/// Régler le prix d'un booster depuis la page de profil.
///
/// **Ce que ces tests protègent.** Le prix payé est la seule donnée du profil
/// dont l'utilisateur est la source ; tout le reste se déduit de la collection.
/// Trois choses peuvent mentir séparément : le geste (toucher la ligne du prix
/// ne doit pas faire défiler les chiffres à la place), l'écriture (ce que le
/// dépôt reçoit), et le retour au repère, qui est un `null` **écrit** et non une
/// absence d'écriture.
///
/// Les assertions portent donc sur ce que le dépôt a reçu, comme celles du
/// partage et du choix des jeux.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/account/data/profile_repository.dart';
import 'package:deckhand/src/features/account/presentation/account_screen.dart';
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
import '../binders/binder_view_test.dart' show FakeBinderRepository;

const _totaux = CollectionSummary(
  totalCards: 617,
  distinctCards: 266,
  totalValueEur: 167.83,
  uniqueValueEur: 119.64,
  topCardName: 'Simulacrum Synthesizer',
  topCardEur: 15.49,
);

Future<FakeProfileRepository> pumpProfil(
  WidgetTester tester, {
  Map<String, double> prices = const {},
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(tester.view.reset);

  final profile = FakeProfileRepository(declared: const [Game.magic])
    ..prices = prices;
  final collection = FakeCollectionRepository()..totals = _totaux;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileRepositoryProvider.overrideWithValue(profile),
        playedGamesProvider.overrideWith((ref) async => const [Game.magic]),
        collectionRepositoryProvider.overrideWithValue(collection),
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

/// Amène la tuile de droite sur le chiffre « en boosters », qui est le
/// troisième de sa série.
Future<void> allerAuxBoosters(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await tester.tap(find.byIcon(Icons.euro));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('le repère', () {
    testWidgets('s’applique tant que rien n’a été déclaré', (tester) async {
      await pumpProfil(tester);
      await allerAuxBoosters(tester);

      // 617 / 14 × 6,90 € — le repère Philibert.
      expect(find.text((617 / 14 * 6.90).toStringAsFixed(2)), findsOneWidget);
      expect(find.textContaining('à 6.90 € pièce'), findsOneWidget);
    });

    testWidgets('cède la place au prix déclaré', (tester) async {
      await pumpProfil(tester, prices: const {'magic': 4.20});
      await allerAuxBoosters(tester);

      expect(find.text((617 / 14 * 4.20).toStringAsFixed(2)), findsOneWidget);
    });
  });

  group('le geste', () {
    testWidgets('toucher la ligne du prix ouvre le réglage, sans défiler', (
      tester,
    ) async {
      await pumpProfil(tester);
      await allerAuxBoosters(tester);
      final avant = find.text((617 / 14 * 6.90).toStringAsFixed(2));
      expect(avant, findsOneWidget);

      await tester.tap(find.textContaining('à 6.90 € pièce'));
      await tester.pumpAndSettle();

      // **Le détecteur imbriqué doit gagner l'arène.** S'il perdait, la tuile
      // passerait au chiffre suivant et aucune boîte ne s'ouvrirait — un geste
      // qui fait « autre chose » plutôt que rien, donc le pire des deux.
      expect(find.text('Le prix que vous payez'), findsOneWidget);
    });

    testWidgets('toucher ailleurs sur la tuile fait toujours défiler', (
      tester,
    ) async {
      await pumpProfil(tester);

      await tester.tap(find.byIcon(Icons.euro));
      await tester.pumpAndSettle();

      expect(find.text('119.64'), findsOneWidget);
      expect(find.text('Le prix que vous payez'), findsNothing);
    });

    testWidgets('la tuile de gauche n’ouvre aucun réglage', (tester) async {
      await pumpProfil(tester);
      // Son troisième chiffre est aussi un booster, mais il ne dépend que de la
      // taille — un fait publié, que l'utilisateur n'a pas à corriger.
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byIcon(Icons.style_outlined));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.textContaining('cartes le booster'));
      await tester.pumpAndSettle();

      expect(find.text('Le prix que vous payez'), findsNothing);
    });
  });

  group('ce qui est enregistré', () {
    testWidgets('un prix saisi part au serveur, virgule comprise', (
      tester,
    ) async {
      final profile = await pumpProfil(tester);
      await allerAuxBoosters(tester);
      await tester.tap(find.textContaining('à 6.90 € pièce'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '4,20');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(profile.savedPrices, [('magic', 4.20)]);
    });

    testWidgets('vider le champ écrit un retour au repère', (tester) async {
      // **Un `null` écrit, pas une absence d'écriture.** Sans cela, on ne
      // pourrait plus revenir au repère qu'en le retapant de mémoire.
      final profile = await pumpProfil(tester, prices: const {'magic': 4.20});
      await allerAuxBoosters(tester);
      await tester.tap(find.textContaining('à 4.20 € pièce'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(profile.savedPrices, [('magic', null)]);
    });

    testWidgets('annuler n’écrit rien du tout', (tester) async {
      final profile = await pumpProfil(tester);
      await allerAuxBoosters(tester);
      await tester.tap(find.textContaining('à 6.90 € pièce'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '4,20');
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      expect(profile.savedPrices, isEmpty);
    });

    testWidgets('une saisie illisible est refusée sans fermer la boîte', (
      tester,
    ) async {
      final profile = await pumpProfil(tester);
      await allerAuxBoosters(tester);
      await tester.tap(find.textContaining('à 6.90 € pièce'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), ',,,');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      // Refermer sur une saisie fautive la perdrait en silence : l'utilisateur
      // croirait avoir enregistré.
      expect(profile.savedPrices, isEmpty);
      expect(find.text('Le prix que vous payez'), findsOneWidget);
      expect(find.textContaining('par exemple 6,90'), findsOneWidget);
    });

    testWidgets('le champ part vide quand rien n’a été déclaré', (
      tester,
    ) async {
      // Y écrire le repère ferait passer une valeur d'usine pour une réponse de
      // l'utilisateur, et la première validation la graverait.
      await pumpProfil(tester);
      await allerAuxBoosters(tester);
      await tester.tap(find.textContaining('à 6.90 € pièce'));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
          '');
    });
  });
}
