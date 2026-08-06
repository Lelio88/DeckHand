/// Point d'entrée de DeckHand.
///
/// La configuration Supabase est vérifiée **avant** toute initialisation réseau :
/// un `--dart-define` oublié doit produire un message clair au démarrage, pas un
/// échec d'authentification opaque à la première requête.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/config/supabase_config.dart';
import 'src/features/card_search/presentation/card_search_screen.dart';

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
      home: const CardSearchScreen(),
    );
  }
}
