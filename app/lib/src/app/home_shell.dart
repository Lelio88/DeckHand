/// Coque de navigation de l'application connectée.
///
/// Deux destinations seulement : chercher une carte, consulter sa collection.
/// Les decks viendront s'ajouter ici lorsque le moteur de suggestion existera.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/card_search/presentation/card_search_screen.dart';
import '../features/collection/presentation/collection_screen.dart';
import '../features/decks/presentation/deck_suggestions_screen.dart';

/// Sous-titre affiché pour chaque destination, dans l'ordre des onglets.
const _titles = ['Rechercher', 'Ma collection', 'Decks possibles'];

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
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
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
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Se déconnecter',
            onPressed: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
    );
  }
}
