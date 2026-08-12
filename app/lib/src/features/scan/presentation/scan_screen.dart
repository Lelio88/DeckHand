/// Écran de scan : photographier une carte pour l'ajouter à sa collection.
///
/// **Rien n'est ajouté sans confirmation.** La reconnaissance propose, elle ne
/// décide pas — garde-fou §IV.8 du CLAUDE.md. Une carte enregistrée à tort
/// fausserait ensuite toutes les suggestions de decks, ce qui est bien pire
/// qu'une reconnaissance ratée.
///
/// Quand la confiance est faible, les candidats restent affichés mais le ton
/// change : on suggère au lieu d'affirmer, et l'utilisateur tranche.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../config/selected_game.dart';
import '../../../diagnostics/diagnostics.dart';
import '../../card_search/data/card_repository.dart';
import '../../card_search/domain/card_hit.dart';
import '../../collection/data/collection_repository.dart';
import '../../printings/presentation/card_art_view.dart';
import '../../printings/presentation/printing_picker.dart';
import '../application/scan_service.dart';
import '../data/art_index_repository.dart';
import '../data/photo_source.dart';
import '../domain/card_name_text.dart';
import '../domain/set_code_text.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  ScanOutcome? _outcome;
  List<CardHit> _details = const [];
  bool _busy = false;

  /// Dernière source employée, pour proposer de recommencer en recadrant.
  ImageSource? _lastSource;
  String? _error;

  /// Prend une photo et tente de reconnaître la carte.
  ///
  /// [crop] déclenche l'étape de recadrage. Elle n'est plus imposée : le nom se
  /// lit sur une photo large, et exiger un cadrage par carte coûtait des
  /// centaines de gestes sur une collection. On la propose en seconde chance
  /// quand la lecture échoue, car l'empreinte d'illustration, elle, exige un
  /// cadrage précis.
  Future<void> _capture(ImageSource source, {bool crop = false}) async {
    setState(() {
      _busy = true;
      _error = null;
      _outcome = null;
      _details = const [];
    });

    _lastSource = source;
    try {
      final theme = Theme.of(context);
      final photo = await ref
          .read(photoSourceProvider)
          .capture(
            source: source,
            toolbarColor: theme.colorScheme.surfaceContainerHigh,
            toolbarWidgetColor: theme.colorScheme.onSurface,
            webContext: context,
            crop: crop,
            game: ref.read(selectedGameProvider).id,
          );
      // Abandon à la prise de vue ou au recadrage : rien à signaler.
      if (photo == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final service = await ref.read(scanServiceProvider.future);
      final outcome = await service.recognise(
        photo.bytes,
        photoPath: photo.path,
      );

      final details = outcome.oracleIds.isEmpty
          ? <CardHit>[]
          : await ref
                .read(cardRepositoryProvider)
                .byOracleIds(outcome.oracleIds);

      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _details = details;
        _error = outcome.error;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ouvre le sélecteur avant d'ajouter.
  ///
  /// Le scan ajoutait directement, sans jamais offrir de préciser l'édition ni
  /// la finition — il fallait ensuite retrouver la carte dans la collection pour
  /// le faire. Or c'est ici qu'on la tient en main, donc le seul moment où l'on
  /// sait de quelle extension elle vient et si elle brille.
  Future<void> _addWithPrinting(CardHit card) async {
    // Le texte lu sur la photo porte la ligne d'extension. Elle ne sert que si
    // la carte a plusieurs éditions — d'où la fonction, appelée par le
    // sélecteur une fois qu'il sait lesquelles.
    final lines = _outcome?.readLines ?? const <ReadLine>[];
    final chosen = await showPrintingPicker(
      context,
      oracleId: card.oracleId,
      cardName: card.matchedName,
      lang: card.matchedLang,
      readSetCode: lines.isEmpty
          ? null
          : (codes) {
              final read = readSetCode(lines, codes);
              _diagnoseSetCode(lines, codes, read);
              return read;
            },
    );
    if (chosen == null || !mounted) return;
    await _add(
      card,
      printId: chosen.isUnspecified ? null : chosen.printing.printId,
      isFoil: chosen.isFoil,
    );
  }

  /// Consigne ce que la lecture du code d'extension a vu, et ce qu'elle en a
  /// fait.
  ///
  /// **Un bandeau absent ne dit pas pourquoi il est absent**, et les causes
  /// appellent des correctifs opposés : le code peut n'avoir pas été lu du tout
  /// (cadrage, netteté), avoir été lu de travers (`M5H` — il faudrait tolérer
  /// une faute), avoir été collé à un mot voisin (il faudrait revoir le
  /// découpage), ou avoir été lu juste sans figurer parmi les extensions de la
  /// carte (le catalogue écrit le code autrement que la carte). Sans le texte
  /// brut en face des candidats, on choisirait le correctif à l'aveugle.
  ///
  /// Les lignes sont émises une par une : le tampon de `logcat` tronque les
  /// entrées longues, et une carte peut en produire une quarantaine.
  void _diagnoseSetCode(
    List<ReadLine> lines,
    Set<String> candidates,
    String? read,
  ) {
    if (!diagnosticsEnabled) return;
    diagnose('set_code', {
      'read': read,
      'candidates': candidates.length,
      'codes': (candidates.toList()..sort()).take(20).toList(),
      'lines': lines.length,
    });
    for (final line in lines) {
      diagnose('set_code_line', {
        'text': line.text,
        'top': line.top,
        'height': line.height,
      });
    }
  }

  Future<void> _add(
    CardHit card, {
    String? printId,
    bool isFoil = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final total = await ref
          .read(collectionRepositoryProvider)
          .add(card.oracleId, printId: printId, isFoil: isFoil);
      ref.invalidate(collectionProvider);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('${card.matchedName} ajoutée — vous en avez $total'),
          duration: const Duration(seconds: 2),
        ),
      );
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Ajout impossible : $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(artHashIndexProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Scanner une carte')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: index.when(
              loading: () => const _LoadingIndex(),
              error: (e, _) => _Message(
                icon: Icons.cloud_off,
                title: 'Index indisponible',
                detail: '$e',
              ),
              data: (loaded) => _Body(
                indexSize: loaded.length,
                busy: _busy,
                error: _error,
                outcome: _outcome,
                details: _details,
                onCapture: _capture,
                // Seconde chance : la même source, en passant cette fois par le
                // recadrage, pour que l'empreinte d'illustration puisse répondre.
                onCropRetry: () =>
                    _capture(_lastSource ?? ImageSource.camera, crop: true),
                onAdd: _add,
                onChoosePrinting: _addWithPrinting,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.indexSize,
    required this.busy,
    required this.error,
    required this.outcome,
    required this.details,
    required this.onCapture,
    required this.onCropRetry,
    required this.onAdd,
    required this.onChoosePrinting,
  });

  final int indexSize;
  final bool busy;
  final String? error;
  final ScanOutcome? outcome;
  final List<CardHit> details;
  final void Function(ImageSource) onCapture;
  final VoidCallback onCropRetry;
  final void Function(CardHit) onAdd;
  final void Function(CardHit) onChoosePrinting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cadrez la carte pour qu\'elle remplisse la hauteur de l\'image.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '$indexSize illustrations connues',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => onCapture(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera),
                      label: const Text('Photographier'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => onCapture(ImageSource.gallery),
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Importer'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _Result(
            error: error,
            outcome: outcome,
            details: details,
            onAdd: onAdd,
            onChoosePrinting: onChoosePrinting,
            onCropRetry: onCropRetry,
          ),
        ),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.error,
    required this.outcome,
    required this.details,
    required this.onAdd,
    required this.onChoosePrinting,
    required this.onCropRetry,
  });

  final String? error;
  final ScanOutcome? outcome;
  final List<CardHit> details;
  final void Function(CardHit) onAdd;
  final void Function(CardHit) onChoosePrinting;

  /// Reprend la photo en passant par le recadrage.
  ///
  /// C'est le filet de la reconnaissance sans cadrage : quand le nom n'a pas pu
  /// être lu, l'empreinte d'illustration peut encore répondre — mais elle exige
  /// un cadrage précis, que seul l'utilisateur peut fournir.
  final VoidCallback onCropRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (error != null) {
      return _Message(
        icon: Icons.error_outline,
        title: 'Reconnaissance impossible',
        detail: error!,
      );
    }
    if (outcome == null) {
      return const _Message(
        icon: Icons.crop_free,
        title: 'Aucune carte scannée',
        detail: 'Photographiez une carte ou importez une image pour commencer.',
      );
    }
    if (details.isEmpty) {
      // **Un nom lu et non retrouvé n'est pas un nom illisible.** Annoncer le
      // second quand c'est le premier fait recadrer une photo irréprochable —
      // mesuré sur une carte Riftbound française, dont le nom se lit sans une
      // faute et ne figure dans aucun catalogue.
      // Une panne de réseau ne se répare pas en recadrant : le dire évite un
      // geste inutile et une conclusion fausse sur la carte.
      if (outcome!.catalogueUnreachable) {
        return const _Message(
          icon: Icons.cloud_off,
          title: 'Catalogue injoignable',
          detail:
              "Le nom a été lu, mais la carte n'a pas pu être confrontée au "
              "catalogue. Vérifiez la connexion, puis réessayez.",
        );
      }
      final read = outcome!.readName;
      return _Message(
        icon: Icons.search_off,
        title: 'Carte non reconnue',
        detail: read == null
            ? "Le nom n'a pas pu être lu. En cadrant la carte, "
                  "son illustration peut encore la trahir."
            : "« $read » a bien été lu, mais aucune carte de ce nom ne figure "
                  "au catalogue. En cadrant la carte, son illustration peut "
                  "encore la trahir.",
        actionLabel: 'Cadrer et réessayer',
        onAction: onCropRetry,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        // La nuance porte tout le sens : « c'est cette carte » ou « est-ce
        // l'une de celles-ci ? ». Affirmer à tort coûte plus cher que suggérer.
        Text(
          outcome!.isConfident
              ? 'Carte reconnue'
              : 'Reconnaissance incertaine — vérifiez avant d\'ajouter',
          style: theme.textTheme.titleSmall?.copyWith(
            color: outcome!.isConfident
                ? theme.colorScheme.primary
                : theme.colorScheme.tertiary,
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < details.length; i++) ...[
          _Candidate(
            card: details[i],
            // La provenance parle plus qu'un écart d'empreinte : « nom lu »
            // dit à l'utilisateur pourquoi cette carte est proposée, et lui
            // permet de juger s'il peut faire confiance.
            origin: i == 0 ? outcome!.method : null,
            highlighted: i == 0 && outcome!.isConfident,
            onAdd: () => onAdd(details[i]),
            onChoosePrinting: () => onChoosePrinting(details[i]),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

String _originLabel(ScanMethod method) => switch (method) {
  ScanMethod.nameAndArt => 'nom et illustration',
  ScanMethod.name => 'nom lu',
  ScanMethod.art => 'illustration',
};

class _Candidate extends StatelessWidget {
  const _Candidate({
    required this.card,
    required this.origin,
    required this.highlighted,
    required this.onAdd,
    required this.onChoosePrinting,
  });

  final CardHit card;
  final ScanMethod? origin;
  final bool highlighted;
  final VoidCallback onAdd;
  final VoidCallback onChoosePrinting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // **Maintenir montre la carte**, comme sur les trois autres voies de
    // saisie. C'est ici qu'on en a le plus besoin : la visée ajoute d'un seul
    // appui et referme aussitôt, sans liste à cocher pour rattraper une
    // reconnaissance de travers.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => showCardArt(
        context,
        oracleId: card.oracleId,
        title: card.matchedName,
        lang: card.matchedLang,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        decoration: BoxDecoration(
          color: highlighted
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(card.matchedName, style: theme.textTheme.titleMedium),
                  if (card.isLocalized) Text(card.name, style: muted),
                  const SizedBox(height: 4),
                  Text(
                    [
                      card.typeLine ?? '',
                      if (origin != null) _originLabel(origin!),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(
              card.priceEur == null
                  ? '—'
                  : '${card.priceEur!.toStringAsFixed(2)} €',
              style: theme.textTheme.titleSmall,
            ),
            // Deux gestes : ajouter vite, ou préciser d'abord. Imposer le
            // sélecteur à chaque carte ralentirait la saisie ; ne jamais le
            // proposer obligerait à repasser par la collection.
            IconButton(
              onPressed: onChoosePrinting,
              tooltip: "Choisir l'édition",
              // Le seul bouton sans libellé de la famille « édition » : c'est
              // ici que l'emprunt au glyphe de l'onglet Collection coûtait le
              // plus cher. Voir card_search_screen.dart.
              icon: const Icon(Icons.layers_outlined),
            ),
            IconButton.filledTonal(
              onPressed: onAdd,
              tooltip: 'Ajouter à ma collection',
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
    );
  }
}

/// Attente du premier chargement de l'index.
///
/// **L'avancement est affiché parce que l'attente est longue.** L'index demande
/// une cinquantaine d'allers-retours ; un indicateur qui tourne sans chiffre ne
/// permet pas de distinguer « ça avance » de « c'est bloqué », et c'est
/// précisément la confusion qu'il a produite en usage réel. La barre montre la
/// fraction reçue dès la première page ; tant qu'aucune n'est arrivée, elle
/// reste indéterminée plutôt que d'afficher un zéro qui ne veut rien dire.
class _LoadingIndex extends ConsumerWidget {
  const _LoadingIndex();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final progress = ref.watch(artIndexProgressProvider);
    final fraction = progress == null || progress.total <= 0
        ? null
        : progress.received / progress.total;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 180,
              child: LinearProgressIndicator(value: fraction),
            ),
            const SizedBox(height: 20),
            Text(
              'Chargement de l\'index de reconnaissance',
              style: theme.textTheme.titleSmall,
            ),
            if (progress != null) ...[
              const SizedBox(height: 6),
              Text(
                '${progress.received} / ${progress.total} illustrations',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              'Une seule fois — ensuite la reconnaissance fonctionne hors ligne.',
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

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

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
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: onAction,
                icon: const Icon(Icons.crop),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
