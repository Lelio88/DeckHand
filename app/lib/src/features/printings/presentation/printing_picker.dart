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
/// **Une ligne par édition, pas par langue.** La liste montrait chaque édition deux
/// fois, en français et en anglais, sans rien apprendre. Filtrer sur la langue du nom
/// trouvé supprimait bien le doublon, mais cachait aussi les éditions que Scryfall n'a
/// pas encore cataloguées dans cette langue — un joueur tenant « Ne bougez pas ! »
/// (MAR #43, français) ne se voyait proposer qu'une autre extension, six fois plus
/// chère. La langue est donc devenue une **préférence** : l'édition est servie dans
/// celle qu'on cherche quand elle existe, en anglais sinon, mais aucune ne disparaît.
/// Ce qu'identifie une ligne est le couple extension + numéro, c'est-à-dire l'objet
/// physique — la langue du texte imprimé ne le change pas, et n'en change pas le prix.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../common/card_image.dart';

import '../data/printing_repository.dart';
import '../domain/card_printing.dart';
import 'card_art_view.dart';

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

/// Désigne, parmi les extensions où la carte existe, celle qui a été lue.
///
/// **Pourquoi une fonction plutôt qu'un code tout fait.** Seul le sélecteur sait
/// dans quelles extensions la carte existe — il vient de les charger — et seul
/// l'appelant sait ce qui a été lu sur la photo. Aucun des deux ne peut trancher
/// seul, et se passer une fonction évite au sélecteur de connaître le scan, ou
/// au scan de recharger les éditions pour rien.
typedef SetCodeReader = String? Function(Set<String> setCodes);

Future<PrintingChoice?> showPrintingPicker(
  BuildContext context, {
  required String oracleId,
  required String cardName,
  String? currentPrintId,
  bool currentIsFoil = false,
  bool allowUnspecified = false,
  String? lang,
  SetCodeReader? readSetCode,
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
      readSetCode: readSetCode,
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
    required this.readSetCode,
  });

  final String oracleId;
  final String cardName;
  final String? currentPrintId;
  final bool currentIsFoil;
  final bool allowUnspecified;
  final String? lang;
  final SetCodeReader? readSetCode;

  @override
  ConsumerState<_PrintingPicker> createState() => _PrintingPickerState();
}

class _PrintingPickerState extends ConsumerState<_PrintingPicker> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  late bool _foil = widget.currentIsFoil;

  /// Vrai dès que le code lu a désigné l'édition à notre place.
  ///
  /// Le choix se referme sur la feuille, donc au cours d'une construction :
  /// sans ce drapeau, une reconstruction survenue entre-temps le rejouerait.
  bool _autoChose = false;

  /// Referme la feuille sur l'édition que le code lu désigne seul.
  ///
  /// **Un seul candidat n'est pas un choix**, et le demander revenait à faire
  /// ouvrir une liste d'un seul élément — le même raisonnement qui précise
  /// d'office les cartes à édition unique lors d'un étalement. La différence
  /// tient à ce qui restreint : là le catalogue, ici le code d'extension lu sur
  /// la carte. Éprouvé sur onze cartes réelles, dix codes lus, aucun faux.
  ///
  /// Le geste reste réversible : l'édition d'une case se corrige depuis le
  /// classeur, et c'est là qu'on verra si la lecture s'est trompée.
  void _acceptSoleReading(CardPrinting only) {
    _autoChose = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(PrintingChoice(only, isFoil: _foil));
    });
  }

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
                  'Appui long sur une ligne pour voir la carte en grand',
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
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
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
                final matching = list
                    .where((p) => _foil ? p.hasFoil : p.hasNonfoil)
                    .toList(growable: false);

                if (matching.isEmpty) return _Empty(query: _query, foil: _foil);

                // L'extension lue sur la photo remonte en tête. C'est tout ce
                // qu'on en fait : elle n'est ni cochée ni ajoutée d'office,
                // parce qu'une édition fausse range la carte dans la mauvaise
                // case (garde-fou §IV.8 — l'utilisateur confirme en tapant).
                // Sur une carte rééditée quarante fois, ce simple ordre est ce
                // qui rend le geste tenable.
                final read = widget.readSetCode?.call({
                  for (final p in matching) p.setCode,
                });
                final shown = read == null
                    ? matching
                    : [
                        ...matching.where((p) => p.setCode == read),
                        ...matching.where((p) => p.setCode != read),
                      ];
                final readCount = read == null
                    ? 0
                    : matching.where((p) => p.setCode == read).length;

                // **Le code lu tranche quand il ne laisse qu'une case.** Sur
                // une carte rééditée treize fois, c'est la différence entre une
                // édition précisée et une carte qui atterrit « à trier ». On ne
                // le fait qu'à l'ajout : rouvrir le sélecteur pour corriger une
                // édition doit laisser choisir, sinon la correction serait
                // impossible.
                if (!_autoChose &&
                    readCount == 1 &&
                    widget.currentPrintId == null &&
                    _query.isEmpty) {
                  _acceptSoleReading(shown.first);
                }

                return ListView.builder(
                  controller: scrollController,
                  itemCount: shown.length + (read == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (read != null) {
                      if (index == 0) return _ReadOnCard(setCode: read);
                      index -= 1;
                    }
                    return _PrintingTile(
                      printing: shown[index],
                      foil: _foil,
                      readOnCard: index < readCount,
                      selected:
                          shown[index].printId == widget.currentPrintId &&
                          _foil == widget.currentIsFoil,
                      onTap: () => Navigator.of(
                        context,
                      ).pop(PrintingChoice(shown[index], isFoil: _foil)),
                    );
                  },
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
            // Le français, comme le classeur et comme l'étalement : « Foil »
            // ici et « Brillantes » là ne disaient pas qu'il s'agissait de la
            // même finition — celle qui double le prix.
            Text(
              'Brillante',
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

/// En-tête annonçant l'extension lue sur la photo.
///
/// Dire **ce qui a été lu** plutôt que réordonner en silence : si la lecture se
/// trompe, l'utilisateur comprend pourquoi les mauvaises éditions sont en tête
/// au lieu de subir un ordre inexplicable. C'est la même règle que le nom lu,
/// affiché tel quel après un scan.
class _ReadOnCard extends StatelessWidget {
  const _ReadOnCard({required this.setCode});

  final String setCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Icon(
            Icons.center_focus_weak,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Extension lue sur la carte : ${setCode.toUpperCase()}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrintingTile extends StatelessWidget {
  const _PrintingTile({
    required this.printing,
    required this.foil,
    required this.selected,
    required this.onTap,
    this.readOnCard = false,
  });

  final CardPrinting printing;
  final bool foil;
  final bool selected;
  final VoidCallback onTap;

  /// Vrai quand cette édition porte le code lu sur la photo.
  final bool readOnCard;

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
      title: Row(
        children: [
          Flexible(
            child: Text(
              printing.setName ?? printing.setCode.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Le code peut désigner plusieurs éditions d'une même extension —
          // 17 % des cas mesurés. Le marquer sur chacune évite de laisser
          // croire que la première est la bonne.
          if (readOnCard) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.center_focus_weak,
              size: 14,
              color: theme.colorScheme.primary,
            ),
          ],
        ],
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
              // « Déjà N », comme la pastille de la recherche : c'est le même
              // avertissement — vous en possédez déjà, êtes-vous sûr d'ajouter ?
              'Déjà ${printing.owned}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }

  /// **La carte entière, et non son illustration recadrée.** La question posée
  /// ici est « laquelle de ces trente Foudre est-ce que je tiens ? », et deux
  /// impressions partagent souvent la même illustration sans partager leur
  /// cadre, leur symbole d'extension ni leur numéro imprimé. Le recadrage
  /// effaçait exactement ce qui les départage — et rendait un objet différent
  /// des autres écrans pour un geste identique.
  ///
  /// La finition choisie voyage avec l'aperçu : c'est le seul moment où l'on
  /// voit l'exemplaire qu'on est en train de désigner.
  void _showArt(BuildContext context, CardPrinting printing) {
    showCardImage(
      context,
      imageUrl: printing.artCropUrl,
      title: printing.label,
      foil: foil,
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
      child: CardImage(
        url: url,
        width: _thumbWidth,
        height: _thumbHeight,
        placeholder: placeholder,
      ),
    );
  }
}
