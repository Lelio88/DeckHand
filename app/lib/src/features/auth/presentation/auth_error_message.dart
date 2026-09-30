/// Ce qu'un échec d'authentification dit à l'utilisateur — et ce qu'il tait.
///
/// **Clair pour l'utilisateur, muet pour qui cherche des comptes** (guide de
/// conformité, C2). Une adresse inconnue et un mauvais mot de passe donnent le
/// même message ; aucun message ne dit qu'une adresse est déjà inscrite ; le
/// texte brut de Supabase, en anglais et parfois technique, n'est jamais
/// affiché.
///
/// **Par code, pas par texte.** GoTrue range chaque erreur sous un code stable
/// (`invalid_credentials`, `weak_password`…) ; le texte, lui, change d'une
/// version à l'autre. Le texte n'est lu qu'en repli, pour un serveur qui ne
/// donnerait pas de code.
///
/// ```dart
/// on Object catch (e) { setState(() => _error = authErrorMessage(e)); }
/// ```
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'password_rules.dart';

const _identifiants = 'Adresse e-mail ou mot de passe incorrect.';
const _google = 'La connexion avec Google n\'a pas abouti. Réessayez.';
const _generique = 'Une erreur est survenue. Réessayez.';

/// Le message à afficher pour [error], quelle qu'en soit la nature.
String authErrorMessage(Object error) {
  if (error is! AuthException) return _generique;
  if (error is AuthRetryableFetchException) {
    return 'Serveur injoignable : vérifiez votre connexion, puis réessayez.';
  }
  final code = error is AuthWeakPasswordException
      ? 'weak_password'
      : error.code;
  switch (code) {
    case 'invalid_credentials':
    case 'user_not_found':
      return _identifiants;
    case 'email_not_confirmed':
      return 'Adresse pas encore confirmée : ouvrez le lien reçu par e-mail.';
    case 'weak_password':
      return 'Mot de passe trop faible : au moins $minPasswordLength '
          'caractères, avec des lettres et des chiffres.';
    case 'same_password':
      return 'C\'est déjà votre mot de passe : choisissez-en un autre.';
    case 'over_request_rate_limit':
    case 'over_email_send_rate_limit':
      return 'Trop de tentatives : réessayez dans quelques minutes.';
    case 'identity_already_exists':
      return 'Ce compte Google est déjà lié à un autre compte DeckHand.';
    case 'single_identity_not_deletable':
      return 'Impossible : c\'est votre seul moyen de connexion.';
    case 'google_sign_in_failed':
    case 'manual_linking_disabled':
      return _google;
    case 'signup_disabled':
      return 'Les inscriptions sont fermées.';
    case 'otp_expired':
    case 'flow_state_expired':
    case 'flow_state_not_found':
      return 'Lien expiré ou déjà utilisé. Redemandez-en un.';
  }
  // Repli pour un serveur sans code : seul le cas des identifiants se
  // reconnaît sûrement au texte, et c'est celui qui ne doit rien révéler.
  if (error.message.toLowerCase().contains('invalid login')) {
    return _identifiants;
  }
  return _generique;
}
