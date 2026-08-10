/// La roue chromatique : dire quelles couleurs on veut, et lesquelles on refuse.
///
/// **Cinq pastilles sur une ligne posaient une question ambiguë.** Cocher le
/// rouge voulait-il dire « des decks rouges » ou « des decks uniquement
/// rouges » ? Et rien ne permettait de dire « du rouge, mais pas de bleu », qui
/// est pourtant la question qu'on se pose devant sa collection : on connaît ses
/// couleurs, et celles qu'on ne jouera pas.
///
/// **Trois états par couleur, atteints par appuis successifs** : indifférente,
/// voulue, bannie. Un appui pour vouloir, deux pour bannir, trois pour revenir
/// — pas de second contrôle à côté, pas de mode à choisir avant.
///
/// **Le pentagone, et pas une rangée.** Les cinq couleurs se disposent au dos
/// de chaque carte dans cet ordre depuis trente ans ; un joueur y lit les
/// alliances et les oppositions sans réfléchir — les voisines s'allient, les
/// opposées se combattent. Une ligne perd cette information, que la forme donne
/// gratuitement.
///
/// La roue refermée reste un simple disque : elle montre ce qui est choisi sans
/// occuper la place de cinq pastilles.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/mana_color.dart';

/// Ordre du pentagone, en partant du haut et dans le sens horaire.
///
/// C'est l'ordre WUBRG lui-même : blanc au sommet, puis bleu, noir, rouge,
/// vert. Le dessiner autrement rendrait la roue méconnaissable.
const _wheelOrder = ['W', 'U', 'B', 'R', 'G'];

/// Le disque compact, à poser dans une barre de filtres.
class ColorWheelButton extends StatelessWidget {
  const ColorWheelButton({
    super.key,
    required this.wanted,
    required this.banned,
    required this.onChanged,
  });

  final Set<String> wanted;
  final Set<String> banned;
  final void Function(Set<String> wanted, Set<String> banned) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = wanted.isNotEmpty || banned.isNotEmpty;

    return Tooltip(
      message: 'Couleurs',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () async {
          final result = await showDialog<(Set<String>, Set<String>)>(
            context: context,
            builder: (context) =>
                _ColorWheelDialog(wanted: wanted, banned: banned),
          );
          if (result != null) onChanged(result.$1, result.$2);
        },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: active ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(3),
          child: CustomPaint(
            painter: _WheelPainter(
              wanted: wanted,
              banned: banned,
              dim: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
      ),
    );
  }
}

/// Le disque en cinq quartiers, un par couleur.
///
/// Une couleur voulue s'affiche pleine, une bannie devient grise, une
/// indifférente reste pâle : l'état du filtre se lit sans l'ouvrir.
class _WheelPainter extends CustomPainter {
  const _WheelPainter({
    required this.wanted,
    required this.banned,
    required this.dim,
  });

  final Set<String> wanted;
  final Set<String> banned;
  final Color dim;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const sweep = 2 * math.pi / 5;
    // Le premier quartier est centré sur le haut, comme le blanc du pentagone.
    final start = -math.pi / 2 - sweep / 2;

    for (var i = 0; i < _wheelOrder.length; i++) {
      final color = manaColors.firstWhere((c) => c.symbol == _wheelOrder[i]);
      final isBanned = banned.contains(color.symbol);
      final isWanted = wanted.contains(color.symbol);
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = isBanned
            ? dim
            : isWanted
            ? color.swatch
            : color.swatch.withValues(alpha: 0.35);

      canvas.drawArc(rect, start + i * sweep, sweep, true, paint);
    }
  }

  @override
  bool shouldRepaint(_WheelPainter old) =>
      old.wanted != wanted || old.banned != banned;
}

/// Les cinq couleurs en grand, disposées en pentagone.
class _ColorWheelDialog extends StatefulWidget {
  const _ColorWheelDialog({required this.wanted, required this.banned});

  final Set<String> wanted;
  final Set<String> banned;

  @override
  State<_ColorWheelDialog> createState() => _ColorWheelDialogState();
}

class _ColorWheelDialogState extends State<_ColorWheelDialog> {
  late final Set<String> _wanted = {...widget.wanted};
  late final Set<String> _banned = {...widget.banned};

  ManaChoice _choiceOf(String symbol) => _wanted.contains(symbol)
      ? ManaChoice.wanted
      : _banned.contains(symbol)
      ? ManaChoice.banned
      : ManaChoice.neutral;

  void _advance(String symbol) {
    final next = _choiceOf(symbol).next;
    setState(() {
      _wanted.remove(symbol);
      _banned.remove(symbol);
      switch (next) {
        case ManaChoice.wanted:
          _wanted.add(symbol);
        case ManaChoice.banned:
          _banned.add(symbol);
        case ManaChoice.neutral:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Couleurs', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Un appui pour la vouloir, deux pour la bannir',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            // **Le pentagone est borné.** Carré et libre, il prenait toute la
            // largeur disponible et débordait en hauteur sur un écran court —
            // la légende et les boutons passaient sous le pli.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 300,
                  maxHeight: 300,
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final side = math.min(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      final radius = side * 0.34;
                      final centre = Offset(side / 2, side / 2);
                      final badge = side * 0.26;

                      return Stack(
                        children: [
                          for (var i = 0; i < _wheelOrder.length; i++)
                            () {
                              // Sommet en haut, puis sens horaire : l'angle part de
                              // -90° et avance d'un cinquième de tour.
                              final angle = -math.pi / 2 + i * 2 * math.pi / 5;
                              final position =
                                  centre +
                                  Offset(
                                    math.cos(angle) * radius,
                                    math.sin(angle) * radius,
                                  );
                              final color = manaColors.firstWhere(
                                (c) => c.symbol == _wheelOrder[i],
                              );
                              return Positioned(
                                left: position.dx - badge / 2,
                                top: position.dy - badge / 2,
                                width: badge,
                                height: badge,
                                child: _ColorFace(
                                  color: color,
                                  choice: _choiceOf(color.symbol),
                                  onTap: () => _advance(color.symbol),
                                ),
                              );
                            }(),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Legend(wanted: _wanted, banned: _banned),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _wanted.clear();
                    _banned.clear();
                  }),
                  child: const Text('Tout effacer'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop((_wanted, _banned)),
                  child: const Text('Appliquer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Une couleur, en grand, dans l'état où on l'a mise.
class _ColorFace extends StatelessWidget {
  const _ColorFace({
    required this.color,
    required this.choice,
    required this.onTap,
  });

  final ManaColor color;
  final ManaChoice choice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final banned = choice == ManaChoice.banned;
    final wanted = choice == ManaChoice.wanted;

    return Semantics(
      label:
          '${color.label} — ${switch (choice) {
            ManaChoice.wanted => 'voulue',
            ManaChoice.banned => 'bannie',
            ManaChoice.neutral => 'indifférente',
          }}',
      button: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Une couleur bannie perd sa teinte : la barrer sans l'éteindre
            // laisserait croire qu'elle est encore demandée.
            color: banned
                ? theme.colorScheme.surfaceContainerHighest
                : color.swatch.withValues(alpha: wanted ? 1 : 0.4),
            border: Border.all(
              color: wanted
                  ? theme.colorScheme.primary
                  : banned
                  ? theme.colorScheme.error
                  : theme.colorScheme.outlineVariant,
              width: choice == ManaChoice.neutral ? 1 : 3,
            ),
          ),
          child: Center(
            child: banned
                ? Icon(Icons.block, color: theme.colorScheme.error, size: 26)
                : Text(
                    color.symbol,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: wanted
                          ? color.onSwatch
                          : color.onSwatch.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Ce que le filtre demande, en toutes lettres.
///
/// La forme dit l'état couleur par couleur ; la phrase dit ce qu'on obtiendra,
/// et c'est elle qui lève le dernier doute sur le sens du filtre.
class _Legend extends StatelessWidget {
  const _Legend({required this.wanted, required this.banned});

  final Set<String> wanted;
  final Set<String> banned;

  String _names(Set<String> symbols) => manaColors
      .where((c) => symbols.contains(c.symbol))
      .map((c) => c.label.toLowerCase())
      .join(', ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (wanted.isNotEmpty) 'contenant ${_names(wanted)}',
      if (banned.isNotEmpty) 'sans ${_names(banned)}',
    ];

    return Text(
      parts.isEmpty ? 'Toutes les couleurs' : 'Decks ${parts.join(', ')}',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyMedium,
    );
  }
}
