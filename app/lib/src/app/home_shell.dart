/// Coque de navigation de l'application connectée.
///
/// Quatre destinations : chercher une carte, consulter sa collection, voir ce
/// qu'elle permet de construire, et son compte. Le scan et l'écran « à propos »
/// sont ouverts par-dessus plutôt que d'être des onglets — ce sont des gestes
/// ponctuels, pas des lieux où l'on séjourne.
///
/// **La barre du haut ne porte plus d'actions.** Se déconnecter et lire les
/// crédits occupaient deux icônes visibles en permanence sur chaque écran, pour
/// un usage exceptionnel. Elles vivent désormais au bas de l'onglet Compte, où
/// l'on ne tombe pas dessus par mégarde.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/account/presentation/account_screen.dart';
import '../features/card_search/presentation/card_search_screen.dart';
import '../features/collection/presentation/collection_screen.dart';
import '../features/decks/presentation/deck_suggestions_screen.dart';

/// Sous-titre affiché pour chaque destination, dans l'ordre des onglets.
const _titles = ['Rechercher', 'Ma collection', 'Decks possibles', 'Mon compte'];

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                _TopBar(title: _titles[_index]),
                Expanded(
                  // IndexedStack et non un simple switch : passer d'un onglet à
                  // l'autre ne doit pas effacer la recherche en cours.
                  child: IndexedStack(
                    index: _index,
                    children: const [
                      CardSearchScreen(),
                      CollectionScreen(),
                      DeckSuggestionsScreen(),
                      AccountScreen(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: 'Rechercher'),
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style),
            label: 'Collection',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'Decks',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Compte',
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('DeckHand', style: theme.textTheme.headlineMedium),
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
