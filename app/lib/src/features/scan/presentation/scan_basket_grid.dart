/// Les cartes retenues au fil de la caméra, montrées en entier (#8).
///
/// **Pourquoi l'image entière, et pas une ligne de texte.** Le mode vidéo se
/// tient à deux mains : une pour la carte, l'autre pour l'appareil. On ne lit
/// pas une liste dans ces conditions — on la parcourt après coup. Une carte se
/// reconnaît alors d'un coup d'œil à son illustration, là où « Pym
/// Technologies » demande de lire, de se souvenir, et de croire l'application
/// sur parole. C'est aussi le seul rendu qui rende le §IV.8 praticable : la
/// carte qu'un seuil a laissé passer se **voit**, elle ne se déduit pas.
///
/// **Le nom reste, sous la vignette.** L'illustration suffit à reconnaître, pas
/// à distinguer deux impressions de la même carte ni à lever un doute sur une
/// reconnaissance fausse. Il est petit parce qu'il est second.
///
/// **Ce composant ne sait rien de la caméra ni du réseau.** Il reçoit des
/// [ScannedCard] toutes faites, ce qui le rend testable sans appareil — c'est
/// la raison d'être de sa séparation d'avec l'écran, qui n'est lui pas
/// testable, `availableCameras()` n'ayant pas de réponse hors d'un téléphone.
///
/// Exemple canonique :
/// ```dart
/// ScanBasketGrid(
///   cards: [ScannedCard(oracleId: '…', label: 'Pym Technologies', imageUrl: url)],
///   onToggle: (id) => setState(() => basket.line(id).keep = !…),
///   onRemove: (id) => setState(() => basket.remove(id)),
/// )
/// ```
library;

import 'package:flutter/material.dart';

import '../../../common/card_image.dart';

/// Une carte du panier, telle que la grille l'affiche.
class ScannedCard {
  const ScannedCard({
    required this.oracleId,
    required this.label,
    this.imageUrl,
    this.quantity = 1,
    this.keep = true,
  });

  final String oracleId;

  /// Ce qu'on montre à l'utilisateur — le nom dans sa langue quand on l'a.
  final String label;

  /// L'image de la carte **entière**, pas de son illustration seule.
  final String? imageUrl;

  final int quantity;
  final bool keep;
}

/// Combien de cartes par ligne.
///
/// Trois, comme le classeur : c'est la densité à laquelle une carte reste
/// reconnaissable sur un téléphone, mesurée là-bas et sans raison de différer
/// ici — les deux montrent le même carton dans la même case debout.
const int scanGridColumns = 3;

/// Ce que vaut une case, hauteur sur largeur.
///
/// Une carte debout fait 0,716 ; on ajoute de quoi écrire le nom dessous.
const double _cellAspect = 0.60;

class ScanBasketGrid extends StatelessWidget {
  const ScanBasketGrid({
    super.key,
    required this.cards,
    required this.onToggle,
    required this.onRemove,
    this.enabled = true,
  });

  final List<ScannedCard> cards;
  final void Function(String oracleId) onToggle;
  final void Function(String oracleId) onRemove;

  /// Faux pendant l'enregistrement : on ne modifie pas une liste en cours
  /// d'écriture.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: scanGridColumns,
        childAspectRatio: _cellAspect,
        crossAxisSpacing: 10,
        mainAxisSpacing: 12,
      ),
      itemCount: cards.length,
      itemBuilder: (context, i) => _ScannedTile(
        card: cards[i],
        onToggle: enabled ? () => onToggle(cards[i].oracleId) : null,
        onRemove: enabled ? () => onRemove(cards[i].oracleId) : null,
      ),
    );
  }
}

class _ScannedTile extends StatelessWidget {
  const _ScannedTile({
    required this.card,
    required this.onToggle,
    required this.onRemove,
  });

  final ScannedCard card;
  final VoidCallback? onToggle;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // **Le geste porte sur la tuile entière, nom compris.** Le nom est sous
    // l'image, et un doigt qui vise une vignette de trois par ligne tombe
    // volontiers dessus : n'écouter que l'image rendait la carte
    // indécochable une fois sur deux.
    return Semantics(
      label: card.label,
      selected: card.keep,
      child: GestureDetector(
        // **L'appui bascule, l'appui long retire.** Décocher est réversible et
        // se voit — la carte grise reste là, on peut revenir dessus. Retirer
        // ne l'est pas : c'est le geste rare, il demande un geste long.
        onTap: onToggle,
        onLongPress: onRemove,
        // Sans cela, les espaces entre l'image et le nom ne repondent pas.
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Une carte couchée est redressée pour remplir sa case,
                    // exactement comme dans le classeur : sans cela, `cover`
                    // n'en montrerait qu'une bande centrale.
                    Opacity(
                      opacity: card.keep ? 1 : 0.28,
                      child: CardImage(
                        url: card.imageUrl,
                        uprightInCell: true,
                        placeholder: ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ),
                    if (!card.keep)
                      const Center(
                        child: Icon(
                          Icons.block,
                          size: 32,
                          color: Colors.white70,
                        ),
                      ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _Pastille(
                        icon: card.keep ? Icons.check : Icons.close,
                        color: card.keep
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                    ),
                    if (card.quantity > 1)
                      Positioned(
                        top: 4,
                        left: 4,
                        child: _Pastille.text(
                          '×${card.quantity}',
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              card.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: card.keep
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La pastille de coin — coche, croix ou nombre d'exemplaires.
class _Pastille extends StatelessWidget {
  const _Pastille({required this.icon, required this.color}) : label = null;
  const _Pastille.text(this.label, {required this.color}) : icon = null;

  final IconData? icon;
  final String? label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: label == null
          ? const EdgeInsets.all(3)
          : const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(10),
      ),
      child: icon != null
          ? Icon(icon, size: 14, color: Colors.white)
          : Text(
              label!,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
    );
  }
}
