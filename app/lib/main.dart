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
import 'src/features/binders/presentation/overlay_screen.dart';
import 'src/features/binders/presentation/public_binder_screen.dart';
import 'src/features/auth/presentation/reset_password_screen.dart';
import 'src/features/auth/presentation/sign_in_screen.dart';
import 'src/features/scan/presentation/frame_bench_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SupabaseConfig.assertConfigured();
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
  );

  runApp(const ProviderScope(child: DeckHandApp()));
}

/// Vrai sur un build de mesure du flux caméra (issue #8).
const bool benchMode = bool.fromEnvironment('DECKHAND_BENCH');

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
      // **Le banc de mesure court-circuite l'application entière.** Il ne
      // demande ni compte ni base : il chronomètre le flux caméra, et son
      // seul rendu est une ligne de journal. Le passer par un écran de
      // réglages le rendrait dépendant de ce qu'il doit mesurer.
      home: benchMode ? const FrameBenchScreen() : const _AuthGate(),
    );
  }
}

/// Aiguille entre connexion et application selon la session courante.
///
/// La session est restaurée de façon synchrone au démarrage, donc l'écran de
/// chargement n'apparaît qu'en cas de latence réelle — pas à chaque lancement.
///
/// **Une adresse de partage court-circuite tout cela.** Un lien `?c=<id>` ouvre
/// le classeur désigné sans demander de compte : c'est l'objet même de la
/// lecture publique, et exiger une connexion pour regarder une collection
/// donnée à lire la rendrait inutile. Le contrôle n'est pas ici mais en base —
/// une collection non publiée est refusée par la politique, quel que soit le
/// chemin.
/// Cette version ne sait que lire des classeurs partagés.
///
/// **Ce qu'elle protège, ce sont les inscriptions.** L'application se compile
/// pour le web, et une adresse publique donnerait à n'importe qui l'écran de
/// connexion — donc la création de compte, ouverte sur ce projet Supabase.
/// DeckHand n'est pas un service ouvert (`CLAUDE.md` §I) : la version hébergée
/// n'embarque donc pas de quoi s'y inscrire, plutôt que de compter sur le fait
/// que personne n'essaiera.
///
/// La clé publiable qu'elle emporte ne peut alors servir qu'à des lectures
/// anonymes, et celles-ci sont bornées par les politiques — vérifiées dans les
/// deux sens, collection publiée et collection qui ne l'est pas.
const bool publicOnly = bool.fromEnvironment('DECKHAND_PUBLIC_ONLY');

class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // **Le calque avant le classeur.** Une adresse `?o=` ouvre l'overlay OBS,
    // qui est une autre page et pas une variante de celui-ci : fond
    // transparent, aucune navigation. Les deux se résolvent sans compte, par la
    // même porte publique.
    final overlay = overlayFromUrl(Uri.base);
    if (overlay != null) return OverlayScreen(handle: overlay);

    final shared = collectionFromUrl(Uri.base);
    if (shared != null) return PublicBinderScreen(handle: shared);
    if (publicOnly) return const _SharedOnly();

    // **Observé avant la session, et non après.** Un lien de réinitialisation
    // ouvre une session de récupération que rien ne distingue d'une connexion
    // ordinaire : sans ce détour, l'application afficherait l'accueil et le
    // nouveau mot de passe ne serait jamais demandé. L'observer ici garantit
    // aussi que l'abonnement existe avant que l'événement n'arrive — le flux
    // d'authentification ne rejoue pas ce qui est passé.
    final recovering = ref.watch(passwordRecoveryProvider);
    if (recovering) return const ResetPasswordScreen();

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

/// Ce que montre la version hébergée quand l'adresse ne désigne aucun classeur.
///
/// Ni connexion ni inscription : il n'y a rien à faire ici sans un lien.
class _SharedOnly extends StatelessWidget {
  const _SharedOnly();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 40,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text('DeckHand', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Cette page affiche un classeur partagé. Il faut pour cela '
                  'l\'adresse que son propriétaire a donnée.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Cartes, images et prix : Scryfall. Magic: The Gathering est '
                  'une marque de Wizards of the Coast, qui n\'est pas affiliée '
                  'à DeckHand.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
