/// Régler ce qu'un booster contient et coûte, depuis la page de profil.
///
/// **Ce que ces tests protègent.** Ces deux valeurs sont les seules du profil
/// dont l'utilisateur est la source ; tout le reste se déduit de la collection.
/// Quatre choses peuvent mentir séparément : le geste (toucher la ligne du
/// réglage ne doit pas faire défiler les chiffres à la place), l'écriture (ce
/// que le dépôt reçoit), le retour au repère, qui est un `null` **écrit** et non
/// une absence d'écriture, et le refus d'une taille nulle, qui diviserait par
/// zéro deux indicateurs.
///
/// Les assertions portent donc sur ce que le dépôt a reçu, comme celles du
/// partage et du choix des jeux.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/account/data/profile_repository.dart';
import 'package:deckhand/src/features/account/domain/collection_figures.dart';
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

/// La tuile de gauche — ce que la collection contient.
const _contenu = Key('tuile-contenu');

/// La tuile de droite — ce qu'elle vaut.
const _valeur = Key('tuile-valeur');

Future<FakeProfileRepository> pumpProfil(
  WidgetTester tester, {
  Map<String, double> prices = const {},
  Map<String, int> sizes = const {},
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(tester.view.reset);

  final profile = FakeProfileRepository(declared: const [Game.magic])
    ..prices = prices
    ..sizes = sizes;
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

/// Amène une tuile sur le chiffre dont le détail contient [motif].
///
/// **Par le contenu, jamais par le rang.** Une première version comptait deux
/// pressions ; l'ajout d'un chiffre au milieu de la série a fait échouer treize
/// tests d'un coup, aucun ne portant sur l'ordre. Ce que ces tests veulent
/// dire, c'est « le chiffre en boosters », pas « le troisième ».
///
/// La pression tombe au **centre** de la tuile, donc sur le chiffre et son
/// label — jamais sur la ligne de détail, qui porte son propre geste.
Future<void> allerAu(WidgetTester tester, Key tuile, Pattern motif) async {
  // La borne est le nombre de chiffres d'une série : au-delà, on a fait le tour
  // sans trouver, et boucler cacherait le défaut derrière un test qui pend.
  for (var i = 0; i < 8; i++) {
    if (find.textContaining(motif).evaluate().isNotEmpty) return;
    await tester.tap(find.byKey(tuile));
    await tester.pumpAndSettle();
  }
  fail('Aucun chiffre ne porte « $motif » après un tour complet.');
}

Future<void> allerAuxBoosters(WidgetTester tester) =>
    allerAu(tester, _valeur, '€ pièce');

/// Ouvre le réglage depuis la ligne qui affiche la dépense en boosters.
///
/// **Le prix se reconstruit par [euros], jamais à la main** : le détail affiché
/// sépare le nombre du symbole par une espace insécable, qu'un littéral tapé au
/// clavier n'a pas — et le test échouerait sur un texte qui se lit pareil.
Future<void> ouvrirLeReglage(WidgetTester tester, {double prix = 6.90}) async {
  await allerAuxBoosters(tester);
  await tester.tap(find.textContaining('à ${euros(prix)} pièce'));
  await tester.pumpAndSettle();
}

Finder get _champTaille => find.byKey(const Key('booster-cartes'));
Finder get _champPrix => find.byKey(const Key('booster-prix'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('le repère', () {
    testWidgets('s’applique tant que rien n’a été déclaré', (tester) async {
      await pumpProfil(tester);
      await allerAuxBoosters(tester);

      // 617 / 14 × 6,90 € — le repère Philibert.
      expect(find.text(euros(617 / 14 * 6.90)), findsOneWidget);
      expect(find.textContaining('à ${euros(6.90)} pièce'), findsOneWidget);
    });

    testWidgets('cède la place au prix déclaré', (tester) async {
      await pumpProfil(tester, prices: const {'magic': 4.20});
      await allerAuxBoosters(tester);

      expect(find.text(euros(617 / 14 * 4.20)), findsOneWidget);
    });

    testWidgets('cède la place à la taille déclarée, des deux côtés', (
      tester,
    ) async {
      // Celui qui n'ouvre que des Collector Boosters n'a pas ouvert le même
      // nombre de boîtes, ni dépensé la même somme.
      await pumpProfil(tester, sizes: const {'magic': 15});

      await allerAu(tester, _contenu, 'cartes le booster');
      expect(find.text('${617 ~/ 15}'), findsOneWidget);
      expect(find.textContaining('à 15 cartes le booster'), findsOneWidget);

      await allerAuxBoosters(tester);
      expect(find.text(euros(617 / 15 * 6.90)), findsOneWidget);
    });
  });

  group('le geste', () {
    testWidgets('toucher la ligne du réglage l’ouvre, sans défiler', (
      tester,
    ) async {
      await pumpProfil(tester);
      await allerAuxBoosters(tester);
      expect(find.text(euros(617 / 14 * 6.90)), findsOneWidget);

      await tester.tap(find.textContaining('à ${euros(6.90)} pièce'));
      await tester.pumpAndSettle();

      // **Le détecteur imbriqué doit gagner l'arène.** S'il perdait, la tuile
      // passerait au chiffre suivant et aucune boîte ne s'ouvrirait — un geste
      // qui fait « autre chose » plutôt que rien, donc le pire des deux.
      expect(find.text('Vos boosters'), findsOneWidget);
    });

    testWidgets('toucher ailleurs sur la tuile fait toujours défiler', (
      tester,
    ) async {
      await pumpProfil(tester);

      expect(find.text(euros(167.83)), findsOneWidget);

      await tester.tap(find.byKey(_valeur));
      await tester.pumpAndSettle();

      // Le chiffre a changé, et aucune boîte ne s'est ouverte. Lequel vient
      // ensuite ne regarde pas ce test.
      expect(find.text(euros(167.83)), findsNothing);
      expect(find.text('Vos boosters'), findsNothing);
    });

    testWidgets('la tuile de gauche ouvre le même réglage', (tester) async {
      // Elle porte aussi un chiffre en boosters, et il dépend de la taille —
      // que l'utilisateur peut corriger depuis la ligne qui l'affiche.
      await pumpProfil(tester);
      await allerAu(tester, _contenu, 'cartes le booster');

      await tester.tap(find.textContaining('cartes le booster'));
      await tester.pumpAndSettle();

      expect(find.text('Vos boosters'), findsOneWidget);
    });

    testWidgets('glisser à gauche avance, glisser à droite revient', (
      tester,
    ) async {
      // Le geste n'allait que dans un sens quel que soit celui du doigt : sept
      // gestes pour revenir d'un chiffre.
      await pumpProfil(tester);
      final premier = euros(167.83);
      expect(find.text(premier), findsOneWidget);

      await tester.fling(find.byKey(_valeur), const Offset(-200, 0), 800);
      await tester.pumpAndSettle();
      expect(find.text(premier), findsNothing);

      await tester.fling(find.byKey(_valeur), const Offset(200, 0), 800);
      await tester.pumpAndSettle();
      expect(find.text(premier), findsOneWidget);
    });

    testWidgets('revenir depuis le premier chiffre passe par le dernier', (
      tester,
    ) async {
      // La série est un anneau : sans le modulo, l'index tomberait à -1.
      await pumpProfil(tester);

      await tester.fling(find.byKey(_valeur), const Offset(200, 0), 800);
      await tester.pumpAndSettle();

      expect(find.text(euros(15.49)), findsOneWidget);
      expect(find.text('la plus chère'), findsOneWidget);
    });
  });

  group('ce qui est enregistré', () {
    testWidgets('un prix saisi part au serveur, virgule comprise', (
      tester,
    ) async {
      final profile = await pumpProfil(tester);
      await ouvrirLeReglage(tester);

      await tester.enterText(_champPrix, '4,20');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(profile.savedBoosters, [('magic', null, 4.20)]);
    });

    testWidgets('une taille saisie part au serveur', (tester) async {
      final profile = await pumpProfil(tester);
      await ouvrirLeReglage(tester);

      await tester.enterText(_champTaille, '15');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(profile.savedBoosters, [('magic', 15, null)]);
    });

    testWidgets('les deux réglages partent en une seule écriture', (
      tester,
    ) async {
      // Deux écritures successives laisseraient une fenêtre où la taille est
      // enregistrée et le prix non, et l'indicateur afficherait un instant une
      // dépense calculée sur un produit et payée sur un autre.
      final profile = await pumpProfil(tester);
      await ouvrirLeReglage(tester);

      await tester.enterText(_champTaille, '15');
      await tester.enterText(_champPrix, '22');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(profile.savedBoosters, [('magic', 15, 22.0)]);
    });

    testWidgets('vider les champs écrit un retour au repère', (tester) async {
      // **Un `null` écrit, pas une absence d'écriture.** Sans cela, on ne
      // pourrait plus revenir au repère qu'en le retapant de mémoire.
      final profile = await pumpProfil(
        tester,
        prices: const {'magic': 4.20},
        sizes: const {'magic': 15},
      );
      await ouvrirLeReglage(tester, prix: 4.20);

      await tester.enterText(_champTaille, '');
      await tester.enterText(_champPrix, '');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(profile.savedBoosters, [('magic', null, null)]);
    });

    testWidgets('annuler n’écrit rien du tout', (tester) async {
      final profile = await pumpProfil(tester);
      await ouvrirLeReglage(tester);

      await tester.enterText(_champPrix, '4,20');
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      expect(profile.savedBoosters, isEmpty);
    });

    testWidgets('une saisie illisible est refusée sans fermer la boîte', (
      tester,
    ) async {
      final profile = await pumpProfil(tester);
      await ouvrirLeReglage(tester);

      await tester.enterText(_champPrix, ',,,');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      // Refermer sur une saisie fautive la perdrait en silence : l'utilisateur
      // croirait avoir enregistré.
      expect(profile.savedBoosters, isEmpty);
      expect(find.text('Vos boosters'), findsOneWidget);
      expect(find.textContaining('par exemple 6,90'), findsOneWidget);
    });

    testWidgets('une taille nulle est refusée, elle diviserait par zéro', (
      tester,
    ) async {
      final profile = await pumpProfil(tester);
      await ouvrirLeReglage(tester);

      await tester.enterText(_champTaille, '0');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(profile.savedBoosters, isEmpty);
      expect(find.textContaining('au moins une'), findsOneWidget);
    });

    testWidgets('les deux erreurs se disent ensemble, pas l’une après l’autre', (
      tester,
    ) async {
      // S'arrêter au premier champ fautif n'afficherait qu'une erreur sur deux,
      // et la seconde n'apparaîtrait qu'après correction de la première.
      final profile = await pumpProfil(tester);
      await ouvrirLeReglage(tester);

      await tester.enterText(_champTaille, '0');
      await tester.enterText(_champPrix, ',,,');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(profile.savedBoosters, isEmpty);
      expect(find.textContaining('au moins une'), findsOneWidget);
      expect(find.textContaining('par exemple 6,90'), findsOneWidget);
    });

    testWidgets('les champs partent vides quand rien n’a été déclaré', (
      tester,
    ) async {
      // Y écrire le repère ferait passer une valeur d'usine pour une réponse de
      // l'utilisateur, et la première validation la graverait.
      await pumpProfil(tester);
      await ouvrirLeReglage(tester);

      expect(tester.widget<TextField>(_champTaille).controller?.text, '');
      expect(tester.widget<TextField>(_champPrix).controller?.text, '');
    });

    testWidgets('les champs portent ce qui a été déclaré', (tester) async {
      await pumpProfil(
        tester,
        prices: const {'magic': 4.20},
        sizes: const {'magic': 15},
      );
      await ouvrirLeReglage(tester, prix: 4.20);

      expect(tester.widget<TextField>(_champTaille).controller?.text, '15');
      expect(tester.widget<TextField>(_champPrix).controller?.text, '4,20');
    });
  });
}
