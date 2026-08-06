/// Configuration de l'accès Supabase.
///
/// Les valeurs sont injectées à la compilation par `--dart-define`, jamais
/// écrites dans le dépôt — celui-ci est public.
///
/// La clé publiable est publique par conception : elle finit de toute façon dans
/// le bundle distribué, et c'est la RLS qui protège réellement les données. La
/// sortir du code source évite surtout qu'elle traîne dans l'historique git quand
/// le projet change de clés.
///
/// On utilise le format `sb_publishable_…` plutôt que l'ancienne clé `anon` :
/// celle-ci est dépréciée côté SDK et disparaîtra dans une version majeure.
///
/// **Garde-fou volontaire** : si une valeur manque, l'application refuse de
/// démarrer avec un message explicite. Sans cela, l'oubli d'un `--dart-define`
/// produit un échec bien plus tard, sous forme d'un 401 silencieux à la première
/// requête — un piège déjà rencontré sur un autre projet.
library;

class SupabaseConfig {
  const SupabaseConfig._();

  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  /// Vérifie la présence des valeurs et explique comment lancer l'app si elles
  /// manquent. Appelée au démarrage, avant toute initialisation réseau.
  static void assertConfigured() {
    if (url.isNotEmpty && publishableKey.isNotEmpty) return;

    final missing = [
      if (url.isEmpty) 'SUPABASE_URL',
      if (publishableKey.isEmpty) 'SUPABASE_PUBLISHABLE_KEY',
    ].join(', ');

    throw StateError(
      'Configuration Supabase absente : $missing.\n'
      'Lancez l\'application avec les valeurs du coffre de secrets :\n'
      '  flutter run -d chrome \\\n'
      '    --dart-define=SUPABASE_URL=... \\\n'
      '    --dart-define=SUPABASE_PUBLISHABLE_KEY=...\n'
      'Les valeurs sont dans ../.deckhand-secrets/supabase.env',
    );
  }
}
