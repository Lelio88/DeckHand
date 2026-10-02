/// Les écrans de la mise en conformité : inscription, Google, suppression,
/// informations légales.
///
/// **Ce que ces tests protègent.** Qu'une inscription mène toujours au même
/// écran « Vérifiez vos e-mails » ; que le bouton Google n'apparaisse que là où
/// il fonctionne ; qu'un compte Google lié s'affiche aussitôt, et ne se délie
/// qu'après confirmation ; que la suppression du compte ne parte qu'une fois
/// SUPPRIMER écrit ; que les pages légales s'ouvrent à leur adresse publiée.
library;

import 'package:deckhand/src/common/legal_links.dart';
import 'package:deckhand/src/features/about/presentation/legal_screen.dart';
import 'package:deckhand/src/features/account/presentation/account_actions.dart';
import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/auth/domain/google_link.dart';
import 'package:deckhand/src/features/auth/presentation/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

class _Harness {
  _Harness(this.auth);

  final FakeAuthRepository auth;
  final List<Uri> opened = [];

  Widget wrap(Widget child) => ProviderScope(
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      sessionProvider.overrideWith((ref) => Stream.value(fakeSession())),
      externalLinkOpenerProvider.overrideWithValue((uri) async {
        opened.add(uri);
        return true;
      }),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

Future<_Harness> _pump(
  WidgetTester tester,
  Widget child, {
  FakeAuthRepository? auth,
}) async {
  final repository = auth ?? FakeAuthRepository();
  addTearDown(repository.dispose);
  final harness = _Harness(repository);
  await tester.pumpWidget(harness.wrap(child));
  await tester.pumpAndSettle();
  return harness;
}

Future<void> signUp(WidgetTester tester, String password) async {
  await tester.tap(find.text('Créer un compte'));
  await tester.pumpAndSettle();
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), 'ami@exemple.fr');
  await tester.enterText(fields.at(1), password);
  await tester.enterText(fields.at(2), password);
  await tester.tap(find.widgetWithText(FilledButton, 'Créer le compte'));
  await tester.pumpAndSettle();
}

void main() {
  group('l\'inscription', () {
    testWidgets('mène à « Vérifiez vos e-mails », qui rappelle la connexion', (
      tester,
    ) async {
      final h = await _pump(tester, const SignInScreen());

      await signUp(tester, 'motdepasse1');

      expect(h.auth.signUps, [('ami@exemple.fr', 'motdepasse1')]);
      expect(find.text('Vérifiez vos e-mails'), findsOneWidget);
      expect(find.textContaining('Mot de passe oublié'), findsOneWidget);
    });

    testWidgets('un mot de passe sans chiffre ne part pas', (tester) async {
      final h = await _pump(tester, const SignInScreen());

      await signUp(tester, 'sanschiffre');

      expect(h.auth.signUps, isEmpty);
      expect(find.text('Au moins une lettre et un chiffre'), findsOneWidget);
    });

    testWidgets('la mention renvoie aux conditions et à la politique', (
      tester,
    ) async {
      final h = await _pump(tester, const SignInScreen());

      await tester.ensureVisible(find.text('Conditions d\'utilisation'));
      await tester.tap(find.text('Conditions d\'utilisation'));
      await tester.tap(find.text('Confidentialité'));

      expect(h.opened, [LegalLinks.terms, LegalLinks.privacy]);
    });
  });

  group('Google', () {
    testWidgets('le bouton est absent là où le sélecteur n\'existe pas', (
      tester,
    ) async {
      await _pump(tester, const SignInScreen());

      expect(find.text('Continuer avec Google'), findsNothing);
    });

    testWidgets('le bouton connecte avec Google', (tester) async {
      final auth = FakeAuthRepository()..googleAvailable = true;
      await _pump(tester, const SignInScreen(), auth: auth);

      await tester.tap(find.text('Continuer avec Google'));
      await tester.pumpAndSettle();

      expect(auth.googleSignIns, 1);
    });

    testWidgets('la tuile lie un compte Google', (tester) async {
      final auth = FakeAuthRepository()..googleAvailable = true;
      await _pump(tester, const GoogleLinkTile(), auth: auth);

      await tester.tap(find.text('Lier mon compte Google'));
      await tester.pumpAndSettle();

      expect(auth.googleLinks, 1);
      expect(find.text('Compte Google lié'), findsOneWidget);
      expect(find.text('moi@gmail.com'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Délier'), findsOneWidget);
    });

    testWidgets('délier demande confirmation', (tester) async {
      final auth = FakeAuthRepository()
        ..googleAvailable = true
        ..google = const GoogleLink(email: 'moi@gmail.com', canUnlink: true);
      await _pump(tester, const GoogleLinkTile(), auth: auth);
      final confirmer = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'Délier'),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Délier'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Annuler'));
      await tester.pumpAndSettle();
      expect(auth.googleUnlinks, 0);

      await tester.tap(find.widgetWithText(TextButton, 'Délier'));
      await tester.pumpAndSettle();
      await tester.tap(confirmer);
      await tester.pumpAndSettle();
      expect(auth.googleUnlinks, 1);
      expect(find.text('Lier mon compte Google'), findsOneWidget);
    });

    testWidgets(
      'la tuile ne propose pas de délier le seul moyen de connexion',
      (tester) async {
        final auth = FakeAuthRepository()
          ..googleAvailable = true
          ..google = const GoogleLink(email: 'moi@gmail.com', canUnlink: false);
        await _pump(tester, const GoogleLinkTile(), auth: auth);

        expect(find.text('moi@gmail.com'), findsOneWidget);
        expect(find.text('Délier'), findsNothing);
      },
    );
  });

  group('la suppression du compte', () {
    testWidgets('ne part pas tant que SUPPRIMER n\'est pas écrit', (
      tester,
    ) async {
      final h = await _pump(tester, const DeleteAccountTile());

      await tester.tap(find.text('Supprimer mon compte'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'supprime');
      await tester.pump();
      await tester.tap(find.text('Supprimer définitivement'));
      await tester.pumpAndSettle();

      expect(h.auth.deletions, 0);
    });

    testWidgets('part une fois SUPPRIMER écrit', (tester) async {
      final h = await _pump(tester, const DeleteAccountTile());

      await tester.tap(find.text('Supprimer mon compte'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'SUPPRIMER');
      await tester.pump();
      await tester.tap(find.text('Supprimer définitivement'));
      await tester.pumpAndSettle();

      expect(h.auth.deletions, 1);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  testWidgets('les informations légales ouvrent les pages publiées', (
    tester,
  ) async {
    final h = await _pump(tester, const LegalScreen());

    await tester.tap(find.text('Politique de confidentialité'));
    await tester.tap(find.text('Conditions d\'utilisation'));
    await tester.tap(find.text('Mentions légales'));

    expect(h.opened, [
      LegalLinks.privacy,
      LegalLinks.terms,
      LegalLinks.legalNotice,
    ]);
    expect(
      h.opened.every((u) => u.host == 'deckhand.heianenterprise.com'),
      isTrue,
    );
  });
}
