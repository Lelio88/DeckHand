/// Écran de compte : qui vous êtes, ce que vous possédez, comment partir.
///
/// Les actions rares — se déconnecter, lire les crédits — occupaient jusqu'ici
/// deux icônes en haut de chaque écran, visibles en permanence pour un usage
/// exceptionnel. Elles descendent ici, tout en bas, là où l'on ne tombe pas
/// dessus par accident.
///
/// L'écran porte aussi le **choix du jeu**. DeckHand ne couvre aujourd'hui que
/// Magic, mais rien dans son architecture n'y oblige : le catalogue, les
/// empreintes et le moteur de suggestion sont des mécaniques génériques. La
/// place est donc réservée, désactivée, plutôt que d'être ajoutée en catastrophe
/// le jour où un second jeu arrive.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/selected_game.dart';

import '../../about/presentation/about_screen.dart';
import '../../auth/data/auth_repository.dart';
import '../../collection/data/collection_repository.dart';
import 'sharing_screen.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final summary = ref.watch(collectionProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        summary.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (error, _) => Text('Collection illisible : $error'),
          data: (totals) => Row(
            children: [
              Expanded(
                child: _Figure(
                  icon: Icons.style_outlined,
                  value: '${totals.totalCards}',
                  label: totals.totalCards > 1 ? 'cartes' : 'carte',
                  detail:
                      '${totals.distinctCards} référence'
                      '${totals.distinctCards > 1 ? 's' : ''}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Figure(
                  icon: Icons.euro,
                  value: totals.totalValueEur.toStringAsFixed(2),
                  label: 'euros',
                  // Une valorisation fondée sur des éditions inconnues est un
                  // plancher, pas une estimation. Le dire évite de prendre le
                  // chiffre pour argent comptant.
                  detail: totals.unspecifiedPrints > 0
                      ? '${totals.unspecifiedPrints} sans édition'
                      : 'toutes éditions connues',
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 28),
        Text('Jeu', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        const _GamePicker(),

        const SizedBox(height: 28),
        Text('Partage', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        const _PublicationTile(),

        const SizedBox(height: 28),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.info_outline),
          title: const Text('À propos et crédits'),
          subtitle: const Text('Scryfall, TopDeck.gg, MTGJSON'),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.logout, color: theme.colorScheme.error),
          title: Text(
            'Se déconnecter',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          onTap: () => ref.read(authRepositoryProvider).signOut(),
        ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.icon,
    required this.value,
    required this.label,
    required this.detail,
  });

  final IconData icon;
  final String value;
  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(value, style: theme.textTheme.headlineSmall),
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 2,
          ),
        ],
      ),
    );
  }
}

/// Jeux couverts. Le choix vaut pour la recherche, la collection et les decks.
///
/// **Un seul jeu à la fois.** Mêler deux catalogues obligerait l'utilisateur à
/// trier lui-même à chaque frappe, pour des cartes qui ne se jouent pas
/// ensemble et ne se comparent pas en prix. Le choix est retenu d'une session à
/// l'autre : c'est une propriété de l'utilisateur, pas de la séance.
class _GamePicker extends ConsumerWidget {
  const _GamePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selected = ref.watch(selectedGameProvider);

    return Column(
      children: [
        for (final game in Game.values) ...[
          _GameTile(
            name: game.label,
            detail: switch (game) {
              Game.magic => '32 918 cartes, 1 028 decks',
              // 929 et non 1 035 : le catalogue enregistrait deux fois les
              // cartes dont la source réécrit le nom ou le texte d'une
              // extension à l'autre. L'identité tient désormais au titre, au
              // type et au champion.
              Game.riftbound =>
                'le TCG League of Legends — 929 cartes, 2 500 decks',
              Game.yugioh => '13 866 cartes, 3 935 decks',
              Game.pokemon => '20 964 cartes, 23 574 decks',
              // **Le seul jeu sans decks, et ce n'est pas un retard** : aucun
              // corpus de listes n'est publié pour lui. La tuile annonce donc
              // les cartes seules — écrire « 0 deck » se lirait comme une panne
              // là où c'est une propriété du jeu.
              Game.wankul => 'le TCG de Wankil Studio — 958 cartes',
              Game.swu => 'le TCG Star Wars — 2 180 cartes',
              Game.onepiece => '2 541 cartes, 2 526 decks',
              Game.lorcana => 'le TCG Disney — 2 517 cartes',
            },
            // **Les prix Riftbound sont convertis, et ça se dit ici.** Ils sont
            // relevés en dollars chez TCGplayer ; l'euro affiché passe par le
            // taux de la BCE et n'est donc pas un prix de marché européen. Le
            // chiffre est bon, sa provenance mérite d'être connue avant qu'on
            // décide d'acheter sur sa foi.
            note: switch (game) {
              // **Les prix Riftbound sont convertis, et ça se dit ici.** Ils
              // sont relevés en dollars chez TCGplayer ; l'euro affiché passe
              // par le taux de la BCE et n'est donc pas un prix de marché
              // européen. Le chiffre est bon, sa provenance mérite d'être
              // connue avant qu'on décide d'acheter sur sa foi.
              // Les trois jeux servis par TCGCSV sont dans le même cas : les
              // cotes y sont relevées en dollars, et l'euro affiché passe par le
              // taux de la BCE.
              Game.riftbound ||
              Game.yugioh ||
              Game.pokemon ||
              Game.swu ||
              Game.onepiece ||
              Game.lorcana => 'Prix convertis du dollar au taux de la BCE',
              Game.magic => null,
              // **Wankul n'aura pas de prix, et ce n'est pas un retard.** Les
              // quatre autres jeux sont cotés parce qu'ils ont un marché
              // secondaire indexé — TCGplayer, relevé par TCGCSV. Wankul se
              // vend en direct par son éditeur, et la recherche a été menée :
              // ni TCGCSV, ni Cardmarket, ni aucun index public ne le cote carte
              // par carte (voir `docs/multi-game.md` §9). La collection s'y
              // compte et s'y range, elle ne s'y valorise pas.
              Game.wankul => 'Sans valorisation : aucun index ne cote ce jeu',
            },
            selected: game == selected,
            onTap: game == selected
                ? null
                : () => ref.read(selectedGameProvider.notifier).select(game),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          "Le catalogue, la reconnaissance et les suggestions ne sont pas propres "
          "à Magic : les deux jeux se saisissent, se valorisent et se confrontent "
          "à des decks réels. Une réserve pour Riftbound — une carte cotée "
          "seulement en brillante compte pour zéro si on la possède en ordinaire, "
          "et c'est le cas de près de la moitié du catalogue, faute de cote et "
          "non par oubli.",
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.note,
  });

  final String name;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;

  /// Réserve à faire connaître avant de choisir ce jeu, ou `null`.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 20,
              color: selected
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer
                          : null,
                    ),
                  ),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.8,
                            )
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (note != null)
                    Text(
                      note!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: selected
                            ? theme.colorScheme.onPrimaryContainer.withValues(
                                alpha: 0.7,
                              )
                            : theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Porte vers l'écran de partage, et son état d'un coup d'œil.
///
/// **Un interrupteur ici ne suffisait pas.** Publier engage deux autres choix —
/// sous quelle adresse, et quels classeurs — qu'une bascule ne peut pas porter.
/// L'état reste visible sans ouvrir, parce que c'est la seule chose qu'on vient
/// vérifier la plupart du temps.
class _PublicationTile extends ConsumerWidget {
  const _PublicationTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(publicationProvider);

    final subtitle = state.when(
      loading: () => 'Chargement…',
      error: (error, _) => 'État indisponible',
      data: (publication) {
        if (!publication.isPublic) return 'Vous seul voyez votre collection.';
        final sets = publication.sharedSets;
        final quoi = sets == null
            ? 'tous vos classeurs'
            : '${sets.length} classeur${sets.length > 1 ? 's' : ''}';
        return 'Partagé — $quoi';
      },
    );

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        state.asData?.value.isPublic == true
            ? Icons.public
            : Icons.lock_outline,
        color: state.asData?.value.isPublic == true
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: const Text('Classeurs partagés'),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const SharingScreen())),
    );
  }
}
