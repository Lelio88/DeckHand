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
import '../data/game_artwork.dart';
import '../data/profile_repository.dart';
import '../domain/game_order.dart';
import 'game_blurb.dart';
import 'game_tile.dart';
import 'pick_games_screen.dart';
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
          // **Une énumération de trois sources sur vingt ment par omission.**
          // Elle datait de l'époque où il y en avait trois, et elle n'a pas
          // bougé pendant que cinq jeux entraient — dont un dont l'ingestion
          // repose sur une autorisation nominative de son éditeur. Un compte
          // vaut mieux qu'un échantillon : il reste vrai à chaque ajout.
          subtitle: Text('${credits.length} sources et éditeurs crédités'),
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
///
/// **Les jeux déclarés passent devant, les autres se replient.** L'ordre vient
/// du profil du compte, rempli à l'inscription. Relégués, jamais masqués : un
/// jeu décoché garde une collection, des classeurs et un journal, et le faire
/// disparaître de l'écran qui sert justement à en changer les rendrait
/// introuvables.
class _GamePicker extends ConsumerWidget {
  const _GamePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selected = ref.watch(selectedGameProvider);
    final artwork = ref.watch(gameArtworkProvider);

    // Une préférence qui n'a pas encore été lue — ou qui a échoué — donne le
    // même écran qu'une absence de préférence : les huit jeux à plat. Le
    // sélecteur doit rester utilisable avant et pendant la requête.
    final order = orderedGames(ref.watch(playedGamesProvider).asData?.value);

    Widget tile(Game game) => GameTile(
      name: game.label,
      detail: gameDetail(game),
      note: gameNote(game),
      artUrl: artwork.asData?.value[game.id],
      frame: gameArtworks[game.id]?.frame,
      selected: game == selected,
      onTap: game == selected
          ? null
          : () => ref.read(selectedGameProvider.notifier).select(game),
    );

    // Sans jeu déclaré, tout est « autre » : on affiche alors la grille
    // entière, sans repli — replier une section vide n'apprendrait rien.
    final head = order.played.isEmpty ? order.others : order.played;
    final tail = order.played.isEmpty ? const <Game>[] : order.others;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // **Des rangées, et non un `GridView`.** La première version en
        // utilisait un, `shrinkWrap` et `NeverScrollableScrollPhysics` — la
        // recette habituelle pour l'imbriquer dans une liste. Sur l'appareil,
        // l'écran ne défilait plus : cette physique **absorbe** le geste au
        // lieu de le laisser remonter au `ListView` parent, et les quatre
        // derniers jeux devenaient inatteignables. Un sélecteur dont la moitié
        // des entrées est hors de portée est pire qu'un sélecteur laid.
        GameRows(
          perRow: 2,
          spacing: 10,
          // L'illustration occupe le haut de la tuile, le texte le bas. Le
          // rapport a été réglé sur l'appareil : plus haut, les libellés à
          // deux lignes débordaient ; plus bas, l'image devenait une bande.
          aspectRatio: 0.82,
          children: [for (final game in head) tile(game)],
        ),
        if (tail.isNotEmpty) _OtherGames(games: tail, tile: tile),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.tune, size: 18),
            label: Text(
              order.played.isEmpty ? 'Choisir mes jeux' : 'Modifier mes jeux',
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PickGamesScreen(
                  initial: order.played,
                  onDone: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          // **Ce texte se périme à chaque jeu ajouté**, et il l'a fait : il
          // annonçait « les deux jeux » quand il y en avait huit. Le nombre
          // est donc calculé plutôt qu'écrit.
          "Le catalogue, la reconnaissance et les suggestions ne sont propres "
          "à aucun jeu : les ${Game.values.length} se saisissent et se rangent "
          "de la même façon. Sept se valorisent et se confrontent à des decks "
          "réels ; Wankul se construit sur son règlement, aucun index ne le "
          "cotant ni ne publiant ses listes. Une réserve sur les prix — une "
          "carte cotée seulement en brillante compte pour zéro si on la "
          "possède en ordinaire, faute de cote et non par oubli.",
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Le repli qui garde les jeux non déclarés à portée sans les mettre devant.
///
/// **Fermé par défaut, et c'est tout l'intérêt** : la page d'un joueur de
/// Pokémon tient alors en deux tuiles au lieu de huit. L'état vit dans le
/// widget et non dans une préférence — c'est un geste de consultation, pas un
/// réglage, et le rouvrir à chaque visite serait aussi surprenant que de
/// retrouver un tiroir ouvert.
class _OtherGames extends StatefulWidget {
  const _OtherGames({required this.games, required this.tile});

  final List<Game> games;
  final Widget Function(Game) tile;

  @override
  State<_OtherGames> createState() => _OtherGamesState();
}

class _OtherGamesState extends State<_OtherGames> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Autres jeux (${widget.games.length})',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          GameRows(
            perRow: 2,
            spacing: 10,
            aspectRatio: 0.82,
            children: [for (final game in widget.games) widget.tile(game)],
          ),
      ],
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
