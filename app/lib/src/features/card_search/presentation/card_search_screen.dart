/// Écran de saisie de collection : on tape un nom, les cartes apparaissent, on
/// les ajoute.
///
/// La frappe est amortie avant d'atteindre le réseau : sans cela, « lightning »
/// déclencherait neuf requêtes dont huit sans intérêt. Le délai est court pour
/// que la liste paraisse suivre la frappe.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/selected_game.dart';
import '../../collection/data/collection_repository.dart';
import '../../printings/presentation/card_art_view.dart';
import '../../printings/presentation/printing_picker.dart';
import '../data/card_repository.dart';
import '../domain/card_hit.dart';
import '../domain/card_type.dart';

/// Amortissement de la frappe. 250 ms : au-delà la liste semble traîner,
/// en deçà on repart en requête entre deux touches.
const _debounce = Duration(milliseconds: 250);

class CardSearchScreen extends ConsumerStatefulWidget {
  const CardSearchScreen({super.key});

  @override
  ConsumerState<CardSearchScreen> createState() => _CardSearchScreenState();
}

class _CardSearchScreenState extends ConsumerState<CardSearchScreen> {
  final _controller = TextEditingController();
  Timer? _timer;
  String _query = '';

  /// Types retenus. Vide = tous, ce qui est le cas courant : le filtre sert à
  /// dégager une liste encombrée, pas à décrire ce qu'on cherche.
  final Set<String> _types = {};

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(cardSearchProvider(cardQuery(_query, _types)));
    final types = cardTypesFor(ref.watch(selectedGameProvider));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // **Le type filtre avant la recherche, il ne la suit pas.** En rangée
        // de puces, il occupait une ligne entière au-dessus des résultats ;
        // ramené à gauche du champ, il se lit comme ce qu'il est — la portée
        // de ce qu'on va taper.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
          child: Row(
            children: [
              TypeFilter(
                types: types,
                selected: _types,
                onChanged: (kinds) => setState(() {
                  _types
                    ..clear()
                    ..addAll(kinds);
                }),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SearchField(
                  controller: _controller,
                  onChanged: _onChanged,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _query.isEmpty
              ? const _EmptyState()
              : results.when(
                  data: (hits) => hits.isEmpty
                      ? _NoMatch(query: _query)
                      : _ResultList(hits: hits),
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (error, _) => _ErrorState(message: '$error'),
                ),
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Rechercher',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Effacer',
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// Rangée de filtres par type, sous la barre de recherche.
///
/// **Défilable plutôt que repliée sur plusieurs lignes.** Huit types tiennent
/// mal sur la largeur d'un téléphone ; les empiler pousserait les résultats hors
/// de l'écran alors qu'ils sont l'essentiel. Les plus fréquents viennent en
/// tête, donc sous le pouce sans défiler.
/// Le type de carte auquel restreindre la recherche.
///
/// **Un menu plutôt qu'une rangée de puces.** Les puces occupaient une ligne
/// entière et débordaient de l'écran ; le menu tient à gauche du champ, où il
/// annonce la portée de ce qu'on tape. Plusieurs types restent cochables — on
/// cherche parfois « créature ou artefact » — mais l'étiquette se contente de
/// les compter au-delà du premier, faute de place.
class TypeFilter extends StatelessWidget {
  const TypeFilter({
    super.key,
    required this.types,
    required this.selected,
    required this.onChanged,
  });

  final List<CardType> types;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  String get _label {
    if (selected.isEmpty) return 'Tous types';
    final first = types
        .where((t) => selected.contains(t.kind))
        .map((t) => t.label)
        .first;
    return selected.length == 1 ? first : '$first +${selected.length - 1}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopupMenuButton<String>(
      tooltip: 'Filtrer par type',
      // La feuille reste ouverte entre deux choix : cocher trois types
      // demanderait sinon de la rouvrir trois fois.
      onSelected: (kind) {
        final next = Set<String>.from(selected);
        if (kind.isEmpty) {
          next.clear();
        } else if (!next.remove(kind)) {
          next.add(kind);
        }
        onChanged(next);
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: '', child: Text('Tous types')),
        const PopupMenuDivider(),
        for (final type in types)
          CheckedPopupMenuItem(
            value: type.kind,
            checked: selected.contains(type.kind),
            child: Text(type.label),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
          color: selected.isEmpty ? null : theme.colorScheme.secondaryContainer,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_label, style: theme.textTheme.bodyMedium),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}

class _ResultList extends StatelessWidget {
  const _ResultList({required this.hits});

  final List<CardHit> hits;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: hits.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _CardTile(hit: hits[index]),
    );
  }
}

class _CardTile extends ConsumerStatefulWidget {
  const _CardTile({required this.hit});

  final CardHit hit;

  @override
  ConsumerState<_CardTile> createState() => _CardTileState();
}

class _CardTileState extends ConsumerState<_CardTile> {
  bool _busy = false;

  /// Exemplaires possédés, tels que connus à l'affichage puis corrigés par les
  /// ajouts et retraits faits depuis cette carte. La liste de résultats n'étant
  /// pas rechargée après un ajout, sans cela le compteur resterait figé.
  int? _owned;

  /// Édition retenue pour le prochain ajout. Nulle par défaut : préciser n'est
  /// jamais obligatoire, et l'imposer rendrait la saisie de deux mille cartes
  /// pénible. Le choix reste en place d'un ajout à l'autre — on saisit
  /// généralement plusieurs cartes de la même extension à la suite.
  PrintingChoice? _printing;

  int get _quantity => _owned ?? widget.hit.owned;

  /// Ouvre le sélecteur, retient l'édition choisie, et ajoute la carte.
  ///
  /// **Désigner une édition, c'est avoir la carte en main.** Exiger ensuite un
  /// appui sur « + » ajoutait un geste à un moment où la décision est déjà
  /// prise, et sur une saisie de deux mille cartes ce geste se paie deux mille
  /// fois. Le choix vaut donc validation.
  ///
  /// « Ne pas préciser » ne déclenche rien : c'est un réglage qu'on annule, pas
  /// une carte qu'on tient. Le bouton « + » reste pour les exemplaires suivants
  /// de la même édition.
  Future<void> _choosePrinting() async {
    final hit = widget.hit;
    final chosen = await showPrintingPicker(
      context,
      oracleId: hit.oracleId,
      cardName: hit.matchedName,
      currentPrintId: _printing?.printing.printId,
      currentIsFoil: _printing?.isFoil ?? false,
      lang: hit.matchedLang,
      allowUnspecified: _printing != null,
    );
    if (chosen == null || !mounted) return;
    // Le sélecteur renvoie une édition vide pour « ne pas préciser » — `null`
    // signifiant déjà « refermé sans choisir ».
    final printing = chosen.isUnspecified ? null : chosen;
    setState(() => _printing = printing);
    if (printing != null) await _add();
  }

  /// Rattache après coup les exemplaires ajoutés sans édition.
  ///
  /// C'est le rattrapage du geste rapide : on ajoute d'abord, la notification
  /// propose de préciser, un appui suffit. Le moment compte — c'est celui où
  /// l'on a encore la carte en main.
  Future<void> _specifyAfterAdd(int quantity) async {
    final hit = widget.hit;
    final chosen = await showPrintingPicker(
      context,
      oracleId: hit.oracleId,
      cardName: hit.matchedName,
    );
    if (chosen == null || chosen.isUnspecified || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(collectionRepositoryProvider)
          .setPrinting(
            hit.oracleId,
            fromPrintId: null,
            toPrintId: chosen.printing.printId,
            toFoil: chosen.isFoil,
            quantity: quantity,
          );
      ref.invalidate(collectionProvider);
      if (!mounted) return;
      setState(() => _printing = chosen);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Édition enregistrée : ${chosen.printing.label}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Édition non enregistrée : $e')),
        );
      }
    }
  }

  Future<void> _add() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final hit = widget.hit;

    try {
      final printing = _printing;
      final total = await ref
          .read(collectionRepositoryProvider)
          .add(
            hit.oracleId,
            printId: printing?.printing.printId,
            isFoil: printing?.isFoil ?? false,
          );
      ref.invalidate(collectionProvider);
      if (!mounted) return;
      setState(() => _owned = total);
      // Sans cela les messages s'empilent et l'utilisateur lit un retour périmé :
      // en ajoutant trois cartes d'affilée, la dernière notification affichée
      // concernait encore la première carte.
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            printing == null
                ? '${hit.matchedName} ajoutée — vous en avez $total'
                : '${hit.matchedName} · ${printing.printing.setCode.toUpperCase()}${printing.isFoil ? " foil" : ""} — vous en avez $total',
          ),
          duration: const Duration(seconds: 4),
          // Flutter fait persister indéfiniment toute notification porteuse
          // d'une action : la durée ci-dessus serait ignorée et le bandeau
          // attendrait un balayage, recouvrant entre-temps les commandes de
          // l'écran suivant. L'action est ici une commodité, pas une question
          // posée — elle n'a pas à retenir l'écran.
          persist: false,
          // Sans édition choisie, la notification sert de rampe d'accès vers le
          // sélecteur : c'est l'instant où l'on tient la carte, donc le seul où
          // l'on sait de quelle extension elle vient.
          action: printing == null
              ? SnackBarAction(
                  label: 'Préciser l\'édition',
                  onPressed: () => unawaited(_specifyAfterAdd(1)),
                )
              : SnackBarAction(
                  label: 'Annuler',
                  onPressed: () async {
                    final left = await ref
                        .read(collectionRepositoryProvider)
                        .remove(
                          hit.oracleId,
                          printId: printing.printing.printId,
                          isFoil: printing.isFoil,
                        );
                    ref.invalidate(collectionProvider);
                    if (mounted) setState(() => _owned = left);
                  },
                ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Ajout impossible : $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final printing = _printing;

    // **La ligne décrit l'édition retenue, pas la carte en général.** Tant
    // qu'aucune n'est choisie, l'illustration est celle d'une impression de
    // référence et le prix celui de la moins chère — un plancher assumé. Une
    // fois l'édition désignée, les deux doivent la suivre : c'est l'illustration
    // qui permet de vérifier qu'on a bien désigné celle qu'on tient, et laisser
    // le prix plancher afficherait 1,55 € sur une édition qui en vaut 9.
    //
    // Le repli sur le prix plancher quand l'édition n'est pas cotée n'est pas
    // une approximation de confort : c'est exactement ce que la collection
    // comptera pour elle (`COALESCE(prix de l'édition, prix le moins cher)`).
    final art = printing?.printing.artCropUrl ?? hit.artUrl;
    final price =
        printing?.printing.priceFor(foil: printing.isFoil) ?? hit.priceEur;

    // **Maintenir montre la carte**, comme partout ailleurs. C'est l'écran où
    // l'on décide d'écrire une carte en collection, et la vignette de 56 × 42
    // ne permet pas de lever un doute entre deux noms voisins. L'édition
    // choisie voyage avec l'aperçu : une carte rééditée change parfois
    // d'illustration, et en montrer une autre ferait douter de sa saisie.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => showCardArt(
        context,
        oracleId: hit.oracleId,
        title: hit.matchedName,
        lang: hit.matchedLang,
        printId: printing?.printing.printId,
        foil: printing?.isFoil ?? false,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // L'illustration précède le nom : c'est elle qu'on reconnaît en
            // premier, et le seul repère qui sépare deux cartes homonymes.
            Padding(
              padding: const EdgeInsets.only(right: 12, top: 2),
              child: CardArtThumbnail(url: art),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hit.matchedName,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Le nom oracle n'est rappelé que s'il diffère : inutile de
                  // répéter la même chaîne sous une carte trouvée en anglais.
                  if (hit.isLocalized)
                    Text(
                      hit.name,
                      style: muted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 6),
                  Text(
                    hit.typeLine ?? '',
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_quantity > 0) _OwnedBadge(quantity: _quantity),
                      if (hit.legalPauper) const _FormatChip('Pauper'),
                      if (hit.legalModern) const _FormatChip('Modern'),
                      if (hit.legalCommander) const _FormatChip('Commander'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _PrintingSelector(choice: _printing, onTap: _choosePrinting),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  price == null ? '—' : '${price.toStringAsFixed(2)} €',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                IconButton.filledTonal(
                  onPressed: _busy ? null : _add,
                  tooltip: 'Ajouter à ma collection',
                  icon: _busy
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Le choix d'édition, posé sur la tuile plutôt que caché derrière un menu.
///
/// Affiche « Toutes éditions » tant que rien n'est choisi : c'est la description
/// exacte de ce qui sera enregistré, là où « Choisir une édition » laisserait
/// croire à une étape obligatoire.
class _PrintingSelector extends StatelessWidget {
  const _PrintingSelector({required this.choice, required this.onTap});

  final PrintingChoice? choice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = choice != null;
    final color = chosen
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // **Un glyphe, un sens.** `Icons.style` est d'abord celui de
            // l'onglet Collection — « des cartes » —, visible en permanence
            // sous tous les écrans, et il servait aussi à dire « choisir
            // l'édition ». Les feuillets empilés disent ce dont il s'agit :
            // plusieurs impressions d'une même carte, dont on désigne une.
            // Le contraste vide/plein, lui, est conservé : c'est ce qui
            // distingue « à préciser » de « précisée ».
            Icon(
              chosen ? Icons.layers : Icons.layers_outlined,
              size: 15,
              color: color,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                chosen
                    ? '${choice!.printing.label}'
                          '${choice!.isFoil ? ' · brillante' : ''}'
                    : 'Toutes éditions',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: chosen ? FontWeight.w600 : null,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}

/// « Déjà 3 » — ce qu'on possède, mis en avant plutôt que dans un coin.
///
/// C'est l'information qui évite de saisir deux fois la même carte quand on
/// remplit sa collection en plusieurs séances.
/// Combien d'exemplaires on possède déjà, avant d'en ajouter un.
///
/// **Trois formes, trois sens** — c'est le lexique du comptage dans toute
/// l'application, et il vaut mieux qu'un mot unique employé au hasard :
///
/// | Forme | Sens | Où |
/// |---|---|---|
/// | « Déjà N » | stock **avant** l'ajout, donc un avertissement anti-doublon | recherche, sélecteur d'édition |
/// | « ×N » | compte compact **posé sur une image**, faute de place pour un mot | case de classeur, résultat de recherche d'étagère |
/// | « N exemplaires » | la même chose en toutes lettres, quand la ligne a la place | feuille d'action d'une case |
///
/// « Déjà » n'est donc pas une graphie interchangeable des deux autres : il
/// dit *quand* on regarde le nombre, pas seulement lequel. Le lire ailleurs
/// qu'avant un ajout serait une faute.
class _OwnedBadge extends StatelessWidget {
  const _OwnedBadge({required this.quantity});

  final int quantity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 13,
            color: theme.colorScheme.onPrimary,
          ),
          const SizedBox(width: 4),
          Text(
            'Déjà $quantity',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _FormatChip extends StatelessWidget {
  const _FormatChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Les accents et les fautes de frappe sont tolérés.\n'
          'Essayez « foudr » ou « contresor ».',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Aucune carte ne correspond à « $query ».',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('La recherche a échoué.', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
