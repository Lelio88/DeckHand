/// Écran de saisie de collection : on tape un nom, les cartes apparaissent, on
/// les ajoute.
///
/// La frappe est amortie avant d'atteindre le réseau : sans cela, « lightning »
/// déclencherait neuf requêtes dont huit sans intérêt. Le délai est court pour
/// que la liste paraisse suivre la frappe.
///
/// **Ajouter vide le champ, pas la liste.** Saisir une pile de cartes, c'est
/// enchaîner les noms, et effacer le précédent à la main coûtait un geste par
/// carte. La liste reste en place jusqu'à ce que le nom suivant la remplace :
/// un second exemplaire, ou une autre édition de la même carte, reste à un
/// appui.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/selected_game.dart';
import '../data/card_repository.dart';
import '../domain/card_hit.dart';
import 'card_result_tile.dart';
import '../domain/card_type.dart';

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
  final _focus = FocusNode();
  Timer? _timer;
  String _query = '';

  /// Types retenus. Vide = tous, ce qui est le cas courant : le filtre sert à
  /// dégager une liste encombrée, pas à décrire ce qu'on cherche.
  final Set<String> _types = {};

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  /// Libère le champ pour le nom suivant, en laissant `_query` — donc la
  /// liste — intact.
  ///
  /// **À l'appui, pas au retour du serveur.** Le nom suivant se tape pendant
  /// que l'ajout voyage ; vidé seulement ensuite, le champ aurait accolé la
  /// nouvelle frappe à l'ancien nom. Si l'ajout échoue, la liste est toujours
  /// là et « + » se rejoue.
  ///
  /// **Seule la saisie qui a produit la liste est effacée.** Un nom déjà
  /// entamé pour la carte suivante, dont la recherche n'est pas encore partie,
  /// n'est pas à nous.
  ///
  /// Le focus est rendu au champ : à la souris, cliquer « + » le lui retire,
  /// et vider le champ ne servirait à rien s'il fallait encore cliquer dedans.
  void _onAdd() {
    if (_controller.text.trim() == _query) {
      setState(_controller.clear);
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(cardSearchProvider(cardQuery(_query, _types)));
    final types = cardTypesFor(ref.watch(selectedGameProvider));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // **Le type filtre avant la recherche, il ne la suit pas.** En rangée
        // de puces, il occupait une ligne entière au-dessus des résultats ;
        // ramené à gauche du champ, il se lit comme ce qu'il est — la portée
        // de ce qu'on va taper.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
          child: Row(
            children: [
              TypeFilter(
                types: types,
                selected: _types,
                onChanged: (kinds) => setState(() {
                  _types
                    ..clear()
                    ..addAll(kinds);
                }),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SearchField(
                  controller: _controller,
                  focusNode: _focus,
                  onChanged: _onChanged,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _query.isEmpty
              ? const _EmptyState()
              : results.when(
                  data: (hits) => hits.isEmpty
                      ? _NoMatch(query: _query)
                      : _ResultList(
                          hits: hits,
                          query: cardQuery(_query, _types),
                          onAdd: _onAdd,
                        ),
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
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Rechercher',
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

/// Rangée de filtres par type, sous la barre de recherche.
///
/// **Défilable plutôt que repliée sur plusieurs lignes.** Huit types tiennent
/// mal sur la largeur d'un téléphone ; les empiler pousserait les résultats hors
/// de l'écran alors qu'ils sont l'essentiel. Les plus fréquents viennent en
/// tête, donc sous le pouce sans défiler.
/// Le type de carte auquel restreindre la recherche.
///
/// **Un menu plutôt qu'une rangée de puces.** Les puces occupaient une ligne
/// entière et débordaient de l'écran ; le menu tient à gauche du champ, où il
/// annonce la portée de ce qu'on tape. Plusieurs types restent cochables — on
/// cherche parfois « créature ou artefact » — mais l'étiquette se contente de
/// les compter au-delà du premier, faute de place.
class TypeFilter extends StatelessWidget {
  const TypeFilter({
    super.key,
    required this.types,
    required this.selected,
    required this.onChanged,
  });

  final List<CardType> types;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  String get _label {
    if (selected.isEmpty) return 'Tous types';
    final first = types
        .where((t) => selected.contains(t.kind))
        .map((t) => t.label)
        .first;
    return selected.length == 1 ? first : '$first +${selected.length - 1}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopupMenuButton<String>(
      tooltip: 'Filtrer par type',
      // La feuille reste ouverte entre deux choix : cocher trois types
      // demanderait sinon de la rouvrir trois fois.
      onSelected: (kind) {
        final next = Set<String>.from(selected);
        if (kind.isEmpty) {
          next.clear();
        } else if (!next.remove(kind)) {
          next.add(kind);
        }
        onChanged(next);
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: '', child: Text('Tous types')),
        const PopupMenuDivider(),
        for (final type in types)
          CheckedPopupMenuItem(
            value: type.kind,
            checked: selected.contains(type.kind),
            child: Text(type.label),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
          color: selected.isEmpty ? null : theme.colorScheme.secondaryContainer,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_label, style: theme.textTheme.bodyMedium),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}

class _ResultList extends ConsumerWidget {
  const _ResultList({
    required this.hits,
    required this.query,
    required this.onAdd,
  });

  final List<CardHit> hits;

  /// La recherche qui a produit [hits], clé des éditions uniques.
  final CardQuery query;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sole = ref.watch(searchSoleEditionsProvider(query)).value ?? const {};

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: hits.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      // **La clé attache l'état de la ligne à sa carte**, pas à son rang : une
      // ligne retient une édition, et réutilisée pour une autre carte, elle
      // ferait enregistrer celle-ci sous l'édition de la précédente. Unique :
      // `search_cards` rend une ligne par carte (`DISTINCT ON (oracle_id)`).
      itemBuilder: (context, index) {
        final hit = hits[index];
        return CardResultTile(
          key: ValueKey(hit.oracleId),
          hit: hit,
          soleEdition: sole[hit.oracleId],
          onAdd: onAdd,
        );
      },
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
