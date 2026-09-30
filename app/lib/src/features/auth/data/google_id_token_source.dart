/// D'où viennent les jetons d'identité Google : le sélecteur de compte natif,
/// ou un faux dans les tests.
///
/// **Un jeton, pas une session.** Google rend un jeton d'identité (JWT signé,
/// destiné à [kGoogleWebClientId]) ; `AuthRepository` l'échange contre une
/// session Supabase (`signInWithIdToken`). Ni redirection ni secret Google
/// côté application : le secret du client Web reste dans le coffre, inutilisé.
///
/// **L'interface de la plateforme, et non le paquet `google_sign_in`.** Celui-ci
/// embarque aussi une version web qui charge le script de Google dès le
/// démarrage : la page d'un classeur partagé aurait transmis l'adresse IP de
/// chaque visiteur à Google. L'application dépend donc de la seule
/// implémentation Android (`google_sign_in_android`), qui s'inscrit comme
/// `GoogleSignInPlatform.instance`, et parle à son interface.
///
/// Calqué sur DewDrop, qui l'a éprouvé sur appareil.
library;

import 'package:flutter/foundation.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

/// Identifiant du client OAuth **Web** « DeckHand – Web » (Google Cloud, projet
/// DeckHand).
///
/// **Public par nature** : il part dans l'APK. C'est l'audience que Supabase
/// vérifie sur chaque jeton Google, donc il doit être celui du fournisseur
/// Google du projet Supabase (`api/push_auth_config.py`) et celui de la page
/// web de suppression. **Une constante et non un `--dart-define`** : un build
/// qui oublierait le define compilerait sans erreur et perdrait la connexion
/// Google en silence. Vide = bouton Google masqué partout.
const String kGoogleWebClientId =
    '606067636388-an9rtthrnsd18te5v78uesqd4cvepn3p.apps.googleusercontent.com';

abstract interface class GoogleIdTokenSource {
  /// Le sélecteur peut-il s'ouvrir sur cet appareil ?
  bool get isAvailable;

  /// Ouvre le sélecteur de compte ; rend le jeton d'identité du compte choisi,
  /// ou `null` si l'utilisateur referme. Tout autre échec lève une
  /// [AuthException] de code `google_sign_in_failed`.
  Future<String?> pickAccount();

  /// Oublie le compte choisi sur cet appareil, pour que la connexion suivante
  /// rouvre le sélecteur au lieu de reprendre le même compte en silence.
  /// [revoke] retire en plus l'accès de DeckHand au compte Google (suppression
  /// du compte).
  Future<void> forget({bool revoke = false});
}

/// Le sélecteur natif (Credential Manager sur Android).
///
/// - **Android seulement.** iOS demanderait son propre client, et la version
///   web publiée ne connecte personne (`DECKHAND_PUBLIC_ONLY`).
/// - **Sans nonce** : ni l'une ni l'autre partie n'en fournit, Supabase n'a donc
///   rien à comparer ; le jeton reste lié à notre client et de courte durée.
/// - `init` ne se joue qu'une fois par processus (l'implémentation l'exige), et
///   paresseusement : une session qui ne touche jamais à Google ne le charge
///   pas.
class NativeGoogleIdTokenSource implements GoogleIdTokenSource {
  NativeGoogleIdTokenSource({required this.serverClientId});

  final String serverClientId;
  Future<void>? _ready;

  GoogleSignInPlatform get _platform => GoogleSignInPlatform.instance;

  @override
  bool get isAvailable =>
      serverClientId.isNotEmpty &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android;

  Future<void> _init() => _ready ??= _platform
      .init(InitParameters(serverClientId: serverClientId))
      .catchError((Object e) {
        _ready = null; // une tentative suivante pourra réessayer
        throw e;
      });

  @override
  Future<String?> pickAccount() async {
    try {
      await _init();
      final result = await _platform.authenticate(
        const AuthenticateParameters(),
      );
      final token = result.authenticationTokens.idToken;
      if (token == null) {
        throw const GoogleSignInException(
          code: GoogleSignInExceptionCode.unknownError,
          description: 'aucun jeton d\'identité',
        );
      }
      return token;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw AuthException(
        'Google sign-in failed: ${e.code.name}',
        code: 'google_sign_in_failed',
      );
    }
  }

  @override
  Future<void> forget({bool revoke = false}) async {
    if (!isAvailable) return;
    try {
      await _init();
      if (revoke) {
        await _platform.disconnect(const DisconnectParams());
      } else {
        await _platform.signOut(const SignOutParams());
      }
    } on Exception {
      // Aucun compte choisi sur cet appareil, ou pas de réseau : il n'y a rien
      // à oublier, et l'échec ne doit pas empêcher la déconnexion.
    }
  }
}
