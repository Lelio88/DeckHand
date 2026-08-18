/// Vue de construction : un deck bâti avec ce qu'on possède.
///
/// **Une vue de l'onglet Decks, et non un écran poussé.** Le premier essai en
/// faisait une action, ouverte par un bouton glissé parmi les filtres : rien
/// n'annonçait qu'elle menait ailleurs, et elle se lisait comme un filtre de
/// plus. Or consulter le corpus et construire depuis sa collection sont deux
/// façons de répondre à la même question — « que puis-je jouer ? » —, ce qu'un
/// sélecteur en tête d'onglet dit mieux qu'un bouton.
///
/// **Le deck est jetable, et c'est un choix.** Rien n'est enregistré : on
/// construit, on lit, on recopie, on ferme. Conserver les decks demanderait une
/// table, un écran pour les relire, et de décider ce qu'il advient d'un deck
/// quand la collection change — un produit à lui seul. Mieux vaut savoir si le
/// résultat mérite d'être gardé avant de bâtir de quoi le garder.
///
/// **Le diagnostic est affiché à côté du deck, pas caché.** Un deck bâti sur une
/// collection incomplète s'écarte des proportions des decks réels ; le taire
/// ferait passer un outil pour un oracle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../decks/domain/deck_suggestion.dart';
import '../../printings/presentation/card_art_view.dart';
import '../data/buildable_repository.dart';
import '../domain/buildable_card.dart';
import '../domain/card_role.dart';
import '../domain/deck_blueprint.dart';
import '../domain/deck_builder.dart';
import '../domain/deck_series.dart';

/// Libellés français des rôles. Le domaine les nomme en anglais, comme le texte
/// oracle qu'il inspecte ; l'écran, lui, parle à l'utilisateur.
/// Le nom français de chaque rôle, tel que l'écran le montre.
///
/// **Un rôle absent d'ici s'affiche en anglais**, `entry.key.name` servant de
/// repli — et c'est ce qui se passait pour les treize rôles ajoutés depuis
/// Yu-Gi-Oh : un joueur Pokémon lisait « trainer », un joueur Lorcana lisait
/// « song ». Le repli existe pour qu'un rôle neuf n'affiche pas du vide, pas
/// pour tenir lieu de traduction.
const _roleLabels = {
  // Magic
  CardRole.creature: 'créatures',
  CardRole.draw: 'pioche',
  CardRole.ramp: 'accélération',
  CardRole.removal: 'retrait',
  CardRole.land: 'terrains',
  // Yu-Gi-Oh
  CardRole.monster: 'monstres',
  CardRole.spell: 'magies',
  CardRole.trap: 'pièges',
  CardRole.quickSpell: 'magies rapides',
  CardRole.continuousTrap: 'pièges continus',
  // Pokémon
  CardRole.pokemon: 'pokémon',
  CardRole.trainer: 'dresseurs',
  CardRole.energy: 'énergies',
  CardRole.supporter: 'supporters',
  CardRole.stadium: 'stades',
  // Star Wars Unlimited
  CardRole.unit: 'unités',
  CardRole.upgrade: 'améliorations',
  // Partagés : `event` sert à SWU et One Piece, `item` à Pokémon et Lorcana,
  // `character` à One Piece, Lorcana et Wankul.
  CardRole.event: 'événements',
  CardRole.item: 'objets',
  CardRole.character: 'personnages',
  // One Piece
  CardRole.stage: 'décors',
  // Lorcana
  CardRole.action: 'actions',
  CardRole.song: 'chansons',
  CardRole.location: 'lieux',
};

/// Une liste de cartes en une ligne, exemplaires regroupés.
String _grouped(List<BuildableCard> cards) {
  final counts = <String, int>{};
  for (final card in cards) {
    counts[card.displayName] = (counts[card.displayName] ?? 0) + 1;
  }
  final names = counts.keys.toList()..sort();
  return [for (final n in names) '${counts[n]} × $n'].join('   ·   ');
}

class DeckBuilderView extends ConsumerStatefulWidget {
  const DeckBuilderView({super.key, required this.format});

  /// Format visé. Chacun a son gabarit, mesuré sur son propre corpus — et sa
  /// fiabilité : celui du Commander décrit un deck réel, ceux du Pauper et du
  /// Modern moyennent des archétypes incompatibles, ce que la vue annonce.
  final DeckFormat format;

  @override
  ConsumerState<DeckBuilderView> createState() => _DeckBuilderViewState();
}

class _DeckBuilderViewState extends ConsumerState<DeckBuilderView> {
  DeckBuilder get _builder =>
      DeckBuilder(blueprint: DeckBlueprint.of(widget.format)!);

  /// Général retenu. Nul tant qu'on n'a pas choisi : l'écran montre alors la
  /// liste des candidats plutôt qu'un deck qu'on n'a pas demandé.
  BuildableCard? _commander;

  /// Deck affiché, quand la collection en porte plusieurs à la fois.
  int _shown = 0;

  /// Dernière série calculée, et ce pour quoi elle l'a été.
  ///
  /// **Mémorisée parce que la calculer coûte quatre constructions**, et que le
  /// seul geste courant — passer d'un deck à l'autre — ne change ni la
  /// collection ni le général. Sans ce cache, changer d'onglet reconstruirait
  /// tout pour afficher ce qui était déjà calculé.
  List<BuildableCard>? _seriesFor;
  BuildableCard? _seriesCommander;
  DeckSeries? _series;

  DeckSeries _seriesOf(List<BuildableCard> cards, BuildableCard? commander) {
    final cached = _series;
    if (cached != null &&
        identical(_seriesFor, cards) &&
        identical(_seriesCommander, commander)) {
      return cached;
    }
    final computed = DeckSeriesBuilder(builder: _builder).build(
      cards,
      first: commander,
    );
    _seriesFor = cards;
    _seriesCommander = commander;
    _series = computed;
    return computed;
  }

  @override
  Widget build(BuildContext context) {
    // **Sans gabarit, pas de construction.** Le format construit de Riftbound
    // n'a pas de corpus mesuré : bâtir avec les proportions du Commander
    // produirait un deck faux sous une apparence de rigueur.
    if (DeckBlueprint.of(widget.format) == null) {
      return const _Note(
        'Aucun gabarit mesuré pour ce format.\n'
        'Les proportions d\'un deck se mesurent sur un corpus, et celles de '
        'Magic ne s\'y transposent pas : ce jeu compte des runes et des champs '
        'de bataille, pas des terrains. Les decks du corpus restent '
        'consultables dans « Préconstruits ».',
      );
    }

    final collection = ref.watch(buildableCollectionProvider(widget.format));

    return collection.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) => _Note('Collection illisible : $error'),
      data: _content,
    );
  }

  Widget _content(List<BuildableCard> cards) {
    final blueprint = DeckBlueprint.of(widget.format)!;
    if (!blueprint.needsCommander) {
      return _built(cards, null, blueprint, onChangeCommander: null);
    }

    final commanders = _builder.commanders(cards);
    if (commanders.isEmpty) {
      return const _Note(
        'Aucune créature légendaire dans votre collection.\n'
        'Un deck Commander se construit autour d\'un général : il en faut un.',
      );
    }

    final commander = _commander;
    if (commander == null) {
      return _CommanderPicker(
        commanders: commanders,
        onPick: (c) => setState(() {
          _commander = c;
          _shown = 0;
        }),
      );
    }

    return _built(
      cards,
      commander,
      blueprint,
      onChangeCommander: () => setState(() {
        _commander = null;
        _shown = 0;
      }),
    );
  }

  /// Le deck, et les autres decks quand la collection en porte plusieurs.
  ///
  /// **La série n'enlève rien à l'écran d'un deck seul, elle s'y ajoute.** Une
  /// collection trop mince pour deux decks — le cas courant, le vivier étant le
  /// facteur limitant — retrouve exactement l'écran d'avant : un deck, son
  /// diagnostic, et rien de plus. Le sélecteur n'apparaît que lorsqu'il a
  /// quelque chose à sélectionner.
  ///
  /// Et quand la série refuse **tout** — un premier deck trop éloigné du corpus
  /// —, c'est le deck ordinaire qui s'affiche, avec ce qu'on peut lui
  /// reprocher. Refuser de montrer serait une régression : l'écran d'un deck
  /// seul a toujours montré les decks imparfaits, c'est même sa raison d'être.
  Widget _built(
    List<BuildableCard> cards,
    BuildableCard? commander,
    DeckBlueprint blueprint, {
    required VoidCallback? onChangeCommander,
  }) {
    final series = _seriesOf(cards, commander);

    if (series.decks.length < 2) {
      return _DeckView(
        deck: series.decks.isEmpty
            ? _builder.build(cards, commander)
            : series.decks.first,
        blueprint: blueprint,
        onChangeCommander: onChangeCommander,
      );
    }

    final index = _shown.clamp(0, series.decks.length - 1);
    return Column(
      children: [
        _SeriesBar(
          series: series,
          shown: index,
          onPick: (i) => setState(() => _shown = i),
        ),
        Expanded(
          child: _DeckView(
            deck: series.decks[index],
            blueprint: blueprint,
            onChangeCommander: onChangeCommander,
          ),
        ),
      ],
    );
  }
}

/// Le bandeau des decks simultanés : combien, lequel, et pourquoi pas un de plus.
class _SeriesBar extends StatelessWidget {
  const _SeriesBar({
    required this.series,
    required this.shown,
    required this.onPick,
  });

  final DeckSeries series;
  final int shown;
  final ValueChanged<int> onPick;

  /// Ce qui a arrêté la série, dit à l'utilisateur plutôt qu'au journal.
  ///
  /// **Le deck refusé porte ce qui lui manquait**, et c'est le seul renseignement
  /// actionnable : « à deux cartes près » se règle en achetant deux cartes,
  /// « pas de quatrième deck » ne se règle pas.
  ///
  /// **Écrit court pour tenir sur une ligne.** Vu sur l'appareil, la version
  /// longue passait à deux lignes et repoussait le deck à mi-hauteur, sous deux
  /// barres de sélection déjà présentes. Le titre au-dessus donne le résultat ;
  /// cette ligne le nuance, elle n'a pas à le répéter — d'où « un 4ᵉ » et non
  /// « un 4ᵉ deck », et la disparition du « Au moins N » qui redisait le titre.
  String get _reason => switch (series.stop) {
    SeriesStop.limitReached => 'recherche arrêtée là',
    SeriesStop.incomplete =>
      'un ${series.decks.length + 1}ᵉ à '
          '${series.refused?.diagnosis.short ?? 0} cartes près',
    SeriesStop.offBlueprint => 'un ${series.decks.length + 1}ᵉ serait trop bancal',
    SeriesStop.noCommander => 'plus de général disponible',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${series.decks.length} decks jouables en même temps',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            // Ce que la promesse vaut — aucune carte n'est comptée deux fois —
            // puis ce qui a arrêté la série, séparés par un point médian pour
            // tenir sur une ligne là où deux phrases en prenaient deux.
            'Aucune carte partagée · $_reason',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < series.decks.length; i++)
                ChoiceChip(
                  label: Text('Deck ${i + 1}'),
                  selected: i == shown,
                  onSelected: (_) => onPick(i),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Choix du général, ou remise du choix au constructeur.
class _CommanderPicker extends StatelessWidget {
  const _CommanderPicker({required this.commanders, required this.onPick});

  final List<BuildableCard> commanders;
  final ValueChanged<BuildableCard> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${commanders.length} généraux possibles',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Le général décide des couleurs du deck, donc de ce que votre '
                'collection y apporte. Maintenez une ligne pour voir la carte.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              // Le premier de la liste est celui qui ouvre le plus de cartes :
              // le proposer d'un bouton évite d'imposer un choix à qui n'en a
              // pas encore.
              FilledButton.tonalIcon(
                onPressed: () => onPick(commanders.first),
                icon: const Icon(Icons.auto_awesome),
                label: Text(
                  'Choisir pour moi — ${commanders.first.displayName}',
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 20),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            itemCount: commanders.length,
            itemBuilder: (context, index) {
              final card = commanders[index];
              return ListTile(
                onTap: () => onPick(card),
                onLongPress: () => showCardArt(
                  context,
                  oracleId: card.oracleId,
                  title: card.displayName,
                ),
                contentPadding: EdgeInsets.zero,
                title: Text(card.displayName, maxLines: 1),
                subtitle: Text(
                  card.typeLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _ColorDots(colors: card.colorIdentity),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Le deck produit, et ce qu'on peut lui reprocher.
class _DeckView extends StatelessWidget {
  const _DeckView({
    required this.deck,
    required this.blueprint,
    required this.onChangeCommander,
  });

  final BuiltDeck deck;
  final DeckBlueprint blueprint;

  /// Nul dans les formats sans général : il n'y a alors rien à changer.
  final VoidCallback? onChangeCommander;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final commander = deck.commander;
    // Les exemplaires multiples se regroupent : « 4 Foudre » plutot que quatre
    // lignes identiques, comme dans toute liste de deck.
    final counts = <String, int>{};
    final unique = <BuildableCard>[];
    for (final card in [...deck.spells, ...deck.lands]) {
      if (counts.containsKey(card.oracleId)) {
        counts[card.oracleId] = counts[card.oracleId]! + 1;
      } else {
        counts[card.oracleId] = 1;
        unique.add(card);
      }
    }
    unique.sort((a, b) => a.displayName.compareTo(b.displayName));

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        if (commander != null) ...[
          Row(
            children: [
              Expanded(
                // **Maintenir montre le général**, comme les 99 autres cartes
                // de la liste et comme l'écran de choix d'où l'on vient.
                // Sans ce geste, revoir la carte qui structure le deck
                // obligeait à toucher « Changer », ce qui le détruit.
                child: InkWell(
                  onLongPress: () => showCardArt(
                    context,
                    oracleId: commander.oracleId,
                    title: commander.displayName,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        commander.displayName,
                        style: theme.textTheme.titleLarge,
                      ),
                      Text(
                        commander.typeLine,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              TextButton(
                onPressed: onChangeCommander,
                child: const Text('Changer'),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (blueprint.reliability == BlueprintReliability.averaged) ...[
          const _AveragedWarning(),
          const SizedBox(height: 12),
        ],
        if (blueprint.reliability == BlueprintReliability.regulatory) ...[
          const _RegulatoryNote(),
          const SizedBox(height: 12),
        ],
        _Summary(deck: deck, blueprint: blueprint),
        const SizedBox(height: 16),
        Text('Ce que le deck vise', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final entry in blueprint.roles.entries)
          _RoleGauge(
            label: _roleLabels[entry.key] ?? entry.key.name,
            target: entry.value.countFor(blueprint.size),
            gap: deck.diagnosis.roleGaps[entry.key] ?? 0,
            tolerance: entry.value.spread,
          ),
        // **Rien sur les terrains dans un jeu qui n'en a pas.** Une rubrique
        // vide se lit comme un manque ; son absence dit qu'il n'y a rien à
        // manquer.
        //
        // La condition portait d'abord sur le seul gabarit, et ne couvrait donc
        // que la moitié du cas : Wankul déclare des terrains — dix sur
        // cinquante, c'est son règlement — mais ce sont des cartes de la
        // collection, pas des terrains de base illimités. L'écran affichait un
        // titre suivi de rien, ce qui se lit comme une panne. Le compte réel
        // tranche : on n'annonce des terrains de base que lorsqu'il y en a.
        if (blueprint.lands != null && deck.basicCount > 0) ...[
          const SizedBox(height: 20),
          Text('Terrains de base', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            deck.basicLands.entries
                .map((e) => '${e.value} × ${e.key}')
                .join('   ·   '),
            style: theme.textTheme.bodyMedium,
          ),
        ],
        if (blueprint.extraSize != null) ...[
          const SizedBox(height: 20),
          Text(
            'Extra Deck — ${deck.extra.length} sur ${blueprint.extraSize}',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            deck.extra.isEmpty
                ? "Aucune carte d'Extra Deck dans votre collection."
                : _grouped(deck.extra),
            style: theme.textTheme.bodyMedium,
          ),
        ],
        const SizedBox(height: 20),
        Text(
          '${unique.length} cartes de votre collection',
          style: theme.textTheme.titleSmall,
        ),
        Text(
          blueprint.maxCopies == 1
              ? "Un seul exemplaire de chacune — le format l'exige. "
                    'Le coût de mana est indiqué à droite.'
              : "Le nombre d'exemplaires précède le nom, "
                    'le ${blueprint.curveLabel} suit.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        for (final card in unique)
          _CardLine(card: card, copies: counts[card.oracleId] ?? 1),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.deck, required this.blueprint});

  final BuiltDeck deck;

  /// **Le gabarit, parce que la phrase du bas en dépend.** Elle annonçait
  /// « cent cases dans ces couleurs » à tous les jeux : un chiffre écrit en dur
  /// du temps où Commander était le seul format visé, et une notion de couleur
  /// que Yu-Gi-Oh et Wankul n'ont pas. Un deck Wankul de cinquante cartes se
  /// voyait donc reprocher de ne pas en remplir cent.
  final DeckBlueprint blueprint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final complete = deck.diagnosis.isComplete;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            complete
                ? '${deck.size} cartes — le deck est complet'
                : '${deck.size} cartes — il en manque ${deck.diagnosis.short}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            deck.lands.isEmpty && deck.basicCount == 0
                ? '${deck.spells.length} cartes'
                      '${deck.extra.isEmpty ? '' : ' · ${deck.extra.length} en Extra Deck'}'
                : '${deck.spells.length} sorts · ${deck.lands.length} terrains '
                      'spéciaux · ${deck.basicCount} terrains de base',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          if (!complete) ...[
            const SizedBox(height: 8),
            Text(
              blueprint.usesColorIdentity
                  ? 'Votre collection ne suffit pas à remplir '
                        '${blueprint.size} cases dans ces couleurs. Le deck '
                        'reste jouable, en plus court.'
                  : 'Votre collection ne suffit pas à remplir '
                        '${blueprint.size} cases. Le deck reste jouable, en '
                        'plus court.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Ce qu'un rôle a obtenu, comparé à ce que les decks réels en comptent.
class _RoleGauge extends StatelessWidget {
  const _RoleGauge({
    required this.label,
    required this.target,
    required this.gap,
    required this.tolerance,
  });

  final String label;
  final int target;
  final int gap;

  /// Écart interquartile mesuré sur le corpus : la moitié des decks réels s'en
  /// écarte d'autant, donc le reprocher au résultat n'aurait pas de sens.
  final double tolerance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final have = target - gap;
    final within = gap <= tolerance;
    final color = gap <= 0
        ? theme.colorScheme.primary
        : within
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: target == 0 ? 0 : (have / target).clamp(0.0, 1.0),
                minHeight: 6,
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 54,
            child: Text(
              '$have / $target',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardLine extends StatelessWidget {
  const _CardLine({required this.card, this.copies = 1});

  final BuildableCard card;

  /// Exemplaires retenus. Affiché seulement au-delà d'un : dans un format
  /// singleton, un « 1 » devant chaque ligne n'apprendrait rien.
  final int copies;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roles = rolesOf(card)
        .where((r) => r != CardRole.land)
        .map((r) => _roleLabels[r] ?? r.name)
        .join(', ');

    return InkWell(
      onLongPress: () => showCardArt(
        context,
        oracleId: card.oracleId,
        title: card.displayName,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            // **Un nombre devant un nom de carte est une quantité.** C'est la
            // convention de toutes les listes de deck ; y mettre le coût de
            // mana faisait croire à des exemplaires qu'on ne pouvait pas jouer.
            if (copies > 1)
              SizedBox(
                width: 24,
                child: Text(
                  '$copies',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Expanded(
              child: Text(
                card.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (roles.isNotEmpty) ...[
              Text(
                roles,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              card.manaCost.isEmpty ? '' : card.manaCost,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontFeatures: const [],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pastilles d'identité couleur, sans texte : cinq couleurs se reconnaissent à
/// leur teinte, et un nom prendrait quatre fois la place.
class _ColorDots extends StatelessWidget {
  const _ColorDots({required this.colors});

  final Set<String> colors;

  static const _swatches = {
    'W': Color(0xFFF3E9C8),
    'U': Color(0xFF3A7DC1),
    'B': Color(0xFF2E2A31),
    'R': Color(0xFFC0453A),
    'G': Color(0xFF3E8A5B),
  };

  @override
  Widget build(BuildContext context) {
    final ordered = ['W', 'U', 'B', 'R', 'G'].where(colors.contains);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final color in ordered)
          Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(left: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _swatches[color],
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Ce qu'il faut penser d'un gabarit moyenné.
///
/// **Le dire est le minimum honnête.** Les 725 decks Pauper et les 113 Modern
/// du corpus mêlent des archétypes incompatibles — aggro, contrôle, combo — dont
/// la médiane décrit un deck jouable mais qui ne ressemble à aucun d'eux. Le
/// résultat reste utile ; le présenter comme aussi fondé qu'un deck Commander
/// serait faux.
/// Ce que l'écran dit d'un gabarit tiré du règlement et non d'un corpus.
///
/// **Le message contraire de `_AveragedWarning`.** Celui-là prévient que la
/// cible est une moyenne dont les decks réels s'écartent ; celui-ci dit que la
/// cible n'a pas d'écart du tout, parce que ce n'est pas une tendance mais une
/// règle. Les afficher tous deux de la même façon ferait lire « à peu près dix
/// terrains » là où le règlement en impose dix.
class _RegulatoryNote extends StatelessWidget {
  const _RegulatoryNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.gavel_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Aucune liste de tournoi n'est publiée pour ce jeu : les "
              "proportions ci-dessous viennent de son règlement, pas d'un "
              "corpus. Elles ne sont donc pas des moyennes — ce sont les "
              "contraintes qu'un deck doit respecter pour être légal.",
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AveragedWarning extends StatelessWidget {
  const _AveragedWarning();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Les decks de ce format se ressemblent peu — aggro, contrôle, "
              "combo se partagent le corpus. Les proportions visées sont une "
              "moyenne de tous, donc un repère plus lâche qu'en Commander.",
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
