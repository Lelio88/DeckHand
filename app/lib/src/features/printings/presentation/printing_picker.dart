/// Sélecteur d'édition : « laquelle de ces trente Foudre tenez-vous ? »
///
/// Présenté en feuille modale plutôt qu'en menu déroulant, pour trois raisons qu'un
/// `DropdownButton` ne couvre pas : la liste peut compter plus de mille entrées, elle
/// doit être cherchable, et chaque ligne porte plusieurs informations (extension,
/// numéro, langue, prix) qu'une ligne de menu ne peut pas montrer.
///
/// Renvoie l'édition choisie, ou `null` si l'utilisateur a refermé sans choisir.
/// Pour distinguer « refermé » de « je ne veux plus préciser l'édition », le second
/// cas renvoie [unspecifiedPrinting] — une valeur sentinelle, car `null` est déjà pris.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/printing_repository.dart';
import '../domain/card_printing.dart';

/// Choix explicite de ne pas préciser l'édition.
///
/// Se distingue d'un abandon (`null`) : l'un efface l'édition enregistrée, l'autre
/// laisse tout en l'état.
const unspecifiedPrinting = CardPrinting(
  printId: '',
  setCode: '',
  lang: 'en',
);

Future<CardPrinting?> showPrintingPicker(
  BuildContext context, {
  required String oracleId,
  required String cardName,
  String? currentPrintId,
  bool allowUnspecified = false,
}) {
  return showModalBottomSheet<CardPrinting>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _PrintingPicker(
      oracleId: oracleId,
      cardName: cardName,
      currentPrintId: currentPrintId,
      allowUnspecified: allowUnspecified,
    ),
  );
}

class _PrintingPicker extends ConsumerStatefulWidget {
  const _PrintingPicker({
    required this.oracleId,
    required this.cardName,
    required this.currentPrintId,
    required this.allowUnspecified,
  });

  final String oracleId;
  final String cardName;
  final String? currentPrintId;
  final bool allowUnspecified;

  @override
  ConsumerState<_PrintingPicker> createState() => _PrintingPickerState();
}

class _PrintingPickerState extends ConsumerState<_PrintingPicker> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final printings = ref.watch(
      printingsProvider((oracleId: widget.oracleId, query: _query)),
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Édition de', style: theme.textTheme.bodySmall),
                Text(
                  widget.cardName,
                  style: theme.textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  onChanged: _onChanged,
                  autofocus: false,
                  decoration: InputDecoration(
                    hintText: 'Chercher une extension (nom ou code)',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.allowUnspecified)
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Ne pas préciser l\'édition'),
              subtitle: const Text('Valorisée au prix le moins cher connu'),
              selected: widget.currentPrintId == null,
              onTap: () => Navigator.of(context).pop(unspecifiedPrinting),
            ),
          const Divider(height: 1),
          Expanded(
            child: printings.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              error: (error, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Éditions illisibles : $error'),
                ),
              ),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _query.isEmpty
                              ? 'Aucune édition connue pour cette carte.'
                              : 'Aucune extension ne correspond à « $_query ».',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: list.length,
                      itemBuilder: (context, index) => _PrintingTile(
                        printing: list[index],
                        selected: list[index].printId == widget.currentPrintId,
                        onTap: () =>
                            Navigator.of(context).pop(list[index]),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Vignette de l'illustration.
///
/// Chargée depuis Scryfall à la demande, jamais stockée : seules les lignes
/// visibles déclenchent une requête, `ListView.builder` ne construisant que
/// celles-là. Un échec de chargement laisse un cadre neutre plutôt qu'une icône
/// d'erreur — l'absence d'image ne doit pas parasiter la lecture de la liste.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      width: 56,
      height: 42,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    if (url == null) return placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url!,
        width: 56,
        height: 42,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }
}

class _PrintingTile extends StatelessWidget {
  const _PrintingTile({
    required this.printing,
    required this.selected,
    required this.onTap,
  });

  final CardPrinting printing;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final year = printing.releasedAt?.year;

    return ListTile(
      selected: selected,
      onTap: onTap,
      leading: _Thumbnail(url: printing.artCropUrl),
      title: Text(
        printing.setName ?? printing.setCode.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          printing.setCode.toUpperCase(),
          if (printing.collectorNumber != null) '#${printing.collectorNumber}',
          if (year != null) '$year',
          // La langue n'est signalée que pour le français : l'anglais est le cas
          // par défaut, et l'afficher partout ajouterait du bruit.
          if (printing.lang == 'fr') 'FR',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            printing.priceEur == null
                ? '—'
                : '${printing.priceEur!.toStringAsFixed(2)} €',
            style: theme.textTheme.titleSmall,
          ),
          if (printing.owned > 0)
            Text(
              'déjà ${printing.owned}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}
