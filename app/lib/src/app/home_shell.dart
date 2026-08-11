/// Coque de navigation de l'application connectée.
///
/// Quatre destinations : ajouter des cartes, consulter sa collection, voir ce
/// qu'elle permet de construire, et son compte. Les écrans de prise de vue et
/// « à propos » s'ouvrent par-dessus plutôt que d'être des onglets — ce sont des
/// gestes ponctuels, pas des lieux où l'on séjourne.
///
/// **Le premier onglet s'appelle « Ajouter » et non « Rechercher ».** On n'y
/// vient pas pour consulter le catalogue : on y vient pour faire entrer une
/// carte dans sa collection, au clavier ou par l'appareil photo. La recherche
/// est le moyen, pas la fin.
///
/// **La barre du haut ne répète plus le nom de l'onglet.** « Ma collection »
/// écrit au-dessus de la collection n'apprend rien : la barre de navigation le
/// dit déjà, en surbrillance. Cette place revient donc à ce que chaque onglet a
/// de plus utile à montrer d'un coup d'œil — les façons d'ajouter des cartes, le
/// poids de la collection, la façon dont on veut des decks, le compte ouvert.
///
/// **Elle ne porte toujours aucune action destructrice.** Se déconnecter et lire
/// les crédits vivent au bas de l'onglet Compte, où l'on ne tombe pas dessus par
/// mégarde.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/account/presentation/account_screen.dart';
import '../features/binders/presentation/binder_view.dart'
    show binderIsImmersive;
import '../features/auth/data/auth_repository.dart';
import '../features/card_search/presentation/card_search_screen.dart';
import '../features/collection/data/collection_repository.dart';
import '../features/collection/presentation/collection_screen.dart';
import '../features/collection/presentation/history_sheet.dart';
import '../features/decks/presentation/deck_suggestions_screen.dart';
import '../features/scan/presentation/scan_screen.dart';
import '../features/scan/presentation/spread_scan_screen.dart';
import '../features/voice/presentation/voice_input_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // **Un classeur couché prend tout l'écran.** C'est le seul endroit où la
    // coque s'efface : la barre du haut et la navigation coûtent 150 points de
    // hauteur sur les 408 d'un téléphone couché, et une page de classeur en
    // manque. On y entre en tournant l'appareil, on en sort en le redressant —
    // le geste est réversible, aucun bouton n'est donc nécessaire pour rendre
    // la navigation. La largeur maximale saute aussi : une double page a
    // besoin de toute la table.
    final immersive = binderIsImmersive(context, ref);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: immersive ? 1600 : 720),
            child: Column(
              children: [
                if (!immersive) _TopBar(index: _index),
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
      bottomNavigationBar: immersive
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.add), label: 'Ajouter'),
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
                0 => const _CaptureButtons(),
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

/// Les trois façons d'ajouter des cartes autrement qu'au clavier.
///
/// **Elles occupaient la ligne du champ de recherche**, qu'elles rétrécissaient
/// d'un tiers. En haut, elles deviennent ce qu'elles sont : les entrées de
/// l'onglet, à côté de la saisie au clavier qui reste dessous.
///
/// L'ordre va du geste le plus large au plus fin — une photo d'étalement pour
/// vider une boîte, la dictée pour saisir en vrac, la photo d'une carte pour
/// lever un doute.
class _CaptureButtons extends StatelessWidget {
  const _CaptureButtons();

  /// Ouvre par-dessus, et fait taire la notification en cours.
  ///
  /// Les notifications vivent au-dessus du navigateur : sans cela, le retour
  /// d'un ajout suivrait l'utilisateur et recouvrirait les commandes de
  /// l'écran de prise de vue, dont les boutons sont en bas.
  void _open(BuildContext context, Widget screen) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          tooltip: 'Photographier plusieurs cartes',
          icon: const Icon(Icons.photo_camera_outlined),
          onPressed: () => _open(context, const SpreadScanScreen()),
        ),
        const SizedBox(width: 6),
        IconButton.filledTonal(
          tooltip: 'Dicter des cartes',
          icon: const Icon(Icons.mic_none),
          onPressed: () => _open(context, const VoiceInputScreen()),
        ),
        const SizedBox(width: 6),
        // L'icône annonce ce que ce mode deviendra — la caméra qui reconnaît au
        // fil des cartes (#8). Le comportement, lui, reste la photo unique tant
        // que le temps réel n'est pas mesuré : promettre du direct avant de
        // l'avoir éprouvé ferait passer une limite pour une panne.
        IconButton.filledTonal(
          tooltip: 'Viser une carte',
          icon: const Icon(Icons.center_focus_strong_outlined),
          onPressed: () => _open(context, const ScanScreen()),
        ),
      ],
    );
  }
}

/// Ce que pèse la collection, et son histoire.
///
/// Le nombre dit l'état, le journal dit comment on y est arrivé — « quand ai-je
/// acquis cette carte » est une question que la collection seule ne sait pas
/// résoudre, sa date étant écrasée à chaque ajout.
class _CollectionWeight extends ConsumerWidget {
  const _CollectionWeight();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final summary = ref.watch(collectionProvider).asData?.value;
    if (summary == null || summary.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Journal des ajouts',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.history, size: 20),
          onPressed: () => showCollectionHistory(context),
        ),
        Text('${summary.totalCards} cartes', style: theme.textTheme.titleSmall),
      ],
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
    final user = ref.watch(sessionProvider).asData?.value?.user;
    final email = user?.email;
    if (email == null || email.isEmpty) return const SizedBox.shrink();

    // **Le nom du compte, et à défaut ce qui précède le @.** Le repli n'est
    // qu'un pis-aller : il donnait « test » sur un compte nommé
    // `test@deckhand.app`, et suivrait n'importe quel changement d'adresse.
    final name = (user?.userMetadata?['name'] as String?)?.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name == null || name.isEmpty ? email.split('@').first : name,
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
