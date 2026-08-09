/// Scan d'un étalement : plusieurs cartes sur une même photo.
///
/// Distinct du scan d'une carte parce que le geste l'est : on ne cherche pas
/// *quelle* carte on tient, mais *lesquelles* sont là. Le résultat n'est donc
/// pas une proposition à départager mais une liste à valider, où l'on décoche ce
/// qui a été mal lu et où l'on ajuste les quantités.
///
/// **Aucune carte n'entre en collection sans validation** — garde-fou §IV.8. Il
/// pèse davantage ici qu'ailleurs : valider vingt cartes d'un geste rend une
/// erreur d'autant plus facile à laisser passer, et une carte saisie à tort
/// fausse ensuite toutes les suggestions de decks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../card_search/domain/card_hit.dart';
import '../../collection/data/collection_repository.dart';
import '../../printings/presentation/card_art_view.dart';
import '../../printings/presentation/printing_picker.dart';
import '../application/scan_service.dart';
import '../data/photo_source.dart';

/// Une carte repérée sur la photo, telle que l'utilisateur peut l'amender.
class _Spotted {
  _Spotted(SpreadFind find)
    : card = find.card,
      quantity = find.copies;

  final CardHit card;
  bool keep = true;

  /// Quantité proposée, pré-remplie par le nombre d'exemplaires vus sur la
  /// photo. Reste modifiable : la reconnaissance propose, l'utilisateur décide.
  int quantity;

  /// Édition possédée, quand l'utilisateur a pris la peine de la désigner.
  ///
  /// **Facultative, et elle doit le rester.** L'intérêt de l'étalement est de
  /// saisir vingt cartes d'un geste ; imposer un choix d'édition par carte
  /// annulerait ce gain. Sans elle, la carte est valorisée au prix le moins
  /// cher connu — un plancher assumé, jamais une invention.
  ///
  /// Deviner cette édition à partir de l'illustration a été mesuré puis
  /// écarté : la géométrie d'une carte n'est reconstructible qu'à ±13 %, et
  /// au-delà de 5 % une carte sur trois recevrait la mauvaise édition. Un
  /// geste juste vaut mieux qu'un calcul faux.
  PrintingChoice? printing;
}

class SpreadScanScreen extends ConsumerStatefulWidget {
  const SpreadScanScreen({super.key});

  @override
  ConsumerState<SpreadScanScreen> createState() => _SpreadScanScreenState();
}

class _SpreadScanScreenState extends ConsumerState<SpreadScanScreen> {
  final List<_Spotted> _spotted = [];
  bool _busy = false;
  bool _saving = false;
  bool _scanned = false;
  String? _error;

  Future<void> _capture(ImageSource source) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final theme = Theme.of(context);
      final photo = await ref
          .read(photoSourceProvider)
          .capture(
            source: source,
            toolbarColor: theme.colorScheme.surfaceContainerHigh,
            toolbarWidgetColor: theme.colorScheme.onSurface,
            webContext: context,
          );
      if (photo == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final service = await ref.read(scanServiceProvider.future);
      final found = await service.recogniseSpread(photo.path);

      if (!mounted) return;
      setState(() {
        _spotted
          ..clear()
          ..addAll(found.map(_Spotted.new));
        _scanned = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAll() async {
    final kept = _spotted.where((s) => s.keep).toList();
    if (kept.isEmpty) return;

    setState(() => _saving = true);
    final repository = ref.read(collectionRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    var added = 0;
    try {
      for (final item in kept) {
        await repository.add(
          item.card.oracleId,
          quantity: item.quantity,
          printId: item.printing?.printing.printId,
          isFoil: item.printing?.isFoil ?? false,
        );
        added += item.quantity;
      }
      ref.invalidate(collectionProvider);
      ref.invalidate(collectionPageProvider);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '$added carte${added > 1 ? 's' : ''} ajoutée'
            '${added > 1 ? 's' : ''}',
          ),
        ),
      );
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Enregistrement impossible : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keptCount = _spotted
        .where((s) => s.keep)
        .fold<int>(0, (sum, s) => sum + s.quantity);

    return Scaffold(
      appBar: AppBar(title: const Text('Plusieurs cartes')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                _Header(spotted: _spotted.length, scanned: _scanned),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(child: _results(theme)),
                _Actions(
                  busy: _busy,
                  saving: _saving,
                  keptCount: keptCount,
                  onCapture: _capture,
                  onSave: _saveAll,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _results(ThemeData theme) {
    if (_error != null) {
      return _Note(icon: Icons.error_outline, text: _error!);
    }
    if (!_scanned) {
      return const _Note(
        icon: Icons.grid_view,
        text:
            'Étalez vos cartes sans les faire se chevaucher, '
            'puis photographiez l\'ensemble.',
      );
    }
    if (_spotted.isEmpty) {
      return const _Note(
        icon: Icons.search_off,
        text:
            'Aucun nom n\'a pu être lu. Rapprochez-vous, '
            'ou évitez les reflets sur les protège-cartes.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      itemCount: _spotted.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) =>
          _SpottedTile(item: _spotted[index], onChanged: () => setState(() {})),
    );
  }
}

class _SpottedTile extends StatelessWidget {
  const _SpottedTile({required this.item, required this.onChanged});

  final _Spotted item;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = item.card;

    // **Voir avant de valider en bloc.** Un étalement propose des cartes lues
    // de loin, parfois de travers ; l'illustration est ce qui permet de
    // reconnaître la sienne d'un coup d'œil, là où un nom demande à être lu et
    // comparé. Le geste est celui du sélecteur d'édition : maintenir la ligne.
    return GestureDetector(
      onLongPress: () => showCardArt(
        context,
        oracleId: card.oracleId,
        title: card.matchedName,
        lang: card.matchedLang,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: item.keep
              ? theme.colorScheme.surfaceContainerHigh
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Checkbox(
              value: item.keep,
              onChanged: (v) {
                item.keep = v ?? false;
                onChanged();
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.matchedName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: item.keep
                          ? null
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (card.isLocalized)
                    Text(
                      card.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 4),
                  _EditionLine(item: item, onChanged: onChanged),
                ],
              ),
            ),
            // Les exemplaires identiques ne sont pas comptés : la lecture des noms
            // ne distingue pas deux cartes côte à côte d'un nom lu deux fois. La
            // quantité s'ajuste donc à la main.
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Un de moins',
              onPressed: item.quantity > 1
                  ? () {
                      item.quantity--;
                      onChanged();
                    }
                  : null,
            ),
            Text('${item.quantity}', style: theme.textTheme.titleMedium),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Un de plus',
              onPressed: () {
                item.quantity++;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.busy,
    required this.saving,
    required this.keptCount,
    required this.onCapture,
    required this.onSave,
  });

  final bool busy;
  final bool saving;
  final int keptCount;
  final void Function(ImageSource) onCapture;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || saving
                      ? null
                      : () => onCapture(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Photographier'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy || saving
                      ? null
                      : () => onCapture(ImageSource.gallery),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Importer'),
                ),
              ),
            ],
          ),
          if (keptCount > 0) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: saving ? null : onSave,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: saving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.playlist_add_check),
                label: Text('Ajouter ($keptCount)'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Consigne de cadrage avant le scan, décompte des cartes trouvées après.
///
/// **Le nombre est ce que l'utilisateur peut vérifier sans rien relire.** Il
/// sait combien de cartes il a posées sur la table ; comparer deux nombres lui
/// dit immédiatement s'il ne lui reste qu'à contrôler des noms, ou s'il doit en
/// plus partir à la recherche d'une carte manquante. Sans lui, une carte ratée
/// ne se remarque qu'en recomptant la liste — donc jamais.
///
/// **Il compte les cartes trouvées, pas les cartes cochées.** Le bouton
/// d'ajout, lui, décompte la sélection. Les deux nombres répondent à deux
/// questions distinctes — « la photo a-t-elle tout vu ? » et « qu'est-ce que je
/// m'apprête à enregistrer ? » — et les confondre rendrait le premier
/// inutilisable dès la première case décochée.
///
/// Un doublon parfait n'est vu qu'une fois : deux exemplaires côte à côte
/// comptent pour une carte, quantité 1. C'est aussi ce que ce compteur rend
/// visible — l'écart avec ce que l'utilisateur a posé lui signale d'ajuster la
/// quantité.
class _Header extends StatelessWidget {
  const _Header({required this.spotted, required this.scanned});

  final int spotted;
  final bool scanned;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!scanned || spotted == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Text(
          'Photographiez vos cartes étalées, noms bien visibles. '
          'Ce sont eux qui sont lus, pas les illustrations.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Icon(
            Icons.style_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$spotted carte${spotted > 1 ? 's' : ''} '
              'trouvée${spotted > 1 ? 's' : ''} sur la photo',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ligne d'édition d'une carte repérée : ce qu'on possède, ou rien.
///
/// **Discrète à dessein.** Sur une liste de vingt cartes, un bouton par ligne
/// encombrerait ; c'est un texte qui se touche, effacé tant qu'aucune édition
/// n'est choisie, affirmé une fois qu'elle l'est.
class _EditionLine extends StatelessWidget {
  const _EditionLine({required this.item, required this.onChanged});

  final _Spotted item;
  final VoidCallback onChanged;

  Future<void> _choose(BuildContext context) async {
    final chosen = await showPrintingPicker(
      context,
      oracleId: item.card.oracleId,
      cardName: item.card.matchedName,
      currentPrintId: item.printing?.printing.printId,
      currentIsFoil: item.printing?.isFoil ?? false,
      // La langue du nom trouvé restreint la liste : on a reconnu la carte par
      // son nom français, c'est donc l'impression française qu'on tient.
      lang: item.card.matchedLang,
      allowUnspecified: true,
    );
    if (chosen == null) return;
    item.printing = chosen.isUnspecified ? null : chosen;
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final printing = item.printing;

    return InkWell(
      onTap: () => _choose(context),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              printing == null ? Icons.style_outlined : Icons.style,
              size: 14,
              color: printing == null
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                printing == null
                    ? "Préciser l'édition"
                    : '${printing.printing.setCode.toUpperCase()}'
                          '${printing.isFoil ? " · brillante" : ""}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: printing == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
