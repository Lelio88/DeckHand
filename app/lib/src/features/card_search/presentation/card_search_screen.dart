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

import '../../collection/data/collection_repository.dart';
import '../../printings/presentation/card_art_view.dart';
import '../../printings/presentation/printing_picker.dart';
import '../../scan/presentation/scan_screen.dart';
import '../../scan/presentation/spread_scan_screen.dart';
import '../../voice/presentation/voice_input_screen.dart';
import '../data/card_repository.dart';
import '../domain/card_hit.dart';

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

  /// Ouvre un écran de saisie, après avoir effacé la notification du dernier
  /// ajout.
  ///
  /// Les notifications vivent au-dessus du navigateur : sans cela, le retour
  /// d'un ajout fait ici suivrait l'utilisateur et recouvrirait les commandes
  /// de l'écran de prise de vue, dont les boutons sont en bas.
  void _open(Widget screen) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(cardSearchProvider(_query));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _SearchField(
                controller: _controller,
                onChanged: _onChanged,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 4),
              child: IconButton.filledTonal(
                tooltip: 'Dicter des cartes',
                icon: const Icon(Icons.mic_none),
                onPressed: () => _open(const VoiceInputScreen()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 4),
              child: IconButton.filledTonal(
                tooltip: 'Scanner une carte',
                icon: const Icon(Icons.photo_camera_outlined),
                onPressed: () => _open(const ScanScreen()),
              ),
            ),
            // Deux gestes distincts, donc deux boutons : « quelle carte est-ce ? »
            // et « lesquelles sont là ? ». Les fondre dans un seul écran
            // obligerait à choisir un mode avant de savoir ce qu'on photographie.
            Padding(
              padding: const EdgeInsets.only(right: 20, top: 4),
              child: IconButton.filledTonal(
                tooltip: 'Scanner plusieurs cartes',
                icon: const Icon(Icons.grid_view),
                onPressed: () => _open(const SpreadScanScreen()),
              ),
            ),
          ],
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Foudre, Sol Ring, contresort…',
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

  /// Ouvre le sélecteur et retient l'édition choisie.
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
    setState(() => _printing = chosen.isUnspecified ? null : chosen);
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
      ref.invalidate(collectionPageProvider);
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
      ref.invalidate(collectionPageProvider);
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
                    ref.invalidate(collectionPageProvider);
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

    return Container(
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
                  Text(hit.name, style: muted, overflow: TextOverflow.ellipsis),
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
            Icon(chosen ? Icons.style : Icons.style_outlined, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                chosen
                    ? '${choice!.printing.label}${choice!.isFoil ? ' · foil' : ''}'
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
