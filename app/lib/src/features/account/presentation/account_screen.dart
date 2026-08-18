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

import '../../../common/art_window.dart';
import '../../scan/domain/art_box.dart';
import '../../about/presentation/about_screen.dart';
import '../data/game_artwork.dart';
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
class _GamePicker extends ConsumerWidget {
  const _GamePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selected = ref.watch(selectedGameProvider);

    final artwork = ref.watch(gameArtworkProvider);

    return Column(
      children: [
        // **Deux colonnes, et une image par jeu.** Le sélecteur était la seule
        // liste de l'application à ne montrer aucune carte — la recherche, les
        // classeurs, l'étagère et le constructeur en affichent tous. Un joueur
        // reconnaît son jeu à une image bien avant d'en lire le nom.
        //
        // `shrinkWrap` et `NeverScrollableScrollPhysics` parce que cette grille
        // vit dans le `ListView` de l'écran : sans eux, deux zones défilantes
        // s'emboîteraient et Flutter lèverait sur une contrainte de hauteur
        // infinie.
        // **Des rangées, et non un `GridView`.** La première version en
        // utilisait un, `shrinkWrap` et `NeverScrollableScrollPhysics` — la
        // recette habituelle pour l'imbriquer dans une liste. Sur l'appareil,
        // l'écran ne défilait plus : cette physique **absorbe** le geste au lieu
        // de le laisser remonter au `ListView` parent, et les quatre derniers
        // jeux devenaient inatteignables. Un sélecteur dont la moitié des
        // entrées est hors de portée est pire qu'un sélecteur laid.
        //
        // Deux rangées de deux ne demandent aucun widget défilant : la `Column`
        // de l'écran s'en charge, et le doigt traverse.
        _Rows(
          perRow: 2,
          spacing: 10,
          // L'illustration occupe le haut de la tuile, le texte le bas. Le
          // rapport a été réglé sur l'appareil : plus haut, les libellés à
          // deux lignes débordaient ; plus bas, l'image devenait une bande.
          aspectRatio: 0.82,
          children: [
            for (final game in Game.values)
              _GameTile(
                name: game.label,
                artUrl: artwork.asData?.value[game.id],
                frame: gameArtworks[game.id]?.frame,
                detail: switch (game) {
                  Game.magic => '32 918 cartes, 1 028 decks',
                  // 929 et non 1 035 : le catalogue enregistrait deux fois les
                  // cartes dont la source réécrit le nom ou le texte d'une
                  // extension à l'autre. L'identité tient désormais au titre, au
                  // type et au champion.
                  Game.riftbound => '929 cartes, 2 500 decks',
                  Game.yugioh => '13 866 cartes, 3 935 decks',
                  Game.pokemon => '20 964 cartes, 23 574 decks',
                  // **Le seul jeu sans decks, et ce n'est pas un retard** : aucun
                  // corpus de listes n'est publié pour lui. La tuile annonce donc
                  // les cartes seules — écrire « 0 deck » se lirait comme une panne
                  // là où c'est une propriété du jeu.
                  Game.wankul => '958 cartes',
                  Game.swu => '2 180 cartes, 5 038 decks',
                  Game.onepiece => '2 541 cartes, 2 526 decks',
                  Game.lorcana => '2 517 cartes, 124 decks',
                },
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
                  Game.wankul =>
                    'Sans valorisation : aucun index ne cote ce jeu',
                },
                selected: game == selected,
                onTap: game == selected
                    ? null
                    : () =>
                          ref.read(selectedGameProvider.notifier).select(game),
              ),
          ],
        ),
        const SizedBox(height: 16),
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

/// Dispose des tuiles de largeur égale en rangées, sans zone défilante.
///
/// **Ce widget existe parce qu'un `GridView` imbriqué a bloqué le défilement.**
/// La recette habituelle — `shrinkWrap: true` avec
/// `NeverScrollableScrollPhysics` — laisse la grille *absorber* le geste
/// vertical plutôt que de le laisser remonter au `ListView` parent. L'écran se
/// fige, et rien ne le signale : la grille s'affiche parfaitement, elle refuse
/// seulement de bouger.
///
/// Une `Column` de `Row` n'a pas ce défaut, parce qu'elle ne défile pas du tout.
/// Elle coûte en revanche de connaître le rapport des tuiles — un `Row` ne sait
/// pas donner une hauteur à ses enfants —, d'où [aspectRatio].
class _Rows extends StatelessWidget {
  const _Rows({
    required this.children,
    required this.perRow,
    required this.spacing,
    required this.aspectRatio,
  });

  final List<Widget> children;
  final int perRow;
  final double spacing;

  /// Largeur sur hauteur d'une tuile. `AspectRatio` la traduit en hauteur une
  /// fois la largeur connue, ce qui reproduit `childAspectRatio` du `GridView`.
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += perRow) {
      final slice = children.skip(i).take(perRow).toList();
      rows.add(
        Row(
          // **Surtout pas `stretch`.** Une `Row` ne connaît sa hauteur qu'une
          // fois ses enfants mesurés ; leur demander de la remplir la lui
          // demande à elle, et la mise en page se referme sur elle-même. Le
          // symptôme n'est pas une exception mais un écran ENTIÈREMENT VIDE,
          // sans bandeau rouge ni trace au journal — le reste de l'application
          // continuant de fonctionner. C'est `AspectRatio` qui donne la
          // hauteur ici, et lui seul.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < perRow; j++) ...[
              if (j > 0) SizedBox(width: spacing),
              Expanded(
                // La dernière rangée peut être incomplète : on garde la place
                // vide plutôt que d'étirer la tuile restante sur deux colonnes.
                child: j < slice.length
                    ? AspectRatio(aspectRatio: aspectRatio, child: slice[j])
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
      if (i + perRow < children.length) rows.add(SizedBox(height: spacing));
    }
    return Column(children: rows);
  }
}

/// Une tuile de la grille : l'illustration d'une carte, puis le nom du jeu.
///
/// **L'image porte l'identité, le texte porte les chiffres.** Un joueur
/// reconnaît son jeu à une carte bien avant d'en lire le nom ; les compteurs,
/// eux, ne se lisent que lorsqu'on les cherche. D'où la hiérarchie : l'image
/// occupe le haut de la tuile, le nom vient sous elle, et le détail en petit.
///
/// **La sélection se voit deux fois** — un cadre coloré et une pastille cochée
/// posée sur l'image. Une seule des deux suffirait sur un écran clair ; sur un
/// fond sombre où les illustrations sont elles-mêmes colorées, le cadre seul se
/// perd.
class _GameTile extends StatelessWidget {
  const _GameTile({
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
    this.artUrl,
    this.frame,
    this.note,
  });

  final String name;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;

  /// L'illustration de la carte emblématique, ou `null` tant qu'elle charge.
  ///
  /// **Nullable à dessein** : la grille s'affiche avant que la requête
  /// n'aboutisse, et un sélecteur qui attend son image pour apparaître
  /// empêcherait de changer de jeu pendant une seconde. Le fond uni tient la
  /// place, l'image s'y pose quand elle arrive.
  final String? artUrl;

  /// Le cadre dont on retient la fenêtre, ou `null` si la source publie déjà
  /// l'illustration seule.
  final CardFrame? frame;

  /// Réserve à faire connaître avant de choisir ce jeu, ou `null`.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        // `clipBehavior` pour que l'illustration épouse les coins arrondis :
        // sans lui, elle déborde du cadre par ses angles.
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: theme.colorScheme.surfaceContainerHighest),
                  // **L'illustration seule, pas la carte entière.** Sept
                  // sources sur huit publient le rendu complet — cadre, nom,
                  // texte de règles —, et huit tuiles côte à côte mêlaient
                  // alors des illustrations pleines et des cartes miniatures
                  // illisibles. La fenêtre vient du scan : c'est exactement la
                  // zone que la reconnaissance découpe.
                  if (artUrl != null) ArtWindow(url: artUrl!, frame: frame),
                  if (selected)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(3),
                        child: Icon(
                          Icons.check,
                          size: 15,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer
                          : null,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: selected
                          ? theme.colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.8,
                            )
                          : theme.colorScheme.onSurfaceVariant,
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
