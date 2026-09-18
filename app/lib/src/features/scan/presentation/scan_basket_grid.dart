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
/// **Les gestes sont ceux du reste de l'application.** L'appui long agrandit la
/// carte — c'est ce que fait une case de classeur, une ligne du sélecteur
/// d'édition, et un utilisateur l'essaie ici par réflexe.
///
/// **Un appui écarte la carte, un appui long l'agrandit.** C'est la répartition
/// du reste de l'application, et c'est aussi la bonne ici : écarter est le
/// geste courant de cette liste — on parcourt un booster fraîchement scanné en
/// retirant ce que la reconnaissance a inventé —, l'agrandir est le geste rare,
/// celui du doute. Le geste courant va au toucher simple.
///
/// Une version intermédiaire a déplacé l'écartement sur la pastille, sur un
/// diagnostic faux : une carte trouvée décochée avait été prise pour une fausse
/// manœuvre, alors qu'elle avait été écartée exprès — c'était un faux positif,
/// et le geste avait parfaitement fonctionné.
///
/// **Le compte se corrige sur place, quand la tuile a la place** (#44).
/// `CardTracker` a raison de compter deux passages quand on repose une carte
/// et qu'on la remontre ; c'est le geste qui est ambigu, et la seule issue
/// était d'écarter la ligne entière. Un bandeau « − n + » en bas de l'image
/// — le même composant que l'étalement, [CopiesStepper] — apparaît dès que la
/// tuile fait la largeur qu'il demande, ce qui est le cas d'un poste de
/// travail et non d'un téléphone à quatre par ligne : le téléphone garde
/// exactement ce qu'il avait. Écarter reste le geste courant, et le seul qui
/// retire.
///
/// **À la souris, le survol montre ce que le maintien montre au doigt.** Une
/// loupe apparaît sous un pointeur et ouvre la carte en grand ; le tactile
/// n'entre jamais dans un survol, et garde l'appui long. C'est la seule
/// surface qui la porte — voir « Toucher agit, maintenir montre » dans
/// `docs/architecture.md` pour ce que cela engage.
///
/// Exemple canonique :
/// ```dart
/// ScanBasketGrid(
///   cards: [ScannedCard(oracleId: '…', label: 'Pym Technologies', imageUrl: url)],
///   onToggle: (id) => setState(() => basket.line(id).keep = !…),
///   onEnlarge: (id) => showCardImage(context, imageUrl: …, title: …),
/// )
/// ```
library;

import 'package:flutter/material.dart';

import '../../../common/card_image.dart';
import 'copies_stepper.dart';

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
/// **Quatre, et non trois comme le classeur.** La densité du classeur a été
/// réglée pour une page entière ; ici les cartes vivent dans le tiers bas de
/// l'écran, sous un viseur qui prend le reste. À trois par ligne, une case
/// mesure plus haut que la bande qui l'accueille : on ne verrait aucune carte
/// en entier, ce qui est précisément la promesse de ce rendu. À quatre, une
/// rangée complète y tient.
///
/// La contrainte vient donc de la hauteur disponible, pas de la lisibilité —
/// et si le partage de l'écran change, ce nombre se remesure avec lui.
const int scanGridColumns = 4;

/// Ce que vaut une case, hauteur sur largeur.
///
/// Une carte debout fait 0,716 ; on ajoute de quoi écrire le nom dessous.
const double _cellAspect = 0.60;

class ScanBasketGrid extends StatelessWidget {
  const ScanBasketGrid({
    super.key,
    required this.cards,
    required this.onToggle,
    required this.onEnlarge,
    required this.onIncrement,
    required this.onDecrement,
    this.enabled = true,
  });

  final List<ScannedCard> cards;
  final void Function(String oracleId) onToggle;

  /// Un exemplaire de plus, ou de moins, à la main (#44). **Requis** : un
  /// écran qui oublierait de les brancher montrerait un bandeau inerte.
  final void Function(String oracleId) onIncrement;
  final void Function(String oracleId) onDecrement;

  /// Ce que fait l'appui long. **Confié à l'appelant**, comme le reste : ce
  /// composant n'ouvre pas de dialogue et ne connaît pas le réseau, ce qui est
  /// la raison pour laquelle il se teste sans appareil.
  final void Function(String oracleId) onEnlarge;

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
        // La clé sert aux tests, qui visent une tuile par sa carte.
        key: ValueKey(cards[i].oracleId),
        card: cards[i],
        enabled: enabled,
        onToggle: enabled ? () => onToggle(cards[i].oracleId) : null,
        onEnlarge: () => onEnlarge(cards[i].oracleId),
        onIncrement: () => onIncrement(cards[i].oracleId),
        onDecrement: () => onDecrement(cards[i].oracleId),
      ),
    );
  }
}

/// Largeur de tuile à partir de laquelle le compte se corrige sur place.
///
/// **Mesurée par le composant, pas choisie.** `CopiesStepper.minWidth` fait
/// 104 dp ; huit de chaque côté pour qu'il ne touche pas les bords. Sous ce
/// seuil — un téléphone de 360 donne des tuiles de 76 — la pastille `×N`
/// reste seule, et la quantité se lit sans se régler : c'est l'état d'avant,
/// là où tout est mesuré. Au-dessus — un poste de travail donne 250 et plus —
/// le bandeau apparaît.
const double _stepperMinTileWidth = CopiesStepper.minWidth + 16;

class _ScannedTile extends StatefulWidget {
  const _ScannedTile({
    super.key,
    required this.card,
    required this.onToggle,
    required this.onEnlarge,
    required this.onIncrement,
    required this.onDecrement,
    required this.enabled,
  });

  final ScannedCard card;
  final VoidCallback? onToggle;
  final VoidCallback onEnlarge;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final bool enabled;

  @override
  State<_ScannedTile> createState() => _ScannedTileState();
}

class _ScannedTileState extends State<_ScannedTile> {
  /// Vrai sous un pointeur. **C'est le seul signal fiable d'une souris** : un
  /// écran tactile n'entre jamais ici, et garde donc ses gestes tels quels.
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = widget.card;
    // **Le geste porte sur la tuile entière, nom compris.** Le nom est sous
    // l'image, et un doigt qui vise une vignette de trois par ligne tombe
    // volontiers dessus : n'écouter que l'image rendait la carte
    // indécochable une fois sur deux.
    return Semantics(
      label: card.label,
      selected: card.keep,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onToggle,
          onLongPress: widget.onEnlarge,
          // Sans cela, les espaces entre l'image et le nom ne repondent pas.
          behavior: HitTestBehavior.opaque,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      fit: StackFit.expand,
                      children: [
                        // Une carte couchée est redressée pour remplir sa
                        // case, exactement comme dans le classeur : sans
                        // cela, `cover` n'en montrerait qu'une bande
                        // centrale.
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
                        // Le témoin de l'état, et rien de plus : c'est la
                        // tuile entière qui écoute le doigt.
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
                        // **La loupe n'existe que sous un pointeur.** L'appui
                        // long n'a pas de sens au clic — maintenir le bouton
                        // une seconde, personne ne le fait spontanément. Le
                        // tactile n'entre jamais ici et garde l'appui long.
                        if (_hovered)
                          Positioned(
                            top: 28,
                            right: 4,
                            child: _Loupe(onPressed: widget.onEnlarge),
                          ),
                        // **Le compte se corrige sur place quand la tuile a
                        // la place** (#44), et seulement sur une carte gardée
                        // : compter les exemplaires d'une carte écartée n'a
                        // pas de sens. En bandeau sur le bas de l'image plutôt
                        // que sous le nom, pour ne pas toucher à la hauteur de
                        // la grille — ce qu'il couvre est le texte de règles,
                        // pas l'illustration ni le nom.
                        if (card.keep &&
                            constraints.maxWidth >= _stepperMinTileWidth)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: _Bandeau(
                              child: CopiesStepper(
                                quantity: card.quantity,
                                enabled: widget.enabled,
                                onIncrement: widget.onIncrement,
                                onDecrement: widget.onDecrement,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
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
      ),
    );
  }
}

/// Le bandeau sombre translucide qui porte le compte, en bas de l'image.
class _Bandeau extends StatelessWidget {
  const _Bandeau({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xAA101014),
    child: Center(child: child),
  );
}

/// La loupe du survol : un petit bouton rond, sombre, qui agrandit.
class _Loupe extends StatelessWidget {
  const _Loupe({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton.filled(
    tooltip: 'Voir en grand',
    icon: const Icon(Icons.zoom_in, size: 18),
    style: IconButton.styleFrom(
      backgroundColor: const Color(0xCC101014),
      foregroundColor: Colors.white,
      minimumSize: const Size(32, 32),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    onPressed: onPressed,
  );
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
