/// Sélecteur d'édition : « laquelle de ces trente Foudre tenez-vous ? »
///
/// Présenté en feuille modale plutôt qu'en menu déroulant, pour trois raisons qu'un
/// `DropdownButton` ne couvre pas : la liste peut compter plus de mille entrées, elle
/// doit être cherchable, et chaque ligne porte plusieurs informations — illustration,
/// extension, numéro, prix — qu'une ligne de menu ne peut pas montrer.
///
/// **Deux choix en un.** L'édition, mais aussi la finition : une carte brillante se
/// vend couramment le double ou le triple de sa jumelle normale, et les deux
/// cohabitent dans une collection. L'interrupteur en tête met à jour tous les prix
/// affichés, pour qu'on compare ce qu'on possède réellement.
///
/// **Une seule langue.** La liste montrait chaque édition deux fois, en français et
/// en anglais, alors que la langue est déjà déterminée : on a trouvé la carte par son
/// nom français, donc c'est la version française qu'on tient. Le doublon allongeait
/// la liste sans rien apprendre.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/printing_repository.dart';
import '../domain/card_printing.dart';

/// Ce que le sélecteur rend : une édition et sa finition.
class PrintingChoice {
  const PrintingChoice(this.printing, {this.isFoil = false});

  final CardPrinting printing;
  final bool isFoil;

  /// Vrai pour le choix explicite de ne pas préciser l'édition.
  ///
  /// Se distingue d'un abandon — la feuille renvoie alors `null` : l'un efface
  /// l'édition enregistrée, l'autre laisse tout en l'état.
  bool get isUnspecified => printing.printId.isEmpty;
}

const _unspecified = CardPrinting(printId: '', setCode: '', lang: 'en');

Future<PrintingChoice?> showPrintingPicker(
  BuildContext context, {
  required String oracleId,
  required String cardName,
  String? currentPrintId,
  bool currentIsFoil = false,
  bool allowUnspecified = false,
  String? lang,
}) {
  return showModalBottomSheet<PrintingChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _PrintingPicker(
      oracleId: oracleId,
      cardName: cardName,
      currentPrintId: currentPrintId,
      currentIsFoil: currentIsFoil,
      allowUnspecified: allowUnspecified,
      lang: lang,
    ),
  );
}

class _PrintingPicker extends ConsumerStatefulWidget {
  const _PrintingPicker({
    required this.oracleId,
    required this.cardName,
    required this.currentPrintId,
    required this.currentIsFoil,
    required this.allowUnspecified,
    required this.lang,
  });

  final String oracleId;
  final String cardName;
  final String? currentPrintId;
  final bool currentIsFoil;
  final bool allowUnspecified;
  final String? lang;

  @override
  ConsumerState<_PrintingPicker> createState() => _PrintingPickerState();
}

class _PrintingPickerState extends ConsumerState<_PrintingPicker> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  late bool _foil = widget.currentIsFoil;

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
      printingsProvider((
        oracleId: widget.oracleId,
        query: _query,
        lang: widget.lang,
      )),
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
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
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        onChanged: _onChanged,
                        decoration: InputDecoration(
                          hintText: 'Chercher une extension',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _FoilToggle(
                      value: _foil,
                      onChanged: (v) => setState(() => _foil = v),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Appui long sur une ligne pour voir l\'illustration en grand',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
              onTap: () =>
                  Navigator.of(context).pop(const PrintingChoice(_unspecified)),
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
              data: (list) {
                // Une finition jamais imprimée n'a pas à figurer : proposer
                // « brillant » sur une carte qui n'existe qu'en normal ferait
                // enregistrer un exemplaire impossible.
                final shown = list
                    .where((p) => _foil ? p.hasFoil : p.hasNonfoil)
                    .toList(growable: false);

                if (shown.isEmpty) return _Empty(query: _query, foil: _foil);

                return ListView.builder(
                  controller: scrollController,
                  itemCount: shown.length,
                  itemBuilder: (context, index) => _PrintingTile(
                    printing: shown[index],
                    foil: _foil,
                    selected:
                        shown[index].printId == widget.currentPrintId &&
                        _foil == widget.currentIsFoil,
                    onTap: () => Navigator.of(
                      context,
                    ).pop(PrintingChoice(shown[index], isFoil: _foil)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Interrupteur normal / brillant.
class _FoilToggle extends StatelessWidget {
  const _FoilToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = value
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: value ? theme.colorScheme.primary : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.auto_awesome : Icons.auto_awesome_outlined,
              size: 17,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              'Foil',
              style: theme.textTheme.labelLarge?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.query, required this.foil});

  final String query;
  final bool foil;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          foil
              ? 'Aucune édition brillante connue pour cette carte.'
              : query.isEmpty
              ? 'Aucune édition connue pour cette carte.'
              : 'Aucune extension ne correspond à « $query ».',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

const double _thumbWidth = 92;
const double _thumbHeight = 68;

class _PrintingTile extends StatelessWidget {
  const _PrintingTile({
    required this.printing,
    required this.foil,
    required this.selected,
    required this.onTap,
  });

  final CardPrinting printing;
  final bool foil;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final year = printing.releasedAt?.year;
    final price = printing.priceFor(foil: foil);

    return ListTile(
      selected: selected,
      onTap: onTap,
      // **Toute la ligne réagit à l'appui long**, pas seulement la vignette :
      // viser une image d'un centimètre au pouce est inconfortable, et rien
      // n'indiquait que c'était elle qu'il fallait maintenir.
      onLongPress: printing.artCropUrl == null
          ? null
          : () => _showArt(context, printing),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            price == null ? '—' : '${price.toStringAsFixed(2)} €',
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

  void _showArt(BuildContext context, CardPrinting printing) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              child: Image.network(printing.artCropUrl!, fit: BoxFit.contain),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                printing.label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
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
      width: _thumbWidth,
      height: _thumbHeight,
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
        width: _thumbWidth,
        height: _thumbHeight,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }
}
