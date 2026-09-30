/// La règle d'un mot de passe, telle que le projet Supabase l'impose.
///
/// **La même règle des deux côtés.** Supabase refuse ce qui ne fait pas
/// [minPasswordLength] caractères, **avec au moins une lettre et un chiffre**
/// (`password_required_characters`, poussé par `api/push_auth_config.py`).
/// Vérifiée ici, elle épargne un aller-retour et, surtout, de le découvrir
/// après avoir tapé deux fois ; le serveur reste la seule autorité.
///
/// Règle alignée sur la recommandation CNIL de 2022 pour un mot de passe
/// protégé par une limitation des tentatives : huit caractères, de deux types
/// au moins.
library;

/// Longueur minimale, fixée côté projet Supabase.
const int minPasswordLength = 8;

/// Ce qui ne va pas dans [password], ou `null` s'il respecte la règle.
String? passwordRuleError(String password) {
  if (password.isEmpty) return 'Mot de passe requis';
  if (password.length < minPasswordLength) {
    return 'Au moins $minPasswordLength caractères';
  }
  final hasLetter = password.contains(RegExp(r'[A-Za-z]'));
  final hasDigit = password.contains(RegExp(r'[0-9]'));
  if (!hasLetter || !hasDigit) {
    return 'Au moins une lettre et un chiffre';
  }
  return null;
}
