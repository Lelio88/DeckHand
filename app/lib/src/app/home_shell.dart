/// Coque de navigation de l'application connectée.
///
/// Quatre destinations : chercher une carte, consulter sa collection, voir ce
/// qu'elle permet de construire, et son compte. Le scan et l'écran « à propos »
/// sont ouverts par-dessus plutôt que d'être des onglets — ce sont des gestes
/// ponctuels, pas des lieux où l'on séjourne.
///
/// **La barre du haut ne répète plus le nom de l'onglet.** « Ma collection »
/// écrit au-dessus de la collection n'apprend rien : la barre de navigation le
/// dit déjà, en surbrillance. Cette place revient donc à ce que chaque onglet a
/// de plus utile à montrer d'un coup d'œil — le poids de la collection, le jeu
/// dans lequel on cherche, la façon dont on veut des decks, le compte ouvert.
///
/// **Elle ne porte toujours aucune action destructrice.** Se déconnecter et lire
/// les crédits vivent au bas de l'onglet Compte, où l'on ne tombe pas dessus par
/// mégarde.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/selected_game.dart';
import '../features/account/presentation/account_screen.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/card_search/presentation/card_search_screen.dart';
import '../features/collection/data/collection_repository.dart';
import '../features/collection/presentation/collection_screen.dart';
import '../features/decks/presentation/deck_suggestions_screen.dart';

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
                _TopBar(index: _index),
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

/// Nom de l'application à gauche, et ce que l'onglet a d'utile à droite.
///
/// **Le contenu de droite est collé au bord**, sans marge intérieure : c'est
/// l'ancrage qui rend la valeur lisible d'un coup d'œil, toujours au même
/// endroit quel que soit l'onglet.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
      child: Row(
        children: [
          Text('DeckHand', style: theme.textTheme.headlineSmall),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: switch (index) {
                0 => const _GameBadge(),
                1 => const _CollectionWeight(),
                2 => const _DeckModeChips(),
                _ => const _AccountBadge(),
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Le jeu dans lequel on cherche.
///
/// **Il vivait au fond de l'onglet Compte**, alors qu'il commande la recherche,
/// la collection et les decks : chercher « Agent » ne rend pas les mêmes cartes
/// selon qu'on est en Magic ou en Riftbound. Le montrer là où l'on cherche
/// évite de se demander pourquoi le catalogue paraît vide.
class _GameBadge extends ConsumerWidget {
  const _GameBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedGameProvider);
    return PopupMenuButton<Game>(
      tooltip: 'Changer de jeu',
      initialValue: selected,
      onSelected: (game) =>
          ref.read(selectedGameProvider.notifier).select(game),
      itemBuilder: (context) => [
        for (final game in Game.values)
          PopupMenuItem(value: game, child: Text(game.label)),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            selected.label,
            style: Theme.of(context).textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const Icon(Icons.arrow_drop_down, size: 20),
        ],
      ),
    );
  }
}

/// Ce que pèse la collection, en un nombre.
class _CollectionWeight extends ConsumerWidget {
  const _CollectionWeight();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final summary = ref.watch(collectionProvider).asData?.value;
    if (summary == null || summary.isEmpty) return const SizedBox.shrink();

    return Text(
      '${summary.totalCards} cartes',
      style: theme.textTheme.titleSmall,
    );
  }
}

/// Les deux façons de répondre à « que puis-je jouer ? ».
///
/// Le choix vivait au-dessus des filtres de format, où il ressemblait à un
/// filtre de plus. En haut, il devient ce qu'il est : le mode de l'onglet.
class _DeckModeChips extends ConsumerWidget {
  const _DeckModeChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(deckModeProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final value in DeckMode.values) ...[
          ChoiceChip(
            label: Text(value.label),
            selected: mode == value,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) =>
                ref.read(deckModeProvider.notifier).select(value),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }
}

/// Le compte ouvert : son nom d'usage, et l'adresse qui l'identifie.
class _AccountBadge extends ConsumerWidget {
  const _AccountBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final email = ref.watch(sessionProvider).asData?.value?.user.email;
    if (email == null || email.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          email.split('@').first,
          style: theme.textTheme.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          email,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
