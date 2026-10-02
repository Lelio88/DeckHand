/// Ce que l'authentification tait, et ce qu'elle garde — la mise en conformité.
///
/// **Ce que ces tests protègent.** Que les messages ne distinguent jamais une
/// adresse inconnue d'un mauvais mot de passe, ni ne recopient le texte brut du
/// serveur ; qu'une inscription sur une adresse déjà prise se lise comme une
/// inscription neuve ; que la session quitte les préférences en clair sans
/// déconnecter personne, et qu'un coffre illisible vaille une déconnexion
/// plutôt qu'un plantage.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/auth/data/session_vault.dart';
import 'package:deckhand/src/features/auth/presentation/auth_error_message.dart';
import 'package:deckhand/src/features/auth/presentation/password_rules.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

class _MemoryVault implements KeyValueVault {
  final Map<String, String> values = {};
  bool broken = false;

  @override
  Future<String?> read(String key) async {
    if (broken) throw PlatformException(code: 'BAD_DECRYPT');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

User _user(List<UserIdentity> identities) => User(
  id: 'u1',
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-09-30T00:00:00Z',
  identities: identities,
);

UserIdentity _identity(String provider, {String? email}) => UserIdentity(
  id: '$provider-id',
  identityId: '$provider-identity',
  userId: 'u1',
  identityData: {'email': ?email},
  provider: provider,
  createdAt: null,
  lastSignInAt: null,
  updatedAt: null,
);

void main() {
  group('les messages d\'erreur', () {
    test('adresse inconnue et mauvais mot de passe disent la même chose', () {
      final inconnue = authErrorMessage(
        const AuthApiException('User not found', code: 'user_not_found'),
      );
      final mauvais = authErrorMessage(
        const AuthApiException(
          'Invalid login credentials',
          code: 'invalid_credentials',
        ),
      );
      expect(inconnue, mauvais);
    });

    test('le texte brut du serveur n\'est jamais recopié', () {
      final message = authErrorMessage(
        const AuthApiException('database error: relation users', code: 'x'),
      );
      expect(message, isNot(contains('database')));
      expect(message, 'Une erreur est survenue. Réessayez.');
    });

    test('une erreur qui n\'est pas d\'authentification reste générique', () {
      expect(
        authErrorMessage(StateError('trace interne')),
        isNot(contains('trace')),
      );
    });

    test('un mot de passe trop faible annonce la vraie règle', () {
      final message = authErrorMessage(
        const AuthApiException('weak', code: 'weak_password'),
      );
      expect(message, contains('lettres et des chiffres'));
    });

    test('aucun message ne dit qu\'une adresse est déjà inscrite', () {
      final message = authErrorMessage(
        const AuthApiException(
          'User already registered',
          code: 'user_already_exists',
        ),
      );
      expect(message.toLowerCase(), isNot(contains('existe')));
      expect(message.toLowerCase(), isNot(contains('déjà inscrit')));
    });
  });

  group('la règle du mot de passe', () {
    test('huit caractères, avec lettres et chiffres', () {
      expect(passwordRuleError('motdepasse1'), isNull);
      expect(passwordRuleError('court1'), isNotNull);
      expect(passwordRuleError('sanschiffre'), isNotNull);
      expect(passwordRuleError('12345678'), isNotNull);
    });
  });

  group('l\'inscription à l\'aveugle', () {
    test('une réponse sans session attend la confirmation', () async {
      expect(await blindSignUp(() async => AuthResponse()), isTrue);
    });

    test('une réponse avec session n\'attend rien', () async {
      expect(
        await blindSignUp(() async => AuthResponse(session: fakeSession())),
        isFalse,
      );
    });

    test('une adresse déjà prise se lit comme une inscription neuve', () async {
      expect(
        await blindSignUp(
          () async => throw const AuthApiException(
            'User already registered',
            code: 'user_already_exists',
          ),
        ),
        isTrue,
      );
    });

    test('une autre erreur remonte', () async {
      expect(
        () => blindSignUp(
          () async =>
              throw const AuthApiException('weak', code: 'weak_password'),
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('le compte Google lié', () {
    test('aucun sans identité Google', () {
      expect(googleLinkOf(_user([_identity('email')])), isNull);
    });

    test('délier est possible s\'il reste un autre moyen de connexion', () {
      final link = googleLinkOf(
        _user([_identity('email'), _identity('google', email: 'a@gmail.com')]),
      );
      expect(link?.email, 'a@gmail.com');
      expect(link?.canUnlink, isTrue);
    });

    test('délier est refusé quand Google est le seul', () {
      final link = googleLinkOf(_user([_identity('google')]));
      expect(link?.canUnlink, isFalse);
    });
  });

  group('la liaison d\'un compte Google', () {
    const dejaLeMien = AuthApiException(
      'Identity is already linked',
      statusCode: '422',
      code: 'identity_already_exists',
    );
    const celuiDUnAutre = AuthApiException(
      'Identity is already linked to another user',
      statusCode: '422',
      code: 'identity_already_exists',
    );

    test('rafraîchit la session une fois la liaison faite', () async {
      final appels = <String>[];
      await linkThenRefresh(
        link: () async => appels.add('lier'),
        refresh: () async => appels.add('rafraîchir'),
      );
      // GoTrue répond à la liaison avec l'utilisateur d'avant : seul le
      // rafraîchissement fait entrer la nouvelle identité dans la session.
      expect(appels, ['lier', 'rafraîchir']);
    });

    test(
      'un compte Google déjà lié à ce compte n\'est pas une erreur',
      () async {
        var rafraichi = false;
        await linkThenRefresh(
          link: () async => throw dejaLeMien,
          refresh: () async => rafraichi = true,
        );
        expect(rafraichi, isTrue);
      },
    );

    test(
      'un compte Google lié à quelqu\'un d\'autre échoue toujours',
      () async {
        var rafraichi = false;
        await expectLater(
          linkThenRefresh(
            link: () async => throw celuiDUnAutre,
            refresh: () async => rafraichi = true,
          ),
          throwsA(same(celuiDUnAutre)),
        );
        expect(rafraichi, isFalse);
      },
    );

    test('le message ne prête pas à un autre le compte qu\'on a déjà', () {
      expect(
        authErrorMessage(dejaLeMien),
        'Ce compte Google est déjà lié à votre compte.',
      );
      expect(
        authErrorMessage(celuiDUnAutre),
        'Ce compte Google est déjà lié à un autre compte DeckHand.',
      );
    });
  });

  group('le coffre de session', () {
    SessionVault vaultFor(_MemoryVault coffre, _MemoryVault ancien) =>
        SessionVault(key: 'sb-x-auth-token', vault: coffre, legacy: ancien);

    test('la session en clair passe au coffre sans déconnecter', () async {
      final coffre = _MemoryVault();
      final ancien = _MemoryVault()..values['sb-x-auth-token'] = 'session';
      final vault = vaultFor(coffre, ancien);

      await vault.initialize();

      expect(await vault.accessToken(), 'session');
      expect(coffre.values['sb-x-auth-token'], 'session');
      expect(ancien.values, isEmpty);
    });

    test('une session déjà au coffre n\'est pas écrasée', () async {
      final coffre = _MemoryVault()..values['sb-x-auth-token'] = 'récente';
      final ancien = _MemoryVault()..values['sb-x-auth-token'] = 'vieille';
      final vault = vaultFor(coffre, ancien);

      await vault.initialize();

      expect(await vault.accessToken(), 'récente');
    });

    test('un coffre illisible vaut une déconnexion, pas un plantage', () async {
      final coffre = _MemoryVault()..broken = true;
      final vault = vaultFor(coffre, _MemoryVault());

      await vault.initialize();

      expect(await vault.hasAccessToken(), isFalse);
    });

    test('la déconnexion efface le coffre et toute copie en clair', () async {
      final coffre = _MemoryVault()..values['sb-x-auth-token'] = 'session';
      final ancien = _MemoryVault()..values['sb-x-auth-token'] = 'copie';
      final vault = vaultFor(coffre, ancien);

      await vault.removePersistedSession();

      expect(coffre.values, isEmpty);
      expect(ancien.values, isEmpty);
    });
  });
}
