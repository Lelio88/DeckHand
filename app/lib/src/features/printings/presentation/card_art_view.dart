/// Aperçu de l'illustration d'une carte, au maintien du doigt.
///
/// **Reconnaître sa carte, c'est la voir.** Une reconnaissance — photo ou
/// dictée — ne rend qu'un nom, et un nom ne suffit pas toujours à décider : deux
/// cartes portent des titres voisins, une lecture approximative en propose une
/// troisième, et rien à l'écran ne permet de trancher avant de valider. Or ces
/// écrans valident **en bloc** : une erreur y passe d'autant plus facilement.
/// L'illustration est ce que l'œil reconnaît immédiatement, avant même de lire.
///
/// Le geste est celui qu'emploie déjà le sélecteur d'édition — maintenir la
/// ligne — pour qu'il n'y ait qu'un seul geste à apprendre dans l'application.
///
/// **L'illustration se charge à la demande, jamais d'avance.** Une liste de
/// vingt cartes dictées déclencherait vingt requêtes vers Scryfall pour des
/// images que l'on ne regardera pas.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/printing_repository.dart';

/// Ouvre l'aperçu de la carte désignée par [oracleId].
///
/// [lang] restreint aux impressions de cette langue lorsqu'elle est connue —
/// l'illustration est la même, mais le choix évite de rapatrier deux fois la
/// liste. [title] est affiché sous l'image : sur une carte reconnue de travers,
/// c'est lui qui explique ce que l'on regarde.
Future<void> showCardArt(
  BuildContext context, {
  required String oracleId,
  required String title,
  String? lang,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _CardArtDialog(oracleId: oracleId, title: title, lang: lang),
  );
}

class _CardArtDialog extends ConsumerWidget {
  const _CardArtDialog({
    required this.oracleId,
    required this.title,
    this.lang,
  });

  final String oracleId;
  final String title;
  final String? lang;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printings = ref.watch(
      printingsProvider((oracleId: oracleId, query: '', lang: lang)),
    );

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          printings.when(
            data: (list) {
              // La première impression qui porte une illustration : les plus
              // anciennes n'en ont pas toujours, et une liste sans image ne
              // doit pas se solder par un cadre vide sans explication.
              final url = list
                  .map((p) => p.artCropUrl)
                  .where((u) => u != null)
                  .firstOrNull;
              if (url == null) {
                return const _Absent("Pas d'illustration connue.");
              }
              return ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(4),
                ),
                child: Image.network(url, fit: BoxFit.contain),
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            error: (_, _) => const _Absent('Illustration indisponible.'),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _Absent extends StatelessWidget {
  const _Absent(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_not_supported_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(message, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Vignette d'illustration, pour distinguer d'un coup d'œil.
///
/// **Elle ne sert pas qu'à décorer.** Quatre-vingts noms Riftbound sont portés
/// par plusieurs cartes distinctes que la ligne de type ne départage jamais ;
/// sans image, la recherche affiche deux résultats rigoureusement identiques et
/// l'utilisateur n'a aucun moyen de choisir. Les illustrations, elles, diffèrent
/// dans tous les cas mesurés.
///
/// Une image absente laisse un cadre neutre plutôt qu'une icône d'erreur : la
/// liste doit rester lisible, et l'absence d'illustration n'est pas une panne.
class CardArtThumbnail extends StatelessWidget {
  const CardArtThumbnail({super.key, required this.url, this.width = 56, this.height = 42});

  final String? url;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      width: width,
      height: height,
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
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }
}
