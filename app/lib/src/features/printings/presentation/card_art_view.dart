/// La carte en grand, au maintien du doigt — un seul aperçu pour l'application.
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
/// taille dans l'URL, sans rien changer au catalogue (voir [fullCardImage]).
///
/// C'est vrai jusque dans le sélecteur d'édition, qui montrait l'illustration
/// recadrée. La question qu'on y pose est « laquelle de ces trente Foudre
/// est-ce que je tiens ? » — et deux impressions partagent souvent la même
/// illustration sans partager leur cadre, leur symbole d'extension ni leur
/// numéro. Le recadrage effaçait précisément ce qui les départage.
///
/// **Un seul geste, un seul objet, une seule sortie.** L'appui long ouvre
/// l'aperçu partout ; taper la carte le referme partout. La croix a été
/// écartée : elle prendrait de la place sur ce qu'on est venu regarder, et la
/// marge seule ne suffisait pas — à douze pixels d'écart, la zone de sortie
/// était de quelques pixels sur une carte qui remplit le cadre.
///
/// **Le cadre épouse la carte, pas l'écran.** Une carte fait 63 × 88 mm : sans
/// ce rapport, le reflet d'une brillante couvrait toute la boîte de dialogue et
/// la carte flottait au milieu d'un rectangle irisé.
///
/// **L'illustration se charge à la demande, jamais d'avance.** Une liste de
/// vingt cartes dictées déclencherait vingt requêtes vers Scryfall pour des
/// images que l'on ne regardera pas.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../common/card_image.dart';

import '../data/printing_repository.dart';
import '../domain/scryfall_image.dart';
import 'foil_decoration.dart';

/// Rapport d'une vraie carte : 63 × 88 mm.
const double _cardAspectRatio = 63 / 88;

const BorderRadius _cardRadius = BorderRadius.all(Radius.circular(14));

/// Ouvre l'aperçu de la carte désignée par [oracleId].
///
/// À employer quand on ne connaît pas l'URL de l'image — c'est le cas de tout
/// écran qui manipule une carte sans manipuler une impression précise : une
/// liste de courses, un candidat de reconnaissance, une ligne de deck.
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
  bool foil = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CardArtDialog(
      oracleId: oracleId,
      title: title,
      lang: lang,
      printId: printId,
      foil: foil,
    ),
  );
}

/// Ouvre l'aperçu d'une carte dont on tient déjà l'image.
///
/// À employer partout où l'URL est connue — une case de classeur, une ligne du
/// sélecteur d'édition. Aucun aller-retour au serveur : l'aperçu s'ouvre sur
/// l'instant, là où [showCardArt] doit d'abord retrouver les impressions.
///
/// [imageUrl] est l'URL de l'illustration telle que la sert le catalogue ; la
/// carte entière en est déduite. Passer directement une URL de carte entière
/// est sans effet — [fullCardImage] rend inchangée une URL qui ne suit pas la
/// convention du recadrage —, ce qui évite à l'appelant de savoir laquelle des
/// deux tailles il tient. Un `null` ouvre quand même l'aperçu, qui annonce
/// l'absence d'image plutôt que de laisser un geste sans effet.
Future<void> showCardImage(
  BuildContext context, {
  required String? imageUrl,
  required String title,
  bool foil = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _Preview(url: fullCardImage(imageUrl), title: title, foil: foil),
  );
}

class _CardArtDialog extends ConsumerWidget {
  const _CardArtDialog({
    required this.oracleId,
    required this.title,
    required this.foil,
    this.lang,
    this.printId,
  });

  final String oracleId;
  final String title;
  final bool foil;
  final String? lang;
  final String? printId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printings = ref.watch(
      printingsProvider((oracleId: oracleId, query: '', lang: lang)),
    );

    return printings.when(
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
            list.map((p) => p.artCropUrl).where((u) => u != null).firstOrNull;

        return _Preview(url: fullCardImage(url), title: title, foil: foil);
      },
      loading: () => const _Shell(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, _) => const _Shell(child: _Absent('Carte indisponible.')),
    );
  }
}

/// La carte, aussi grande que l'écran le permet.
class _Preview extends StatelessWidget {
  const _Preview({required this.url, required this.title, required this.foil});

  final String? url;
  final String title;
  final bool foil;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (url == null) {
      return const _Shell(child: _Absent("Pas d'illustration connue."));
    }

    return _Shell(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: AspectRatio(
              aspectRatio: _cardAspectRatio,
              child: ClipRRect(
                borderRadius: _cardRadius,
                // **Le reflet suit la carte.** Une brillante vue en grand doit
                // l'être aussi : c'est le moment où l'on regarde vraiment
                // l'exemplaire qu'on possède.
                child: FoilSheen(
                  foil: foil,
                  borderRadius: _cardRadius,
                  child: CardImage(
                    url: url,
                    placeholder: const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    errorBuilder: (_) => const _Absent('Carte indisponible.'),
                  ),
                ),
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
      ),
    );
  }
}

/// Le cadre commun : transparent, et refermé par un appui n'importe où.
///
/// L'appui est capté ici plutôt que sur la seule carte pour que le chargement
/// et les messages d'absence se referment du même geste — trois états qui,
/// sinon, n'offriraient d'autre sortie que la marge.
class _Shell extends StatelessWidget {
  const _Shell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: child,
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
    return Center(
      child: Container(
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
      child: CardImage(
        url: url,
        width: width,
        height: height,
        placeholder: placeholder,
      ),
    );
  }
}
