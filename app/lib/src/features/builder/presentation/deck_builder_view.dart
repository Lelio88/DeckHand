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

/// Libellés français des rôles. Le domaine les nomme en anglais, comme le texte
/// oracle qu'il inspecte ; l'écran, lui, parle à l'utilisateur.
const _roleLabels = {
  CardRole.creature: 'créatures',
  CardRole.draw: 'pioche',
  CardRole.ramp: 'accélération',
  CardRole.removal: 'retrait',
  CardRole.land: 'terrains',
};

class DeckBuilderView extends ConsumerStatefulWidget {
  const DeckBuilderView({super.key, required this.format});

  /// Format visé. Le constructeur ne sait bâtir que du Commander : les autres
  /// formats reçoivent une explication, pas un deck bancal.
  final DeckFormat format;

  @override
  ConsumerState<DeckBuilderView> createState() => _DeckBuilderViewState();
}

class _DeckBuilderViewState extends ConsumerState<DeckBuilderView> {
  static const _builder = DeckBuilder();

  /// Général retenu. Nul tant qu'on n'a pas choisi : l'écran montre alors la
  /// liste des candidats plutôt qu'un deck qu'on n'a pas demandé.
  BuildableCard? _commander;

  @override
  Widget build(BuildContext context) {
    if (widget.format != DeckFormat.commander) {
      return const _Note(
        'La construction automatique ne couvre que le Commander.\n\n'
        "Les 725 decks Pauper du corpus s'étalent de 25 à 40 % de créatures "
        "et de 23 à 43 % de sorts : ce sont des archétypes distincts, qu'une "
        "moyenne fondrait en un deck qui n'existe nulle part. Les 190 "
        "précons Commander, eux, se ressemblent assez pour servir de modèle.",
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
        onPick: (c) => setState(() => _commander = c),
      );
    }

    return _DeckView(
      deck: _builder.build(cards, commander),
      onChangeCommander: () => setState(() => _commander = null),
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
                label: Text('Choisir pour moi — ${commanders.first.displayName}'),
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
  const _DeckView({required this.deck, required this.onChangeCommander});

  final BuiltDeck deck;
  final VoidCallback onChangeCommander;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blueprint = DeckBlueprint.commander;
    final byName = [...deck.spells, ...deck.lands]
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    deck.commander.displayName,
                    style: theme.textTheme.titleLarge,
                  ),
                  Text(
                    deck.commander.typeLine,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onChangeCommander,
              child: const Text('Changer'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Summary(deck: deck),
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
        const SizedBox(height: 20),
        Text('Terrains de base', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(
          deck.basicLands.entries
              .map((e) => '${e.value} × ${e.key}')
              .join('   ·   '),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        Text(
          '${byName.length} cartes de votre collection',
          style: theme.textTheme.titleSmall,
        ),
        Text(
          "Un seul exemplaire de chacune — le format l'exige. "
          'Le coût de mana est indiqué à droite.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        for (final card in byName)
          _CardLine(card: card),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.deck});

  final BuiltDeck deck;

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
            '${deck.spells.length} sorts · ${deck.lands.length} terrains '
            'spéciaux · ${deck.basicCount} terrains de base',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          if (!complete) ...[
            const SizedBox(height: 8),
            Text(
              'Votre collection ne suffit pas à remplir cent cases dans ces '
              'couleurs. Le deck reste jouable, en plus court.',
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
  const _CardLine({required this.card});

  final BuildableCard card;

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
            // **Le nom d'abord, le coût à droite.** Un nombre placé devant un
            // nom de carte se lit comme une quantité — c'est la convention de
            // toutes les listes de deck — et faisait croire à plusieurs
            // exemplaires d'une carte que le format n'autorise qu'en un seul.
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
