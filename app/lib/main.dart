/// Point d'entrée de DeckHand.
///
/// La configuration Supabase est vérifiée **avant** toute initialisation réseau :
/// un `--dart-define` oublié doit produire un message clair au démarrage, pas un
/// échec d'authentification opaque à la première requête.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app/home_shell.dart';
import 'src/config/supabase_config.dart';
import 'src/features/auth/data/auth_repository.dart';
import 'src/features/auth/presentation/sign_in_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SupabaseConfig.assertConfigured();
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
  );

  runApp(const ProviderScope(child: DeckHandApp()));
}

class DeckHandApp extends StatelessWidget {
  const DeckHandApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB8860B),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'DeckHand',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF15131A),
        useMaterial3: true,
      ),
      home: const _AuthGate(),
    );
  }
}

/// Aiguille entre connexion et application selon la session courante.
///
/// La session est restaurée de façon synchrone au démarrage, donc l'écran de
/// chargement n'apparaît qu'en cas de latence réelle — pas à chaque lancement.
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);

    return session.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (error, _) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('Authentification indisponible : $error'),
          ),
        ),
      ),
      data: (value) => value == null ? const SignInScreen() : const HomeShell(),
    );
  }
}
