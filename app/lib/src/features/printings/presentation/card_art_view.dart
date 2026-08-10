/// Aperçu d'une carte, au maintien du doigt.
///
/// **Reconnaître sa carte, c'est la voir.** Une reconnaissance — photo ou
/// dictée — ne rend qu'un nom, et un nom ne suffit pas toujours à décider : deux
/// cartes portent des titres voisins, une lecture approximative en propose une
/// troisième, et rien à l'écran ne permet de trancher avant de valider. Or ces
/// écrans valident **en bloc** : une erreur y passe d'autant plus facilement.
///
/// **La carte entière, et non sa seule illustration.** L'illustration suffit à
/// reconnaître une carte qu'on tient déjà ; elle ne dit rien de ce que la carte
/// fait. Or on regarde aussi une carte pour décider — coût de mana, type, texte
/// de règles —, en particulier devant une liste de cartes manquantes où la
/// question est « qu'est-ce que ça m'apporterait ? ». Scryfall sert la carte
/// complète au même chemin que l'illustration : il suffit de substituer la
/// taille dans l'URL, sans rien changer au catalogue.
///
/// **Plein écran, puisque le geste est fugace.** L'aperçu se ferme dès qu'on
/// relâche : il n'a pas à ménager la place de ce qu'il recouvre, et une carte
/// lisible vaut mieux qu'une vignette polie.
///
/// Le geste est celui qu'emploie déjà le sélecteur d'édition — maintenir la
/// ligne — pour qu'il n'y en ait qu'un seul à apprendre dans l'application.
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
///
/// [printId] désigne l'édition possédée quand elle est connue. Une carte
/// rééditée change parfois d'illustration : montrer celle d'une autre édition
/// ferait douter de sa propre saisie.
Future<void> showCardArt(
  BuildContext context, {
  required String oracleId,
  required String title,
  String? lang,
  String? printId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CardArtDialog(
      oracleId: oracleId,
      title: title,
      lang: lang,
      printId: printId,
    ),
  );
}

/// URL de la carte entière, dérivée de celle de son illustration.
///
/// Scryfall sert la même image sous plusieurs tailles au même chemin. La
/// substitution évite un appel à l'API pour retrouver une URL qu'on peut
/// déduire — et le catalogue n'a pas à stocker deux liens par impression.
///
/// Rend l'URL inchangée si le motif attendu est absent : mieux vaut afficher
/// l'illustration seule qu'un cadre vide.
String fullCardUrl(String artCropUrl) =>
    artCropUrl.replaceFirst('/art_crop/', '/normal/');

class _CardArtDialog extends ConsumerWidget {
  const _CardArtDialog({
    required this.oracleId,
    required this.title,
    this.lang,
    this.printId,
  });

  final String oracleId;
  final String title;
  final String? lang;
  final String? printId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printings = ref.watch(
      printingsProvider((oracleId: oracleId, query: '', lang: lang)),
    );

    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: printings.when(
        data: (list) {
          // L'édition possédée d'abord, la première illustrée ensuite : les
          // plus anciennes impressions n'ont pas toujours d'image, et une
          // liste sans illustration ne doit pas se solder par un cadre vide
          // sans explication.
          final url =
              list
                  .where((p) => p.printId == printId)
                  .map((p) => p.artCropUrl)
                  .where((u) => u != null)
                  .firstOrNull ??
              list
                  .map((p) => p.artCropUrl)
                  .where((u) => u != null)
                  .firstOrNull;

          if (url == null) return const _Absent("Pas d'illustration connue.");
          return _FullCard(url: fullCardUrl(url), title: title);
        },
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (_, _) => const _Absent('Illustration indisponible.'),
      ),
    );
  }
}

/// La carte, aussi grande que l'écran le permet.
class _FullCard extends StatelessWidget {
  const _FullCard({required this.url, required this.title});

  final String url;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ClipRRect(
            // Le rayon d'une vraie carte, à l'échelle : un coin carré sur une
            // image de carte se remarque immédiatement.
            borderRadius: BorderRadius.circular(14),
            child: Image.network(
              url,
              fit: BoxFit.contain,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const Padding(
                      padding: EdgeInsets.all(60),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
              errorBuilder: (_, _, _) =>
                  const _Absent('Illustration indisponible.'),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
        ),
      ],
    );
  }
}

class _Absent extends StatelessWidget {
  const _Absent(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
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
  const CardArtThumbnail({
    super.key,
    required this.url,
    this.width = 56,
    this.height = 42,
  });

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
