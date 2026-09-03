/// Feuille de recherche : « quelle carte est-ce, en fait ? »
///
/// **Le pendant du sélecteur d'édition, un cran au-dessus.** `showPrintingPicker`
/// répond à « laquelle de ces trente Foudre ? » une fois la carte connue ; celle-ci
/// répond quand c'est la **carte** qui est fausse — un nom mal lu sur la photo, ou
/// une carte que la photo n'a pas vue du tout.
///
/// **Pourquoi une recherche libre plutôt que les autres candidats de la
/// reconnaissance.** Les candidats voisins supposent que la bonne réponse était
/// dans la liste, à une place près ; or les erreurs qui coûtent sont celles où la
/// lecture tombe franchement à côté — un nom coupé en deux, une ligne de type
/// prise pour un nom. La recherche couvre les deux cas au même prix, et c'est la
/// même requête tolérante aux fautes que l'écran de saisie au clavier.
///
/// La feuille **ne décide de rien** : elle rend une carte, l'appelant en fait ce
/// qu'il veut. Refermée sans choisir, elle rend `null` — l'appelant laisse alors
/// tout en l'état, garde-fou §IV.8.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../printings/presentation/card_art_view.dart';
import '../data/card_repository.dart';
import '../domain/card_hit.dart';
import 'owned_badge.dart';

/// Amortissement de la frappe, identique à celui de l'écran de saisie : au-delà
/// la liste semble traîner, en deçà on repart en requête entre deux touches.
const _debounce = Duration(milliseconds: 250);

/// Ouvre la feuille et rend la carte choisie, ou `null` si l'on referme.
///
/// [title] dit ce que le choix va faire — « Remplacer par » n'est pas « Ajouter
/// une carte », et la feuille est la même.
/// [initialQuery] pré-remplit le champ : après une lecture ratée, le nom lu est
/// souvent presque juste, et le corriger coûte moins que de tout retaper.
Future<CardHit?> showCardPicker(
  BuildContext context, {
  required String title,
  String? initialQuery,
}) {
  return showModalBottomSheet<CardHit>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _CardPicker(title: title, initialQuery: initialQuery),
  );
}

class _CardPicker extends ConsumerStatefulWidget {
  const _CardPicker({required this.title, required this.initialQuery});

  final String title;
  final String? initialQuery;

  @override
  ConsumerState<_CardPicker> createState() => _CardPickerState();
}

class _CardPickerState extends ConsumerState<_CardPicker> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery ?? '',
  );
  Timer? _timer;
  late String _query = (widget.initialQuery ?? '').trim();

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
    final theme = Theme.of(context);
    // Aucun filtre de type : on cherche une carte précise dont on connaît le
    // nom, pas une famille de cartes à dégrossir.
    final results = ref.watch(cardSearchProvider(cardQuery(_query, const [])));

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
                Text(widget.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  onChanged: _onChanged,
                  // **Le clavier ne s'ouvre que s'il y a quelque chose à
                  // taper**, et c'est l'appareil qui l'a montré : sur une
                  // correction, la feuille arrive avec le nom lu déjà cherché
                  // et ses résultats affichés — le clavier en masquait la
                  // moitié pour rien. Sur un ajout à la main, le champ est
                  // vide, la liste ne dit encore rien, et c'est l'inverse :
                  // ouvrir le clavier épargne un geste.
                  autofocus: (widget.initialQuery ?? '').trim().isEmpty,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Nom de la carte',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
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
          const Divider(height: 1),
          Expanded(
            child: _query.isEmpty
                ? const _Note(
                    icon: Icons.keyboard_alt_outlined,
                    text: 'Tapez le nom lu sur la carte.',
                  )
                : results.when(
                    loading: () => const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    // La panne se dit. Une liste vide voudrait dire « cette
                    // carte n'existe pas », ce qui enverrait chercher une faute
                    // de frappe là où c'est le réseau qui manque.
                    error: (error, _) =>
                        _Note(icon: Icons.cloud_off, text: '$error'),
                    data: (hits) => hits.isEmpty
                        ? const _Note(
                            icon: Icons.search_off,
                            text:
                                'Aucune carte de ce nom dans le catalogue du '
                                'jeu sélectionné.',
                          )
                        : ListView.separated(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                            itemCount: hits.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 4),
                            itemBuilder: (context, index) =>
                                _CandidateTile(hit: hits[index]),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Une carte proposée : de quoi la reconnaître, et ce qu'on en possède déjà.
class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.hit});

  final CardHit hit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      // Le même geste que partout ailleurs : maintenir montre la carte en
      // grand. C'est souvent ce qui tranche entre deux homonymes.
      onLongPress: () => showCardArt(
        context,
        oracleId: hit.oracleId,
        title: hit.matchedName,
        lang: hit.matchedLang,
      ),
      onTap: () => Navigator.of(context).pop(hit),
      title: Text(
        hit.matchedName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        // Le nom oracle quand il diffère : c'est sous cette identité que la
        // carte sera enregistrée, et deux traductions se ressemblent parfois
        // davantage que les cartes qu'elles nomment.
        [
          if (hit.isLocalized) hit.name,
          if (hit.typeLine != null) hit.typeLine!,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: hit.owned > 0 ? OwnedBadge(quantity: hit.owned) : null,
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
    // **Défilable, et c'est un test qui l'a exigé.** La note porte aussi le
    // message d'une panne, qui peut faire plusieurs écrans de haut : sans
    // défilement, elle débordait de vingt-six mille pixels — donc, à
    // l'appareil, une bande rayée à la place de l'explication.
    return Center(
      child: SingleChildScrollView(
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
