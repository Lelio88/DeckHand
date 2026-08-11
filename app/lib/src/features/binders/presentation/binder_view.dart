/// La vue classeur : une étagère d'éditions, puis les cases de l'une d'elles.
///
/// **Ce qu'elle montre et qu'une liste ne montre pas, ce sont les cases vides.**
/// La liste de collection dit ce qu'on possède ; le classeur dit ce qui manque,
/// à sa place, dans l'ordre des numéros. C'est une vue de complétion d'édition,
/// et c'est ce qui la rend intéressante à regarder.
///
/// **L'entrée est une étagère, pas un classeur.** 695 éditions au catalogue :
/// ouvrir directement sur l'une d'elles supposerait de choisir laquelle, et
/// afficher les 695 donnerait 690 classeurs vides. Seules celles où quelque
/// chose est rangé figurent.
///
/// La grille est de trois par trois, comme une feuille de classeur physique, et
/// les feuilles **se tournent** — voir `page_turn.dart`. Une glissière traverse
/// le classeur d'un geste : 97 feuilles ne se parcourent pas une par une.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../common/card_image.dart';
import '../../../common/state_message.dart';
import '../../collection/data/collection_repository.dart';
import '../../collection/domain/collection_entry.dart' show FinishFilter;
import '../../printings/presentation/card_art_view.dart';
import '../../printings/presentation/foil_decoration.dart';
import '../../printings/presentation/printing_picker.dart';
import '../data/binder_repository.dart';
import '../domain/binder.dart';
import 'page_turn.dart';
import 'shelf_tile.dart';

/// Code réservé à la pile à trier, qui n'est l'extension de personne.
///
/// Un mot plutôt qu'un booléen de plus : la pile s'ouvre et se ferme comme un
/// classeur, et tout le reste de la navigation la traite comme tel.
const String unsortedBinder = '\u0000unsorted';

/// Classeur ouvert, ou `null` quand on regarde l'étagère.
class OpenBinder extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String setCode) => state = setCode;
  void close() => state = null;
}

final openBinderProvider = NotifierProvider<OpenBinder, String?>(
  OpenBinder.new,
);

/// Vrai quand le classeur couché doit occuper l'écran entier.
///
/// **Mesuré, et c'est ce qui a rendu la double page nécessaire à regarder avant
/// de la déclarer bonne.** Sur un téléphone couché — 907 × 408 —, la barre du
/// haut, l'entête du classeur, les menus de lecture et la navigation du bas
/// consommaient 290 points sur 408. Il en restait 118 pour dix-huit cartes :
/// des vignettes de quarante points perdues dans du noir. La géométrie n'y peut
/// rien, trois rangées de cartes réclament de la hauteur ; la seule variable
/// est ce qu'on leur laisse.
///
/// Debout, rien ne change : la hauteur ne manque pas, et faire disparaître la
/// navigation coûterait plus qu'elle ne rapporterait.
bool binderIsImmersive(BuildContext context, WidgetRef ref) =>
    ref.watch(openBinderProvider) != null &&
    MediaQuery.orientationOf(context) == Orientation.landscape;

/// Page courante du classeur ouvert, à partir de 1.
class BinderPageNumber extends Notifier<int> {
  @override
  int build() => 1;

  void set(int page) => state = page < 1 ? 1 : page;
}

final binderPageNumberProvider = NotifierProvider<BinderPageNumber, int>(
  BinderPageNumber.new,
);

class BinderView extends ConsumerWidget {
  const BinderView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(openBinderProvider);

    // **Le retour du système referme le classeur**, comme la flèche de
    // l'en-tête. Sans lui, le geste de sortie le plus universel d'Android
    // quittait l'application depuis la vue où l'on séjourne le plus : il
    // n'y a qu'une route, l'ouverture d'un classeur n'étant qu'un état.
    // Depuis l'étagère, en revanche, il n'y a plus rien à refermer et le
    // retour reprend son sens ordinaire.
    return PopScope(
      canPop: open == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ref.read(openBinderProvider.notifier).close();
      },
      child: switch (open) {
        null => const _Shelf(),
        unsortedBinder => const _UnsortedPile(),
        final String setCode => _Binder(setCode: setCode),
      },
    );
  }
}

/// Champ de recherche de l'étagère.
///
/// **Chercher une carte est la seule chose qu'une liste faisait mieux qu'un
/// classeur.** L'ordre des numéros ne répond pas à « où est ma Foudre ? » : il
/// faudrait connaître l'extension et tourner les feuilles. Le résultat porte
/// donc la page, et y mène.
class _ShelfSearch extends ConsumerStatefulWidget {
  const _ShelfSearch();

  @override
  ConsumerState<_ShelfSearch> createState() => _ShelfSearchState();
}

class _ShelfSearchState extends ConsumerState<_ShelfSearch> {
  late final TextEditingController _controller;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // **Le champ repart de la recherche en cours, pas de rien.** Ouvrir un
    // classeur démonte l'étagère et emporte ce contrôleur ; en revenant, un
    // nouveau naissait vide alors que la requête, elle, survivait dans son
    // provider. L'écran montrait donc les résultats d'une recherche dont le
    // champ paraissait effacé, et il fallait retaper puis vider pour retrouver
    // ses classeurs.
    _controller = TextEditingController(text: ref.read(binderQueryProvider));
    // La croix d'effacement dépend du contenu : sans cette écoute, elle
    // n'apparaissait qu'au prochain rebuild venu d'ailleurs.
    _controller.addListener(_syncClearButton);
  }

  void _syncClearButton() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_syncClearButton);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // Une requête par frappe interrogerait le serveur dix fois pour un nom.
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) ref.read(binderQueryProvider.notifier).set(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: TextField(
        controller: _controller,
        onChanged: _onChanged,
        decoration: InputDecoration(
          hintText: 'Chercher une carte dans mes classeurs',
          prefixIcon: const Icon(Icons.search, size: 20),
          isDense: true,
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    // Le débours en cours viserait la requête qu'on efface.
                    _debounce?.cancel();
                    _controller.clear();
                    ref.read(binderQueryProvider.notifier).set('');
                  },
                ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}

/// Les cartes trouvées, avec la feuille où les prendre.
class _FindResults extends ConsumerWidget {
  const _FindResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final found = ref.watch(binderFindProvider);

    return found.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => StateMessage(
        icon: Icons.cloud_off,
        title: 'Recherche impossible',
        detail: '$error',
        onRetry: () => ref.invalidate(binderFindProvider),
      ),
      data: (results) {
        if (results.isEmpty) {
          return const StateMessage(
            icon: Icons.search_off,
            title: 'Aucune carte rangée sous ce nom',
            // Chercher dans un classeur, c'est chercher parmi ses cartes : ne
            // pas trouver ne veut pas dire que la carte n'existe pas.
            detail: 'La recherche ne porte que sur vos classeurs.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: results.length,
          itemBuilder: (context, i) {
            final hit = results[i];
            return ListTile(
              dense: true,
              onTap: () {
                ref.read(binderPageNumberProvider.notifier).set(hit.page);
                ref.read(openBinderProvider.notifier).open(hit.setCode);
              },
              title: Text(
                hit.shownName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${hit.setName ?? hit.setCode.toUpperCase()} · '
                '#${hit.collectorNumber} · page ${hit.page}'
                '${hit.owned > 1 ? ' · ×${hit.owned}' : ''}',
                style: theme.textTheme.bodySmall,
              ),
              trailing: const Icon(Icons.chevron_right),
            );
          },
        );
      },
    );
  }
}

/// Les éditions dont on possède au moins une carte.
class _Shelf extends ConsumerWidget {
  const _Shelf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelf = ref.watch(binderShelfProvider);
    final query = ref.watch(binderQueryProvider);

    if (query.isNotEmpty) {
      return const Column(
        children: [
          _ShelfSearch(),
          Expanded(child: _FindResults()),
        ],
      );
    }

    return shelf.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => StateMessage(
        icon: Icons.cloud_off,
        title: 'Étagère illisible',
        detail: '$error',
        onRetry: () => ref.invalidate(binderShelfProvider),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          // **La pile à trier reste, même sans un seul classeur.** C'est
          // l'état du premier jour, ou d'une collection dictée : aucune carte
          // n'a d'édition, donc aucune n'a de case. Rendre le message seul
          // masquait la seule sortie réelle — la tuile « À trier », par où
          // l'on précise les éditions — et renvoyait vers une vue Liste qui
          // n'existe plus.
          //
          // Deux causes à une étagère vide, et deux messages : des cartes qui
          // attendent leur édition, ou pas de cartes du tout. Envoyer vers une
          // pile inexistante serait aussi trompeur que l'ancien renvoi.
          final waiting =
              ref.watch(collectionProvider).asData?.value.unspecifiedPrints ??
              0;
          return Column(
            children: [
              const _UnsortedTile(),
              Expanded(
                child: StateMessage(
                  icon: Icons.inbox_outlined,
                  title: 'Aucun classeur',
                  detail: waiting > 0
                      ? 'Un classeur est une édition, et vos cartes n\'en ont '
                            'pas encore. Ouvrez « À trier » ci-dessus pour leur '
                            'en donner une : elles trouveront alors leur case.'
                      : 'Un classeur est une édition. Ajoutez des cartes '
                            'depuis l\'onglet Ajouter : chacune rejoindra la '
                            'case de son extension.',
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            const _ShelfSearch(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: entries.length + 1,
                // La pile à trier ouvre l'étagère plutôt que de la clore :
                // c'est le travail en cours, et ce qu'on range aujourd'hui
                // remplira les classeurs demain.
                itemBuilder: (context, i) {
                  if (i == 0) return const _UnsortedTile();
                  final entry = entries[i - 1];
                  return ShelfTile(
                    entry: entry,
                    onOpen: () {
                      ref.read(binderPageNumberProvider.notifier).set(1);
                      ref.read(openBinderProvider.notifier).open(entry.setCode);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// L'entrée « À trier », en tête de l'étagère.
///
/// Elle ne s'affiche que s'il y a quelque chose à trier : sur une collection
/// entièrement précisée, une pile vide n'apprendrait rien et occuperait la
/// première place.
class _UnsortedTile extends ConsumerWidget {
  const _UnsortedTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final waiting =
        ref.watch(collectionProvider).asData?.value.unspecifiedPrints ?? 0;
    if (waiting == 0) return const SizedBox.shrink();

    return ListTile(
      onTap: () {
        ref.read(binderPageNumberProvider.notifier).set(1);
        ref.read(openBinderProvider.notifier).open(unsortedBinder);
      },
      leading: Icon(Icons.inbox_outlined, color: theme.colorScheme.primary),
      title: const Text('À trier'),
      subtitle: Text(
        '$waiting exemplaire${waiting > 1 ? 's' : ''} sans édition — '
        'rangeables nulle part tant qu\'on n\'a pas dit lesquels',
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}

/// La pile des cartes sans édition.
///
/// **Ni cases ni numéros** : ces cartes n'ont pas de place. On les montre pour
/// pouvoir leur en donner une — toucher une carte ouvre le sélecteur d'édition,
/// et la pile se vide à mesure qu'on range.
class _UnsortedPile extends ConsumerWidget {
  const _UnsortedPile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final page = ref.watch(binderPageNumberProvider);
    final cards = ref.watch(unsortedPileProvider(page));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Retour à l\'étagère',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => ref.read(openBinderProvider.notifier).close(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('À trier', style: theme.textTheme.titleSmall),
                    Text(
                      'Touchez une carte pour lui donner son édition',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Page précédente',
                icon: const Icon(Icons.chevron_left),
                onPressed: page <= 1
                    ? null
                    : () => ref
                          .read(binderPageNumberProvider.notifier)
                          .set(page - 1),
              ),
              IconButton(
                tooltip: 'Page suivante',
                icon: const Icon(Icons.chevron_right),
                onPressed: (cards.asData?.value.length ?? 0) < binderPageSize
                    ? null
                    : () => ref
                          .read(binderPageNumberProvider.notifier)
                          .set(page + 1),
              ),
            ],
          ),
        ),
        Expanded(
          child: cards.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (error, _) => StateMessage(
              icon: Icons.cloud_off,
              title: 'Pile illisible',
              detail: '$error',
              onRetry: () => ref.invalidate(unsortedPileProvider),
            ),
            data: (list) => list.isEmpty
                ? const StateMessage(
                    icon: Icons.check_circle_outline,
                    title: 'Rien à trier',
                    detail: 'Toutes vos cartes ont trouvé leur case.',
                  )
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: GridView.count(
                      crossAxisCount: 3,
                      childAspectRatio: 0.72,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [
                        for (final card in list) _UnsortedCardTile(card: card),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _UnsortedCardTile extends ConsumerWidget {
  const _UnsortedCardTile({required this.card});

  final UnsortedCard card;

  Future<void> _sort(BuildContext context, WidgetRef ref) async {
    final chosen = await showPrintingPicker(
      context,
      oracleId: card.oracleId,
      cardName: card.shownName,
    );
    if (chosen == null || chosen.isUnspecified || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    // La tuile disparaît de la pile avec le rangement : l'annulation ne peut
    // pas s'appuyer sur `ref`, dont l'état meurt avec elle.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      // Le même geste que dans la liste : « ces exemplaires-là sont de cette
      // édition ». Rien n'est ajouté, tout est déplacé.
      final moved = await container
          .read(collectionRepositoryProvider)
          .setPrinting(
            card.oracleId,
            toPrintId: chosen.printing.printId,
            toFoil: chosen.isFoil,
          );

      _refreshPile(container);

      // **La vignette s'évanouit : il faut dire où elle est allée.** C'est le
      // geste dont la disparition est la moins lisible — la carte quitte
      // l'écran regardé pour un classeur qu'on n'a pas ouvert. Et c'est aussi
      // pourquoi le retour est offert : se tromper de case range la carte hors
      // de vue, là où la retrouver suppose de savoir où l'on s'est trompé.
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Rangée dans ${chosen.printing.label}'),
            duration: const Duration(seconds: 5),
            // Sans cela le bandeau attendrait un balayage et recouvrirait la
            // pile qu'on est en train de trier.
            persist: false,
            action: moved < 1
                ? null
                : SnackBarAction(
                    label: 'Annuler',
                    onPressed: () =>
                        unawaited(_unsort(messenger, container, chosen, moved)),
                  ),
          ),
        );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Rangement impossible : $e')),
      );
    }
  }

  /// Ramène à la pile les exemplaires qu'on vient d'en sortir — ceux-là seuls.
  ///
  /// La quantité est indispensable : la case de destination peut déjà porter
  /// des exemplaires de la même édition, et un retour sans elle les emporterait
  /// avec. Ils quitteraient un classeur où ils étaient bien rangés.
  Future<void> _unsort(
    ScaffoldMessengerState messenger,
    ProviderContainer container,
    PrintingChoice chosen,
    int moved,
  ) async {
    try {
      await container
          .read(collectionRepositoryProvider)
          .setPrinting(
            card.oracleId,
            fromPrintId: chosen.printing.printId,
            toPrintId: null,
            quantity: moved,
            fromFoil: chosen.isFoil,
          );
      _refreshPile(container);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Annulation impossible : $e')),
      );
    }
  }

  /// La carte change de place : la pile, l'étagère et les totaux changent avec.
  void _refreshPile(ProviderContainer container) {
    container.invalidate(unsortedPileProvider);
    container.invalidate(binderShelfProvider);
    container.invalidate(collectionProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(8);
    final image = card.imageUrl;

    return InkWell(
      onTap: () => _sort(context, ref),
      borderRadius: radius,
      child: ClipRRect(
        borderRadius: radius,
        child: FoilSheen(
          foil: card.hasFoil,
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (image == null)
                ColoredBox(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        card.shownName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                )
              else
                CardImage(
                  url: image,
                  placeholder: ColoredBox(
                    color: theme.colorScheme.surfaceContainerLow,
                  ),
                  errorBuilder: (_) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerLow,
                    child: Center(
                      child: Text(
                        card.shownName,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
              if (card.owned > 1)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      child: Text(
                        '×${card.owned}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Marge d'une feuille, écart entre deux cases, proportion d'une carte.
const _facePadding = 12.0;
const _cellSpacing = 8.0;
const _cardRatio = 0.716;

/// Largeur qu'une face de neuf cases occupe naturellement à cette hauteur.
///
/// **Trois rangées de cartes ne s'étirent pas.** Une page de classeur a la
/// forme que lui donnent ses cartes ; c'est la hauteur qui décide, et la
/// largeur suit. Sans cela, la double page s'écartait aux deux bords d'un écran
/// couché en laissant deux cent soixante points de vide au milieu — deux
/// colonnes isolées, et plus rien qui ressemble à un classeur ouvert.
double binderFaceWidth(double height) {
  final cellHeight = (height - _facePadding * 2 - _cellSpacing * 2) / 3;
  if (cellHeight <= 0) return 0;
  return cellHeight * _cardRatio * 3 + _cellSpacing * 2 + _facePadding * 2;
}

/// Numéro de la page de gauche de la double page qui contient [page].
///
/// **Les faces s'apparient (1,2), (3,4)…** Un vrai classeur relié montrerait la
/// première page seule à droite, comme un livre ; celui-ci n'a pas de
/// couverture, et commencer par une demi-page gâcherait une moitié d'écran pour
/// une fidélité que personne ne réclame.
int spreadStart(int page) => page.isOdd ? page : page - 1;

/// Autorise le paysage tant qu'on regarde une page, puis le retire.
///
/// **L'application est verrouillée en portrait**, et c'est un bon réglage
/// partout ailleurs : la saisie, la recherche et les decks sont des colonnes de
/// texte, et les coucher ne donne rien de plus. Une page de classeur, elle, est
/// un objet physique dont la forme naturelle est la double page — c'est le seul
/// écran qui gagne à tourner, donc le seul qui l'autorise.
///
/// Le verrou revient en quittant l'écran : si l'appareil est resté couché, le
/// système le redresse, et l'on ne se retrouve pas avec une étagère en travers
/// sans avoir rien demandé.
class _AllowLandscape extends StatefulWidget {
  const _AllowLandscape({required this.child});

  final Widget child;

  @override
  State<_AllowLandscape> createState() => _AllowLandscapeState();
}

class _AllowLandscapeState extends State<_AllowLandscape> {
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _showBars();
    super.dispose();
  }

  /// **Les barres du système comptent aussi.** Sur les 408 points d'un
  /// téléphone couché, l'heure et la barre de gestes en prennent une
  /// quarantaine — un dixième de la hauteur, soit un dixième de la taille des
  /// cartes. Elles reviennent d'un glissement depuis le bord, et à la sortie de
  /// l'écran quoi qu'il arrive.
  void _sync(bool landscape) {
    if (landscape == _hidden) return;
    _hidden = landscape;
    if (landscape) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      _showBars();
    }
  }

  void _showBars() =>
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  @override
  Widget build(BuildContext context) {
    _sync(MediaQuery.orientationOf(context) == Orientation.landscape);
    return widget.child;
  }
}

/// Une page de classeur : trois cases sur trois, dans l'ordre des numéros.
///
/// **Couché, le classeur s'ouvre à plat.** Deux faces côte à côte, reliure au
/// milieu, exactement comme un classeur posé sur une table — c'est la forme que
/// l'objet a dans la vraie vie, et l'écran couché en a la place. Le numéro de
/// page suit : on se déplace de deux en deux, et « page 3 sur 51 » devient
/// « pages 3-4 sur 51 ».
class _Binder extends ConsumerWidget {
  const _Binder({required this.setCode});

  final String setCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(binderPageNumberProvider);
    final reading = ref.watch(binderReadingProvider);
    // L'orientation, et non la largeur : c'est le geste de tourner l'appareil
    // qui ouvre le classeur, pas un seuil de pixels qu'on franchirait sans le
    // vouloir sur une tablette étroite.
    final spread = MediaQuery.orientationOf(context) == Orientation.landscape;
    final cells = ref.watch(
      binderPageProvider((
        setCode: setCode,
        page: page,
        sort: reading.sort,
        finish: reading.finish,
        descending: reading.descending,
      )),
    );
    final entry = ref
        .watch(binderShelfProvider)
        .asData
        ?.value
        .where((e) => e.setCode == setCode)
        .firstOrNull;

    final pages = entry?.pages ?? 1;
    // Couché, on regarde deux faces et on en découvre deux : le voisinage à
    // précharger double.
    final left = spread ? spreadStart(page) : page;
    final neighbours = spread
        ? [left - 2, left - 1, left + 2, left + 3]
        : [page - 1, page + 1];

    // **Seules les feuilles voisines sont préchargées.** Une feuille pèse neuf
    // cartes entières ; en précharger davantage rapatrierait un classeur entier
    // pour en montrer un neuvième. Le `watch` suffit à déclencher la requête et
    // à la garder en cache le temps qu'on reste sur ce classeur.
    for (final neighbour in neighbours) {
      if (neighbour >= 1 && neighbour <= pages) {
        ref.watch(
          binderPageProvider((
            setCode: setCode,
            page: neighbour,
            sort: reading.sort,
            finish: reading.finish,
            descending: reading.descending,
          )),
        );
      }
    }

    final sheet = Column(
      children: [
        if (!spread) _BinderHeader(entry: entry, setCode: setCode, page: page),
        // **Les menus de lecture ne survivent pas au paysage.** Ils coûtent
        // une rangée de cartes sur un écran qui n'en a que trois, pour un
        // réglage qu'on pose une fois et qu'on retrouve intact en redressant
        // l'appareil.
        if (!spread) _ReadingSelector(setCode: setCode),
        Expanded(
          child: cells.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (error, _) => StateMessage(
              icon: Icons.cloud_off,
              title: 'Page illisible',
              detail: '$error',
              onRetry: () => ref.invalidate(binderPageProvider),
            ),
            data: (list) => list.isEmpty
                ? const StateMessage(
                    icon: Icons.menu_book_outlined,
                    title: 'Page vide',
                    detail: 'Ce classeur n\'a pas de page à cet endroit.',
                  )
                : _Sized(
                    spread: spread,
                    child: PageTurner(
                      // Couché, l'unité qui se tourne est la double page : le
                      // composant compte en feuilles, la collection en faces.
                      page: spread ? (left + 1) ~/ 2 : page,
                      pageCount: spread ? (pages + 1) ~/ 2 : pages,
                      onTurned: (p) => ref
                          .read(binderPageNumberProvider.notifier)
                          .set(spread ? (p * 2 - 1).clamp(1, pages) : p),
                      builder: (context, sheet) => _PageFace(
                        setCode: setCode,
                        page: spread ? sheet * 2 : sheet,
                        reading: reading,
                      ),
                      facingBuilder: !spread
                          ? null
                          : (context, sheet) => _PageFace(
                              setCode: setCode,
                              page: sheet * 2 - 1,
                              reading: reading,
                            ),
                    ),
                  ),
          ),
        ),
      ],
    );

    if (!spread) return _AllowLandscape(child: sheet);

    // **Couché, l'entête se pose dans la marge plutôt qu'au-dessus.** Une
    // double page ne remplit jamais la largeur d'un écran couché — trois
    // rangées de cartes réclament de la hauteur, et deux pages n'occupent que
    // 1,43 fois cette hauteur, quand l'écran en fait 2,2. Le vide est donc
    // acquis sur les côtés ; l'entête y tient sans coûter une seule rangée de
    // cartes, là où il en mangeait un sixième en haut.
    return _AllowLandscape(
      child: Stack(
        children: [
          Positioned.fill(child: sheet),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: _BinderRail(entry: entry, setCode: setCode, page: page),
          ),
        ],
      ),
    );
  }
}

/// L'entête d'un classeur couché, debout dans la marge.
///
/// Les mêmes commandes que l'entête horizontal — revenir, savoir où l'on est,
/// sauter d'une feuille — mais empilées, parce que c'est de la largeur qu'on a
/// en trop et de la hauteur qu'on manque.
class _BinderRail extends ConsumerWidget {
  const _BinderRail({
    required this.entry,
    required this.setCode,
    required this.page,
  });

  final BinderShelfEntry? entry;
  final String setCode;
  final int page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pages = entry?.pages ?? 1;
    final first = spreadStart(page);
    final label = first < pages ? 'Pages $first-${first + 1}' : 'Page $first';

    return SizedBox(
      width: 132,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              tooltip: 'Retour à l\'étagère',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => ref.read(openBinderProvider.notifier).close(),
            ),
            const Spacer(),
            Text(
              entry?.setName ?? setCode.toUpperCase(),
              style: theme.textTheme.titleSmall,
              maxLines: 3,
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: pages <= 1
                  ? null
                  : () => _askPage(context, ref, page: page, pages: pages),
              child: Text(
                pages > 1 ? '$label sur $pages  ›' : label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: pages > 1
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  tooltip: 'Double page précédente',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left),
                  onPressed: first <= 1
                      ? null
                      : () => ref
                            .read(binderPageNumberProvider.notifier)
                            .set(first - 2),
                ),
                IconButton(
                  tooltip: 'Double page suivante',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_right),
                  onPressed: first + 2 > pages
                      ? null
                      : () => ref
                            .read(binderPageNumberProvider.notifier)
                            .set(first + 2),
                ),
              ],
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

/// Resserre la double page sur la largeur que ses cartes réclament.
///
/// En page simple il n'y a rien à faire : la feuille occupe ce qu'on lui donne.
class _Sized extends StatelessWidget {
  const _Sized({required this.spread, required this.child});

  final bool spread;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!spread) return child;
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: SizedBox(
          width: math.min(
            constraints.maxWidth,
            binderFaceWidth(constraints.maxHeight) * 2,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Une face de feuille : neuf cases, pochettes visibles.
///
/// Isolée du reste pour que le retournement puisse en construire deux — la
/// feuille qui pivote et celle qu'on découvre dessous — sans dupliquer la
/// grille ni son chargement.
class _PageFace extends ConsumerWidget {
  const _PageFace({
    required this.setCode,
    required this.page,
    required this.reading,
  });

  final String setCode;
  final int page;
  final BinderReading reading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cells = ref.watch(
      binderPageProvider((
        setCode: setCode,
        page: page,
        sort: reading.sort,
        finish: reading.finish,
        descending: reading.descending,
      )),
    );

    return DecoratedBox(
      // La feuille a sa propre teinte : sans fond opaque, on verrait par
      // transparence la page du dessous pendant le retournement.
      decoration: BoxDecoration(color: theme.colorScheme.surface),
      child: Padding(
        padding: const EdgeInsets.all(_facePadding),
        child: cells.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          // **La feuille entière doit tenir à l'écran.** Un rapport figé à
          // 0,72 — la proportion d'une carte — débordait en hauteur : la
          // troisième rangée sortait du cadre. Une feuille de classeur ne
          // défile pas, elle se tourne ; c'est donc la grille qui s'adapte,
          // quitte à laisser un peu d'air sur les côtés.
          data: (list) => LayoutBuilder(
            builder: (context, constraints) {
              // Une case ne dépasse jamais la proportion d'une carte : au-delà,
              // l'image serait rognée sur les côtés au lieu de l'être en bas.
              const spacing = _cellSpacing;
              const cardRatio = _cardRatio;

              // **La feuille se règle sur la plus contraignante des deux
              // dimensions.** En portrait c'est la largeur, et la grille
              // occupait tout ; en paysage, une demi-largeur est large et
              // basse, et une grille réglée sur la largeur débordait de
              // beaucoup — trois rangées de cartes hautes dans une moitié
              // d'écran couché. On part donc de la hauteur disponible, on en
              // déduit la largeur qu'une carte y autorise, et on garde la plus
              // petite des deux. Une feuille de classeur ne défile pas.
              final cellHeight = (constraints.maxHeight - spacing * 2) / 3;
              final gridWidth = math.min(
                constraints.maxWidth,
                cellHeight * cardRatio * 3 + spacing * 2,
              );
              final cellWidth = (gridWidth - spacing * 2) / 3;

              return Center(
                child: SizedBox(
                  width: gridWidth,
                  child: GridView.count(
                    crossAxisCount: 3,
                    childAspectRatio: cellWidth / cellHeight,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    // Un défilement vertical intercepterait le geste horizontal
                    // du retournement.
                    physics: const NeverScrollableScrollPhysics(),
                    children: [for (final cell in list) _Cell(cell: cell)],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Demande une feuille et s'y rend.
///
/// La glissière permanente coûtait la hauteur d'une rangée de cartes pour un
/// geste rare : on feuillette de proche en proche, on ne saute d'un bout à
/// l'autre qu'en cherchant quelque chose de précis.
Future<void> _askPage(
  BuildContext context,
  WidgetRef ref, {
  required int page,
  required int pages,
}) async {
  var chosen = page.toDouble();
  final target = await showModalBottomSheet<int>(
    context: context,
    useSafeArea: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Aller à la page ${chosen.round()}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Slider(
                value: chosen,
                min: 1,
                max: pages.toDouble(),
                divisions: pages > 1 ? pages - 1 : null,
                label: 'Page ${chosen.round()}',
                onChanged: (v) => setSheetState(() => chosen = v),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(chosen.round()),
                child: const Text('Y aller'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  if (target != null) {
    ref.read(binderPageNumberProvider.notifier).set(target);
  }
}

/// Ordre de lecture et finition retenue.
///
/// **Changer de lecture ramène à une page qui a quelque chose à montrer.** Un
/// filtre serré laisse des feuilles entièrement creuses — sur 97 feuilles dont
/// douze cartes, ouvrir à la première serait ouvrir sur du vide. Le serveur dit
/// où commencer ; hors du rangement, les cases vides ayant disparu, la première
/// page est toujours pleine et la question ne se pose pas.
class _ReadingSelector extends ConsumerWidget {
  const _ReadingSelector({required this.setCode});

  final String setCode;

  Future<void> _jumpToFirstFilled(WidgetRef ref, FinishFilter finish) async {
    final page = await ref
        .read(binderRepositoryProvider)
        .firstPage(setCode, finish: finish);
    ref.read(binderPageNumberProvider.notifier).set(page);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading = ref.watch(binderReadingProvider);

    // **Deux menus plutôt que six puces.** Les puces occupaient une ligne
    // entière et débordaient de l'écran — il fallait faire défiler pour
    // atteindre « Brillantes ». La hauteur ainsi rendue va aux cartes, qui
    // étaient coupées en bas de page.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<BinderSort>(
              initialValue: reading.sort,
              isDense: true,
              decoration: _dense(
                context,
                reading.descending ? Icons.arrow_upward : Icons.arrow_downward,
              ),
              // **Re-choisir un critère renverse le classeur.** C'est le geste
              // de l'ancienne liste, perdu en passant aux menus : le libellé de
              // l'entrée déjà choisie annonce donc ce qu'un second appui fera —
              // « Dernière page d'abord », « Les moins chères d'abord »,
              // « De Z à A » — plutôt que de laisser croire à un choix inerte.
              items: [
                for (final sort in BinderSort.values)
                  DropdownMenuItem(
                    value: sort,
                    child: Text(
                      sort == reading.sort && !reading.descending
                          ? '${sort.label} — ${sort.reversedLabel}'
                          : sort.label,
                    ),
                  ),
              ],
              // Le champ fermé ne montre que le critère : la phrase du menu y
              // déborderait, et n'a de sens qu'au moment de choisir.
              selectedItemBuilder: (context) => [
                for (final sort in BinderSort.values)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(sort.label),
                  ),
              ],
              onChanged: (sort) {
                if (sort == null) return;
                ref.read(binderReadingProvider.notifier).sortBy(sort);
                // Le numéro de page d'un ordre n'a aucun sens dans un autre :
                // la page 42 par numéro n'est pas la page 42 par valeur.
                ref.read(binderPageNumberProvider.notifier).set(1);
                if (sort.keepsEmptyCells) {
                  unawaited(_jumpToFirstFilled(ref, reading.finish));
                }
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonFormField<FinishFilter>(
              initialValue: reading.finish,
              isDense: true,
              decoration: _dense(context, Icons.auto_awesome_outlined),
              items: [
                for (final finish in FinishFilter.values)
                  DropdownMenuItem(value: finish, child: Text(finish.label)),
              ],
              onChanged: (finish) {
                if (finish == null) return;
                ref.read(binderReadingProvider.notifier).filter(finish);
                ref.read(binderPageNumberProvider.notifier).set(1);
                if (reading.sort.keepsEmptyCells) {
                  unawaited(_jumpToFirstFilled(ref, finish));
                }
              },
            ),
          ),
          // **Le fantôme ne s'offre que dans le régime de rangement.** Hors de
          // lui, les cases vides ne sont pas rendues par le serveur : un
          // interrupteur qui ne changerait rien à l'écran laisserait croire à
          // une panne.
          if (reading.sort.keepsEmptyCells) const _MissingArtToggle(),
        ],
      ),
    );
  }

  static InputDecoration _dense(BuildContext context, IconData icon) =>
      InputDecoration(
        isDense: true,
        prefixIcon: Icon(icon, size: 18),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );
}

/// Montrer ou non, en transparence, la carte que chaque case vide attend.
///
/// Un bouton plutôt qu'un troisième menu : c'est un oui-ou-non, et la ligne des
/// commandes est déjà pleine — la hauteur qu'elle prendrait est celle des
/// cartes.
class _MissingArtToggle extends ConsumerWidget {
  const _MissingArtToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = ref.watch(showMissingArtProvider);

    return IconButton(
      onPressed: ref.read(showMissingArtProvider.notifier).toggle,
      isSelected: shown,
      visualDensity: VisualDensity.compact,
      icon: Icon(
        shown ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        size: 20,
      ),
      tooltip: shown
          ? 'Masquer les cartes manquantes'
          : 'Montrer les cartes manquantes',
    );
  }
}

class _BinderHeader extends ConsumerWidget {
  const _BinderHeader({
    required this.entry,
    required this.setCode,
    required this.page,
  });

  final BinderShelfEntry? entry;
  final String setCode;
  final int page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pages = entry?.pages ?? 1;
    final spread = MediaQuery.orientationOf(context) == Orientation.landscape;
    final first = spread ? spreadStart(page) : page;
    final step = spread ? 2 : 1;
    // « Pages 3-4 sur 51 » couché, sauf sur la dernière feuille d'un classeur
    // au nombre impair de faces : la moitié droite y est vide, l'annoncer
    // serait promettre une page qui n'existe pas.
    final label = spread && first < pages
        ? 'Pages $first-${first + 1} sur $pages'
        : 'Page $first sur $pages';

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Retour à l\'étagère',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => ref.read(openBinderProvider.notifier).close(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry?.setName ?? setCode.toUpperCase(),
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // **Le saut de page vit ici depuis que la glissière a disparu.**
                // Elle mangeait la hauteur d'une rangée de cartes ; traverser
                // 51 feuilles reste possible, mais à la demande.
                InkWell(
                  onTap: pages <= 1
                      ? null
                      : () => _askPage(context, ref, page: page, pages: pages),
                  child: Text(
                    pages > 1 ? '$label  ›' : label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: pages > 1
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // **Le pas suit ce qu'on voit.** Couché, une flèche fait tourner une
          // feuille entière — deux faces —, sinon le bouton et le geste ne
          // feraient pas la même chose sur le même écran.
          IconButton(
            tooltip: spread ? 'Double page précédente' : 'Page précédente',
            icon: const Icon(Icons.chevron_left),
            onPressed: first <= 1
                ? null
                : () => ref
                      .read(binderPageNumberProvider.notifier)
                      .set(first - step),
          ),
          IconButton(
            tooltip: spread ? 'Double page suivante' : 'Page suivante',
            icon: const Icon(Icons.chevron_right),
            onPressed: first + step > pages
                ? null
                : () => ref
                      .read(binderPageNumberProvider.notifier)
                      .set(first + step),
          ),
        ],
      ),
    );
  }
}

/// Une case : la carte qu'on y range, ou le creux qu'elle laisse.
///
/// **La carte entière, et non son illustration.** Une case de classeur contient
/// une carte — son cadre, son nom, son coût, son numéro. N'en montrer que
/// l'illustration donnait une planche-contact, jolie mais impossible à
/// reconnaître comme sa propre collection. Le nom imprimé devient illisible à
/// trois par ligne, exactement comme dans un vrai classeur qu'on regarde de
/// loin : c'est l'image qu'on reconnaît, pas le texte qu'on lit.
class _Cell extends ConsumerWidget {
  const _Cell({required this.cell});

  final BinderCell cell;

  /// Ce qu'il reste d'une carte qu'on ne possède pas.
  ///
  /// Assez pour la reconnaître, assez peu pour qu'aucune case vide ne se
  /// confonde avec une case pleine : c'est un manque qu'on montre, pas une
  /// carte.
  static const double _ghostOpacity = 0.24;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final empty = cell.isEmpty;
    final radius = BorderRadius.circular(8);
    final image = cell.imageUrl;

    if (empty || image == null) {
      final ghost = image != null && ref.watch(showMissingArtProvider);

      // **Une case vide dit désormais laquelle.** Elle reste creusée et porte
      // toujours son numéro, mais « #2 » nommait la case et non la carte : il
      // fallait chercher ailleurs pour savoir quoi acheter. L'illustration en
      // fantôme la nomme sans jamais la faire passer pour possédée.
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.35,
          ),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ghost)
                // L'appui long agrandit la carte manquante : à trois par ligne
                // et à un quart d'opacité, on la reconnaît sans pouvoir la
                // lire. Toucher la case, en revanche, n'ouvre toujours rien —
                // il n'y a rien à ajouter ni à retirer d'une carte qu'on ne
                // possède pas.
                GestureDetector(
                  onLongPress: () => showCardImage(
                    context,
                    imageUrl: image,
                    title: cell.shownName,
                  ),
                  child: Opacity(
                    opacity: _ghostOpacity,
                    child: CardImage(url: image),
                  ),
                ),
              Center(
                child: Text(
                  '#${cell.collectorNumber}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    // Sur une illustration, même fantôme, le numéro perdrait
                    // ses contours clairs.
                    shadows: ghost
                        ? [
                            Shadow(
                              blurRadius: 4,
                              color: theme.colorScheme.surface,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => showCellActions(context, cell),
      // **L'appui long montre la carte en grand.** À trois par ligne, le texte
      // imprimé est illisible — c'est assumé, on reconnaît l'image — mais lire
      // une carte reste parfois nécessaire, et rien ne le permettait.
      onLongPress: () => showCardImage(
        context,
        imageUrl: image,
        title: cell.shownName,
        foil: cell.hasFoil,
      ),
      borderRadius: radius,
      child: ClipRRect(
        borderRadius: radius,
        child: FoilSheen(
          foil: cell.hasFoil,
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CardImage(
                url: image,
                // Le cadre reste visible pendant le chargement : sans lui, la
                // grille se recompose sous les yeux à chaque page tournée.
                placeholder: ColoredBox(
                  color: theme.colorScheme.surfaceContainerLow,
                ),
                errorBuilder: (_) => ColoredBox(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Center(
                    child: Text(
                      '#${cell.collectorNumber}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
              // Les doublons se comptent sur la case, pas à côté : un
              // exemplaire de plus ne prend pas de place dans un classeur, il
              // s'empile derrière le premier.
              if (cell.owned > 1)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      child: Text(
                        '×${cell.owned}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ce qu'on peut faire d'une carte rangée.
///
/// **Ces gestes vivaient dans la liste**, qui n'existe plus : ajouter un
/// exemplaire, en retirer un, corriger l'édition. Les perdre en supprimant la
/// liste aurait été une régression déguisée en simplification — le retrait,
/// notamment, n'existe nulle part ailleurs.
Future<void> showCellActions(BuildContext context, BinderCell cell) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) => _CellActions(cell: cell),
  );
}

class _CellActions extends ConsumerStatefulWidget {
  const _CellActions({required this.cell});

  final BinderCell cell;

  @override
  ConsumerState<_CellActions> createState() => _CellActionsState();
}

class _CellActionsState extends ConsumerState<_CellActions> {
  /// Finition sur laquelle portent les actions.
  ///
  /// **Une case ne dit pas de quelle finition on veut ajouter un exemplaire.**
  /// Elle signale ce qu'elle contient — un brillant, ou non — mais on peut très
  /// bien tenir en main l'autre version : elles se rangent dans la même case et
  /// ne valent pas le même prix. Le choix part donc de ce qui est déjà rangé,
  /// et se change.
  late bool _foil = widget.cell.hasFoil;

  BinderCell get cell => widget.cell;

  /// Écrit en collection, referme la feuille, et **dit ce qui vient d'arriver**.
  ///
  /// **Le classeur était le seul écran muet.** Les quatre voies de saisie
  /// accusent réception par une SnackBar ; ici, corriger une édition envoyait
  /// la carte dans le classeur d'une autre extension et vidait la case sous le
  /// doigt, sans un mot. Rien ne distinguait alors « c'est fait » de « la
  /// feuille s'est refermée toute seule », et la seule façon de vérifier était
  /// d'aller chercher la carte ailleurs.
  ///
  /// L'échec parle aussi : il était jusqu'ici avalé, la feuille se refermant
  /// de la même façon qu'en cas de succès.
  ///
  /// **[action] rend ce qu'elle a fait**, non l'état résultant : le nombre
  /// d'exemplaires retirés ou déplacés. Zéro veut dire « rien n'a bougé » — la
  /// ligne visée n'existait pas —, et alors ni [done] ni [undo] n'ont lieu
  /// d'être : annoncer un retrait qui n'a pas eu lieu serait un mensonge, et
  /// proposer de l'annuler inventerait une carte. C'est le cas réel d'une case
  /// qui ne contient que du normal et sur laquelle on demande « retirer un
  /// exemplaire brillant », les deux finitions se rangeant ensemble.
  ///
  /// **[undo] reçoit ce nombre**, seule information dont il ait besoin pour
  /// écrire l'inverse exact. Il s'exécute après la fermeture de la feuille,
  /// donc sur le conteneur de providers et non sur `ref`, dont l'état est mort
  /// avec le widget.
  Future<void> _write(
    BuildContext context,
    WidgetRef ref, {
    required Future<int> Function() action,
    required String done,
    required String failed,
    String? nothing,
    Future<void> Function(ProviderContainer container, int count)? undo,
  }) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // Le conteneur survit à la feuille, `ref` non : c'est lui qui portera
    // l'annulation et le rafraîchissement qui la suit.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final count = await action();
      _refresh(container);
      navigator.pop();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          count < 1
              ? SnackBar(
                  content: Text(nothing ?? done),
                  duration: const Duration(seconds: 3),
                )
              : SnackBar(
                  content: Text(done),
                  duration: const Duration(seconds: 5),
                  // Flutter fait persister indéfiniment toute notification
                  // porteuse d'une action : le bandeau attendrait un balayage
                  // et recouvrirait entre-temps les commandes du classeur.
                  // Annuler est une commodité, pas une question posée.
                  persist: false,
                  action: undo == null
                      ? null
                      : SnackBarAction(
                          label: 'Annuler',
                          onPressed: () => unawaited(
                            _undo(messenger, container, undo, count, failed),
                          ),
                        ),
                ),
        );
    } catch (e) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('$failed : $e')));
    }
  }

  /// Rejoue l'inverse, et le dit s'il échoue.
  ///
  /// Statique de fait — elle ne touche à rien du widget, qui n'existe plus.
  static Future<void> _undo(
    ScaffoldMessengerState messenger,
    ProviderContainer container,
    Future<void> Function(ProviderContainer, int) undo,
    int count,
    String failed,
  ) async {
    try {
      await undo(container, count);
      _refresh(container);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Annulation impossible : $e')),
      );
    }
  }

  static void _refresh(ProviderContainer container) {
    container.invalidate(binderPageProvider);
    container.invalidate(binderShelfProvider);
    container.invalidate(collectionProvider);
    container.invalidate(binderFindProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final oracleId = cell.oracleId;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(cell.shownName, style: theme.textTheme.titleMedium),
                      Text(
                        '#${cell.collectorNumber} · ${cell.owned} exemplaire'
                        '${cell.owned > 1 ? 's' : ''}'
                        '${cell.hasFoil ? ' · brillant' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // **Le prix suit la finition qu'on s'apprête à ajouter.** Le
                // brillant vaut couramment le double ou le triple de sa jumelle
                // mate ; afficher l'un pour l'autre tromperait sur la valeur de
                // ce qu'on range. Un tiret dit l'absence de cote — un zéro
                // ferait croire à une carte sans valeur.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(switch (cell.priceFor(foil: _foil)) {
                      final price? => '${price.toStringAsFixed(2)} €',
                      _ => '—',
                    }, style: theme.textTheme.titleMedium),
                    Text(
                      _foil ? 'brillante' : 'normale',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // **La finition se choisit avant d'agir.** Une case dit ce qu'elle
          // contient, pas ce qu'on tient en main : on peut posséder la version
          // normale et vouloir ajouter la brillante, qui se range dans la même
          // case mais ne vaut pas le même prix. Sans ce choix, il n'y avait
          // aucun moyen d'ajouter l'autre finition depuis le classeur.
          if (oracleId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Normale')),
                  ButtonSegment(value: true, label: Text('Brillante')),
                ],
                selected: {_foil},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _foil = v.first),
              ),
            ),
          const Divider(height: 16),
          if (oracleId != null) ...[
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(
                _foil
                    ? 'Ajouter un exemplaire brillant'
                    : 'Ajouter un exemplaire normal',
              ),
              onTap: () => _write(
                context,
                ref,
                // `add` rend le total de l'édition ; ce qui a été fait, c'est
                // un exemplaire. On le dit plutôt que de laisser un total
                // passer pour tel — l'inverse est d'ailleurs offert juste en
                // dessous, ce qui dispense d'un « Annuler » ici.
                action: () => ref
                    .read(collectionRepositoryProvider)
                    .add(oracleId, printId: cell.printId, isFoil: _foil)
                    .then((_) => 1),
                done: _foil
                    ? 'Un exemplaire brillant ajouté'
                    : 'Un exemplaire ajouté',
                failed: 'Ajout impossible',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.remove),
              title: Text(
                _foil
                    ? 'Retirer un exemplaire brillant'
                    : 'Retirer un exemplaire normal',
              ),
              onTap: () => _write(
                context,
                ref,
                action: () => ref
                    .read(collectionRepositoryProvider)
                    .remove(oracleId, printId: cell.printId, isFoil: _foil),
                done: _foil
                    ? 'Un exemplaire brillant retiré'
                    : 'Un exemplaire retiré',
                // Une case range ensemble le normal et le brillant : demander
                // à retirer une finition qu'elle ne contient pas est un cas
                // ordinaire, et il ne doit pas s'annoncer comme un retrait.
                nothing: _foil
                    ? 'Aucun exemplaire brillant à retirer ici'
                    : 'Aucun exemplaire normal à retirer ici',
                failed: 'Retrait impossible',
                // L'inverse d'un retrait est un ajout sur la même ligne, et il
                // est exact : la ligne a perdu ce nombre d'exemplaires, elle
                // les retrouve. Si elle avait disparu, elle renaît avec eux.
                undo: (container, count) => container
                    .read(collectionRepositoryProvider)
                    .add(
                      oracleId,
                      quantity: count,
                      printId: cell.printId,
                      isFoil: _foil,
                    ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.layers_outlined),
              title: const Text('Corriger l\'édition'),
              subtitle: const Text('Si ce n\'est pas celle que vous tenez'),
              onTap: () async {
                final navigator = Navigator.of(context);
                final chosen = await showPrintingPicker(
                  context,
                  oracleId: oracleId,
                  cardName: cell.shownName,
                  currentPrintId: cell.printId,
                  currentIsFoil: _foil,
                );
                if (chosen == null || chosen.isUnspecified) {
                  navigator.pop();
                  return;
                }
                if (!context.mounted) return;
                await _write(
                  context,
                  ref,
                  action: () => ref
                      .read(collectionRepositoryProvider)
                      .setPrinting(
                        oracleId,
                        fromPrintId: cell.printId,
                        toPrintId: chosen.printing.printId,
                        fromFoil: _foil,
                        toFoil: chosen.isFoil,
                      ),
                  done: 'Édition enregistrée : ${chosen.printing.label}',
                  nothing: 'Cette édition était déjà celle enregistrée',
                  failed: 'Édition non enregistrée',
                  // **L'inverse n'est exact qu'avec la quantité.** La
                  // destination peut porter d'autres exemplaires que ceux qui
                  // viennent d'arriver — ils y ont fusionné —, et un
                  // mouvement de retour sans quantité les emporterait tous.
                  undo: (container, count) => container
                      .read(collectionRepositoryProvider)
                      .setPrinting(
                        oracleId,
                        fromPrintId: chosen.printing.printId,
                        toPrintId: cell.printId,
                        quantity: count,
                        fromFoil: chosen.isFoil,
                        toFoil: _foil,
                      ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
