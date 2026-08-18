/// L'étape où l'on déclare les jeux auxquels on joue, et dans quel ordre.
///
/// **Elle s'ouvre une fois, à la création du compte.** Le sélecteur alignait les
/// huit jeux dans l'ordre du code : quelqu'un qui ne joue qu'à Pokémon passait
/// devant sept jeux qui ne le concernent pas, à chaque fois. Déclarer ses jeux
/// remonte les siens en tête et ouvre l'application dessus.
///
/// **Cocher, c'est ordonner.** Le rang s'affiche sur la tuile au fur et à mesure
/// — 1, 2, 3 — parce que c'est l'ordre qui décide, pas l'ensemble : le premier
/// coché devient le jeu que l'application ouvre. Un second geste de
/// réordonnancement aurait demandé un écran de plus pour une information que le
/// premier geste porte déjà.
///
/// **Rien n'est obligatoire, et rien n'est définitif.** « Plus tard » enregistre
/// une réponse vide : la question ne revient pas, et le sélecteur garde ses huit
/// jeux à plat. L'écran se rouvre depuis l'écran de compte, ce qui est la seule
/// porte pour les comptes créés avant lui.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/selected_game.dart';
import '../data/game_artwork.dart';
import '../data/profile_repository.dart';
import 'game_blurb.dart';
import 'game_tile.dart';

class PickGamesScreen extends ConsumerStatefulWidget {
  const PickGamesScreen({super.key, this.initial = const [], this.onDone});

  /// Les jeux déjà déclarés, quand on rouvre l'écran pour les modifier.
  final List<Game> initial;

  /// Ce qu'il faut faire une fois le choix enregistré.
  ///
  /// `null` à l'inscription : l'écran est alors l'aiguillage lui-même, et c'est
  /// la relecture du profil qui fait passer à la suite. Une fermeture explicite
  /// y refermerait un écran qui n'a pas été empilé.
  final VoidCallback? onDone;

  @override
  ConsumerState<PickGamesScreen> createState() => _PickGamesScreenState();
}

class _PickGamesScreenState extends ConsumerState<PickGamesScreen> {
  late final List<Game> _picked = [...widget.initial];
  bool _busy = false;
  String? _error;

  void _toggle(Game game) {
    setState(() {
      // Décocher puis recocher remet le jeu en dernier, et c'est le
      // comportement attendu : c'est ainsi qu'on corrige un ordre sans avoir à
      // tout décocher.
      if (!_picked.remove(game)) _picked.add(game);
    });
  }

  Future<void> _save(List<Game> games) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(profileRepositoryProvider).save(games);
      // Le premier déclaré devient le jeu courant : sans cela, on ouvrirait
      // l'application sur Magic après avoir déclaré ne jouer qu'à Pokémon.
      if (games.isNotEmpty) {
        await ref.read(selectedGameProvider.notifier).select(games.first);
      }
      ref.invalidate(playedGamesProvider);
      widget.onDone?.call();
    } catch (e) {
      // **Ne jamais laisser l'utilisateur coincé sur cet écran.** C'est un
      // réglage de confort posé devant la porte de l'application : une panne de
      // réseau doit pouvoir être ignorée, pas bloquer l'accès à sa collection.
      if (mounted) {
        setState(() => _error = 'Choix non enregistré : $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artwork = ref.watch(gameArtworkProvider);

    return Scaffold(
      appBar: widget.onDone == null
          ? null
          : AppBar(title: const Text('Mes jeux')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              children: [
                Text(
                  'À quoi jouez-vous ?',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Vos jeux passeront en tête, dans l\'ordre où vous les '
                  'choisissez — le premier est celui que DeckHand ouvrira. '
                  'Les autres restent accessibles, et tout se change plus tard.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                GameRows(
                  perRow: 2,
                  spacing: 10,
                  aspectRatio: 0.82,
                  children: [
                    for (final game in Game.values)
                      GameTile(
                        name: game.label,
                        detail: gameDetail(game),
                        note: gameNote(game),
                        artUrl: artwork.asData?.value[game.id],
                        frame: gameArtworks[game.id]?.frame,
                        selected: _picked.contains(game),
                        rank: _picked.contains(game)
                            ? _picked.indexOf(game) + 1
                            : null,
                        onTap: _busy ? null : () => _toggle(game),
                      ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy || _picked.isEmpty
                      ? null
                      : () => _save(_picked),
                  child: Text(
                    _picked.isEmpty
                        ? 'Choisissez au moins un jeu'
                        : _picked.length == 1
                        ? 'Continuer avec ${_picked.first.label}'
                        : 'Continuer avec ${_picked.length} jeux',
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  // Enregistre une réponse vide, ce qui n'est pas la même chose
                  // que ne rien enregistrer : la ligne existe, donc la question
                  // ne sera plus posée.
                  onPressed: _busy ? null : () => _save(const []),
                  child: const Text('Plus tard'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
