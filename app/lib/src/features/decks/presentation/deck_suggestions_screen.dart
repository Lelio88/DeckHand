/// Écran des decks : ce que la collection permet de construire.
///
/// Deux familles distinguées visuellement — constructibles immédiatement, et
/// à quelques cartes près avec leur coût. La distinction entre deck accessible
/// et deck de tournoi est affichée : un deck de compétition à plusieurs
/// centaines d'euros ne doit pas se présenter comme « presque à portée ».
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../builder/presentation/deck_builder_view.dart';
import '../../printings/presentation/card_art_view.dart';
import '../data/deck_repository.dart';
import '../domain/deck_suggestion.dart';
import 'color_wheel.dart';

/// Les deux façons de répondre à « que puis-je jouer ? ».
///
/// **Deux vues d'un même onglet, et non une vue et une action.** Consulter le
/// corpus et construire depuis sa collection répondent à la même question par
/// deux chemins ; les mettre sur un même sélecteur le dit, là où un bouton
/// glissé parmi les filtres laissait croire à un filtre de plus.
enum DeckMode {
  /// Les decks du corpus, confrontés à la collection.
  existing('Préconstruits'),

  /// Un deck bâti avec la seule collection.
  building('Construire');

  const DeckMode(this.label);

  final String label;
}

/// Un `Notifier` et non un `StateProvider` : ce dernier a été retiré de
/// Riverpod 3.
class SelectedDeckMode extends Notifier<DeckMode> {
  @override
  DeckMode build() => DeckMode.existing;

  void select(DeckMode mode) => state = mode;
}

final deckModeProvider = NotifierProvider<SelectedDeckMode, DeckMode>(
  SelectedDeckMode.new,
);

class DeckSuggestionsScreen extends ConsumerWidget {
  const DeckSuggestionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(deckModeProvider);
    final format = ref.watch(selectedFormatProvider);

    return Column(
      children: [
        // Le choix entre « préconstruits » et « construire » a remonté dans la
        // barre du haut : c'est le mode de l'onglet, pas un filtre de plus.
        // **Le format, lui, est commun aux deux vues** — on cherche un deck
        // Commander ou on en construit un, mais le format se choisit avant de
        // savoir lequel des deux chemins on prendra.
        const _FormatSelector(),
        if (mode == DeckMode.building)
          Expanded(child: DeckBuilderView(format: format))
        else
          ..._existing(context, ref, format),
      ],
    );
  }

  List<Widget> _existing(
    BuildContext context,
    WidgetRef ref,
    DeckFormat format,
  ) {
    final suggestions = ref.watch(deckSuggestionsProvider);
    return [
      // La recherche par commandant n'a de sens que là où il y en a un :
      // l'afficher en Pauper offrirait un champ qui ne peut rien trouver.
      if (format == DeckFormat.commander) const _CommanderSearch(),
      const _FilterBar(),
      Expanded(
        child: suggestions.when(
          loading: () =>
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text('Suggestions indisponibles : $error'),
            ),
          ),
          data: (decks) => decks.isEmpty
              ? _NoDeck(filtered: ref.watch(deckFiltersProvider).isActive)
              : _DeckList(decks: decks),
        ),
      ),
    ];
  }
}

/// Bascule entre les decks du corpus et la construction.
class _FormatSelector extends ConsumerWidget {
  const _FormatSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedFormatProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<DeckFormat>(
              // **Un nom de format ne se coupe pas.** « Commander » se rompait en
              // « Command / er » sur un écran de téléphone, les segments se
              // partageant la largeur à parts égales quelle que soit la longueur du
              // mot. `softWrap: false` le garde d'un tenant, et l'icône de coche est
              // retirée pour lui rendre la place qu'elle prenait.
              showSelectedIcon: false,
              segments: [
                for (final format in DeckFormat.values)
                  ButtonSegment(
                    value: format,
                    label: Text(format.label, softWrap: false, maxLines: 1),
                  ),
              ],
              selected: {selected},
              onSelectionChanged: (values) => ref
                  .read(selectedFormatProvider.notifier)
                  .select(values.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// Recherche d'un deck par son commandant.
///
/// **C'est ainsi qu'on choisit un deck Commander** : on part du général qu'on
/// veut jouer, pas du nom commercial du produit qui le contient. Le nom cherché
/// passe par le même index que la saisie de collection — donc le français
/// fonctionne, et les fautes de frappe sont tolérées.
class _CommanderSearch extends ConsumerStatefulWidget {
  const _CommanderSearch();

  @override
  ConsumerState<_CommanderSearch> createState() => _CommanderSearchState();
}

class _CommanderSearchState extends ConsumerState<_CommanderSearch> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// La frappe attend une pause : sans cela « galadriel » relancerait neuf fois
  /// une requête qui compare une collection à des centaines de decklists.
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) {
        ref.read(deckFiltersProvider.notifier).searchCommander(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(deckFiltersProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Chercher un commandant',
                prefixIcon: const Icon(
                  Icons.workspace_premium_outlined,
                  size: 20,
                ),
                isDense: true,
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Effacer',
                        onPressed: () {
                          _controller.clear();
                          _onChanged('');
                          setState(() {});
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // **Auprès du champ qui parle du général, pas parmi les filtres.**
          // Les deux commandes portent sur la même chose — l'une le cherche,
          // l'autre le restreint à ce qu'on possède — et les séparer obligeait
          // à parcourir une rangée entière pour trouver la seconde.
          FilterChip(
            label: const Text('Possédé'),
            tooltip: 'Ne montrer que les decks dont vous tenez déjà le général',
            selected: filters.ownedCommanderOnly,
            onSelected: (_) =>
                ref.read(deckFiltersProvider.notifier).toggleOwnedCommander(),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Affinage des suggestions.
///
/// Trois questions distinctes, d'où trois contrôles plutôt qu'un tri unique :
/// « qu'est-ce que je peux jouer ce soir » (constructibles), « qu'est-ce qui est
/// à ma portée » (budget), et « de quelle couleur » — celle-ci venant d'ordinaire
/// en premier chez un joueur, avant même le prix.
///
/// **Un quatrième a été retiré.** Il séparait les decks vendus tout faits des
/// listes de tournoi — une distinction réelle en soi, mais que ce corpus ne
/// porte pas : les 190 decks Commander viennent tous de MTGJSON, les 838 autres
/// tous de TopDeck.gg. Le critère était donc parfaitement corrélé au format,
/// si bien que le filtre ne changeait rien en Commander et vidait la liste en
/// Pauper. Il faudra le rétablir le jour où une source apportera des listes de
/// tournoi Commander, ou des précons dans un autre format.
///
/// **Une seule ligne, qui défile.** Empilées sur deux rangs, les commandes
/// mangeaient la hauteur des suggestions, qui sont l'essentiel de l'écran. Les
/// plus employées viennent en tête, donc sous le pouce sans défiler.
class _FilterBar extends ConsumerWidget {
  const _FilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(deckFiltersProvider);
    final notifier = ref.read(deckFiltersProvider.notifier);

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        children: [
          // En tête et non en fin de rangée : c'est la sortie de secours d'un
          // filtrage trop serré, et la reléguer derrière cinq pastilles la
          // rendait invisible sans défiler — précisément quand la liste est
          // vide et qu'on ne comprend pas pourquoi.
          if (filters.isActive) ...[
            TextButton(
              onPressed: notifier.reset,
              child: const Text('Tout afficher'),
            ),
            const SizedBox(width: 4),
          ],
          // **Un seul contrôle pour « jusqu'où suis-je prêt à aller ».**
          // « Constructibles » et le plafond de budget répondaient à la même
          // question mais se cochaient séparément : on pouvait demander un deck
          // sans rien à acheter *et* un budget de cinquante euros. « Rien à
          // acheter » ouvre donc le menu — sans y figurer comme un montant, car
          // une carte manquante sans cote coûte zéro et manque quand même.
          PopupMenuButton<DeckBudget>(
            initialValue: filters.budget,
            onSelected: notifier.setBudget,
            itemBuilder: (context) => [
              for (final budget in DeckBudget.values)
                PopupMenuItem(value: budget, child: Text(budget.label)),
            ],
            // Un chevron, pas un symbole monétaire : l'euro décrivait ce qu'on
            // choisit, il ne disait pas qu'il y avait quelque chose à choisir.
            child: Chip(
              label: Text(filters.budget.shortLabel),
              avatar: const Icon(Icons.expand_more, size: 18),
              visualDensity: VisualDensity.compact,
              backgroundColor: filters.budget == DeckBudget.any
                  ? null
                  : Theme.of(context).colorScheme.secondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          const SizedBox(width: 8),
          // **Une roue plutôt que cinq pastilles.** Elles posaient une question
          // ambiguë — « des decks rouges » ou « uniquement rouges » ? — et ne
          // permettaient pas de dire « du rouge, mais pas de bleu ». Le
          // pentagone, lui, est la forme que tout joueur lit sans réfléchir.
          ColorWheelButton(
            wanted: filters.colors,
            banned: filters.bannedColors,
            onChanged: notifier.setColors,
          ),
        ],
      ),
    );
  }
}

class _CommanderLine extends StatelessWidget {
  const _CommanderLine({required this.deck});

  final DeckSuggestion deck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => showCardArt(
        context,
        oracleId: deck.commanderOracleId!,
        title: deck.commanderName!,
      ),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
        child: Row(
          children: [
            // **La coche dit ce qui décide de tout.** Sans le général, les
            // quatre-vingt-dix-neuf autres cartes ne forment pas un deck — et
            // c'est souvent la carte la plus chère de la liste. La distinction
            // se lit donc avant le nom, pas après.
            Icon(
              deck.commanderOwned
                  ? Icons.check_circle
                  : Icons.workspace_premium_outlined,
              size: 15,
              color: deck.commanderOwned
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                deck.commanderName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: deck.commanderOwned
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.image_outlined,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _DeckList extends StatelessWidget {
  const _DeckList({required this.decks});

  final List<DeckSuggestion> decks;

  @override
  Widget build(BuildContext context) {
    // L'attribution est une obligation contractuelle envers les sources : elle
    // doit rester visible, pas reléguée dans un écran « à propos ».
    final credits = decks
        .map((d) => d.attribution)
        .whereType<String>()
        .toSet()
        .join(' · ');

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: decks.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == decks.length) return _Credits(text: credits);
        return _DeckTile(deck: decks[index]);
      },
    );
  }
}

class _DeckTile extends StatelessWidget {
  const _DeckTile({required this.deck});

  final DeckSuggestion deck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // La barre de progression interne capturait la sémantique de la tuile, qui
    // était annoncée « barre de progression » au lieu de « bouton » : un lecteur
    // d'écran ne signalait pas qu'on peut l'ouvrir. On décrit donc la tuile
    // explicitement et on masque la sémantique de la barre, purement décorative.
    return Semantics(
      button: true,
      label: deck.isBuildable
          ? '${deck.deckName}, constructible, ${deck.totalCards} cartes'
          : '${deck.deckName}, ${(deck.completion * 100).round()} pour cent, '
                'il manque ${deck.missingCards} cartes pour '
                '${deck.missingCostEur.toStringAsFixed(2)} euros',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _MissingSheet(deck: deck),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: deck.isBuildable
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      deck.deckName,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(deck.completion * 100).round()} %',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: deck.completion,
                    minHeight: 6,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      // Le décompte annonce ce qu'il ignore : une liste de
                      // cent cartes présentée sur soixante-seize ferait
                      // autrement douter du chiffre.
                      '${deck.isBuildable ? 'Constructible dès maintenant — ${deck.totalCards} cartes' : 'Il manque ${deck.missingCards} carte${deck.missingCards > 1 ? 's' : ''} sur ${deck.totalCards}'}'
                      '${deck.basicLands > 0 ? ' · hors ${deck.basicLands} terrains de base' : ''}',
                      style: muted,
                    ),
                  ),
                  if (!deck.isBuildable)
                    Text(
                      '${deck.missingCostEur.toStringAsFixed(2)} €',
                      style: theme.textTheme.titleSmall,
                    ),
                ],
              ),
              // **La provenance ne figure plus sur aucune tuile.** « Tournoi »
              // et « TopDeck.gg » décrivaient d'où venait la liste — ce que le
              // bandeau d'attribution dit déjà en fin d'écran, et ce qui ne
              // renseigne en rien sur ce qu'on va jouer. Elles ne
              // distinguaient rien non plus : mesuré sur les 1 028 decks du
              // corpus, la provenance est parfaitement corrélée au format —
              // 190 Commander de MTGJSON, 838 Pauper et Modern de TopDeck.gg —
              // si bien que les deux mêmes étiquettes se répétaient sur les 838
              // tuiles d'une liste.
              //
              // Le commandant, lui, reste : c'est ce par quoi on choisit un
              // deck, et il ne concerne qu'un format.
              if (deck.hasCommander) ...[
                const SizedBox(height: 8),
                _CommanderLine(deck: deck),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MissingSheet extends ConsumerWidget {
  const _MissingSheet({required this.deck});

  final DeckSuggestion deck;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final missing = ref.watch(missingCardsProvider(deck.deckId));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(deck.deckName, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  deck.isBuildable
                      ? 'Vous avez toutes les cartes.'
                      : 'Liste de courses — ${deck.missingCostEur.toStringAsFixed(2)} €',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: missing.when(
              loading: () => const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              error: (error, _) => Center(child: Text('Erreur : $error')),
              data: (cards) {
                // Le serveur rend d'abord ce qui manque, puis ce qu'on
                // possède : la frontière est la première ligne acquise.
                final firstOwned = cards.indexWhere((c) => c.missing == 0);
                return ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  itemCount: cards.length,
                  itemBuilder: (context, index) {
                    final card = cards[index];
                    // **Ce qu'on a déjà ferme la marche, derrière un titre.**
                    // Sans lui, la liste de courses se prolongeait de cartes qui
                    // n'étaient pas à acheter, et un deck complet ouvrait sur une
                    // liste vide — on ne pouvait jamais vérifier ce qu'on avait.
                    final separator = index == firstOwned && firstOwned > 0
                        ? _OwnedHeader(count: cards.length - firstOwned)
                        : null;
                    // **Maintenir montre la carte**, comme partout ailleurs.
                    // C'est ici qu'on en a le plus besoin : la question posée
                    // devant une liste de cartes manquantes est « qu'est-ce que
                    // ça m'apporterait ? », à laquelle un nom seul ne répond pas.
                    final row = GestureDetector(
                      onLongPress: () => showCardArt(
                        context,
                        oracleId: card.oracleId,
                        title: card.displayName,
                      ),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${card.missing}×',
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(card.displayName),
                                  if (card.owned > 0 && card.missing > 0)
                                    Text(
                                      'vous en avez ${card.owned} sur ${card.needed}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                            // Une carte acquise n'a pas de coût à afficher : le
                            // tiret dirait « prix inconnu », le zéro « sans
                            // valeur ». Ni l'un ni l'autre n'est vrai.
                            if (card.missing > 0)
                              Text(
                                '${(card.lineCostEur ?? 0).toStringAsFixed(2)} €',
                                style: theme.textTheme.bodyMedium,
                              )
                            else
                              Icon(
                                Icons.check,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                          ],
                        ),
                      ),
                    );

                    return separator == null
                        ? row
                        : Column(children: [separator, row]);
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

/// Titre séparant la liste de courses de ce qu'on possède déjà.
class _OwnedHeader extends StatelessWidget {
  const _OwnedHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Row(
        children: [
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'Déjà en collection · $count',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
        ],
      ),
    );
  }
}

class _Credits extends StatelessWidget {
  const _Credits({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _NoDeck extends StatelessWidget {
  const _NoDeck({this.filtered = false});

  /// Distingue « rien à proposer » de « vos filtres masquent tout ». Sans cette
  /// nuance, l'utilisateur croit la base vide alors qu'il a simplement plafonné
  /// son budget.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          filtered
              ? 'Aucun deck ne passe ces filtres.\n'
                    'Élargissez le budget ou les couleurs.'
              : 'Aucun deck dans ce format pour l\'instant.\n'
                    'Ajoutez des cartes à votre collection, ou changez de format.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
