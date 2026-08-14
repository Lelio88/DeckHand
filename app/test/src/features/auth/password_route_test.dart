/// La route du mot de passe, de l'oubli jusqu'au remplacement.
///
/// **Pourquoi ces tests existent.** Trois manques se tenaient ensemble et
/// formaient une trappe : un mot de passe saisi une seule fois et à l'aveugle,
/// une adresse jamais vérifiée, et aucune récupération. Une frappe de travers à
/// l'inscription, et le compte devenait irrécupérable — avec la collection
/// dedans, qui est ce que ce produit demande des heures à constituer.
///
/// Les tests portent donc autant sur ce que les écrans **refusent de faire**
/// (appeler le serveur quand les deux saisies diffèrent) que sur ce qu'ils
/// affichent : c'est le refus qui ferme la trappe.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/auth/presentation/forgot_password_screen.dart';
import 'package:deckhand/src/features/auth/presentation/reset_password_screen.dart';
import 'package:deckhand/src/features/auth/presentation/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

Future<FakeAuthRepository> pumpAuth(WidgetTester tester, Widget screen) async {
  final auth = FakeAuthRepository();
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

/// Saisit les champs de l'écran de connexion, en mode inscription.
Future<void> fillSignUp(
  WidgetTester tester, {
  required String password,
  required String confirm,
}) async {
  await tester.tap(find.text('Créer un compte'));
  await tester.pumpAndSettle();

  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), 'ami@exemple.fr');
  await tester.enterText(fields.at(1), password);
  await tester.enterText(fields.at(2), confirm);
  await tester.tap(find.widgetWithText(FilledButton, 'Créer le compte'));
  await tester.pumpAndSettle();
}

void main() {
  group('la confirmation du mot de passe', () {
    testWidgets('deux saisies différentes n\'appellent pas le serveur', (
      tester,
    ) async {
      // Le cœur du dispositif : sans ce refus, la faute de frappe part en base
      // et devient le mot de passe du compte, que personne ne connaît.
      final auth = await pumpAuth(tester, const SignInScreen());

      await fillSignUp(
        tester,
        password: 'motdepasse1',
        confirm: 'motdepasse2',
      );

      expect(auth.signUps, isEmpty);
      expect(find.textContaining('ne correspondent pas'), findsOneWidget);
    });

    testWidgets('deux saisies identiques créent bien le compte', (
      tester,
    ) async {
      // Le garde-fou du test précédent : un écran qui refuserait toujours
      // passerait le premier test sans rendre le moindre service.
      final auth = await pumpAuth(tester, const SignInScreen());

      await fillSignUp(
        tester,
        password: 'motdepasse1',
        confirm: 'motdepasse1',
      );

      expect(auth.signUps, [('ami@exemple.fr', 'motdepasse1')]);
    });

    testWidgets('la connexion ne demande pas de confirmation', (tester) async {
      // Se connecter n'est pas s'inscrire : on retape un mot de passe qu'on
      // connaît, et le confirmer serait une friction sans contrepartie.
      await pumpAuth(tester, const SignInScreen());

      expect(find.byType(TextFormField), findsNWidgets(2));
    });
  });

  group('l\'oubli du mot de passe', () {
    testWidgets('l\'écran de connexion y mène', (tester) async {
      await pumpAuth(tester, const SignInScreen());

      await tester.tap(find.text('Mot de passe oublié ?'));
      await tester.pumpAndSettle();

      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    });

    testWidgets('la demande part, et la réponse ne dit pas si le compte '
        'existe', (tester) async {
      // Anti-énumération : le message doit être le même que l'adresse ait un
      // compte ou non, sans quoi cet écran devient un test d'existence de
      // compte à la portée de n'importe qui.
      final auth = await pumpAuth(tester, const ForgotPasswordScreen());

      await tester.enterText(find.byType(TextFormField), 'ami@exemple.fr');
      await tester.tap(find.widgetWithText(FilledButton, 'Envoyer le lien'));
      await tester.pumpAndSettle();

      expect(auth.resetsSent, ['ami@exemple.fr']);
      expect(find.textContaining('Si un compte existe'), findsOneWidget);
    });

    testWidgets('une adresse vide ne part pas', (tester) async {
      final auth = await pumpAuth(tester, const ForgotPasswordScreen());

      await tester.tap(find.widgetWithText(FilledButton, 'Envoyer le lien'));
      await tester.pumpAndSettle();

      expect(auth.resetsSent, isEmpty);
    });
  });

  group('le nouveau mot de passe', () {
    testWidgets('deux saisies différentes ne sont pas enregistrées', (
      tester,
    ) async {
      final auth = await pumpAuth(tester, const ResetPasswordScreen());

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'nouveaumdp1');
      await tester.enterText(fields.at(1), 'nouveaumdp2');
      await tester.tap(find.widgetWithText(FilledButton, 'Changer le mot de passe'));
      await tester.pumpAndSettle();

      expect(auth.passwordsSet, isEmpty);
      expect(find.textContaining('ne correspondent pas'), findsOneWidget);
    });

    testWidgets('deux saisies identiques remplacent le mot de passe', (
      tester,
    ) async {
      final auth = await pumpAuth(tester, const ResetPasswordScreen());

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'nouveaumdp1');
      await tester.enterText(fields.at(1), 'nouveaumdp1');
      await tester.tap(find.widgetWithText(FilledButton, 'Changer le mot de passe'));
      await tester.pumpAndSettle();

      expect(auth.passwordsSet, ['nouveaumdp1']);
    });

    testWidgets('un mot de passe trop court est refusé sans aller au serveur', (
      tester,
    ) async {
      // Le minimum est fixé côté projet Supabase ; le vérifier ici évite un
      // aller-retour réseau pour une réponse connue d'avance.
      final auth = await pumpAuth(tester, const ResetPasswordScreen());

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'court');
      await tester.enterText(fields.at(1), 'court');
      await tester.tap(find.widgetWithText(FilledButton, 'Changer le mot de passe'));
      await tester.pumpAndSettle();

      expect(auth.passwordsSet, isEmpty);
    });
  });

  group('le mode récupération', () {
    test('un lien de réinitialisation le déclenche', () async {
      // Sans ce signal, l'application ouvrirait l'écran d'accueil : la session
      // de récupération est une session valide, et rien ne la distingue d'une
      // connexion ordinaire sinon l'événement qui l'a créée.
      final auth = FakeAuthRepository();
      addTearDown(auth.dispose);
      final container = ProviderContainer(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
      );
      addTearDown(container.dispose);

      expect(container.read(passwordRecoveryProvider), isFalse);

      auth.emitPasswordRecovery();
      await Future<void>.delayed(Duration.zero);

      expect(container.read(passwordRecoveryProvider), isTrue);
    });

    test('il se referme une fois le mot de passe remplacé', () async {
      // Sans quoi l'écran de nouveau mot de passe resterait affiché par-dessus
      // l'application, indéfiniment.
      final auth = FakeAuthRepository();
      addTearDown(auth.dispose);
      final container = ProviderContainer(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
      );
      addTearDown(container.dispose);

      // Lire le drapeau avant d'émettre n'est pas une commodité de test : c'est
      // ce que fait l'application, dont le premier build s'abonne. Émettre
      // d'abord ne prouverait rien, le flux étant sans rejeu — la première
      // version de ce test le faisait et échouait pour cette seule raison.
      expect(container.read(passwordRecoveryProvider), isFalse);

      auth.emitPasswordRecovery();
      await Future<void>.delayed(Duration.zero);
      expect(container.read(passwordRecoveryProvider), isTrue);

      container.read(passwordRecoveryProvider.notifier).clear();

      expect(container.read(passwordRecoveryProvider), isFalse);
    });
  });
}
