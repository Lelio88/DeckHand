/// Ligne d'édition d'une carte en attente d'ajout : ce qu'on possède, ou rien.
///
/// **Discrète à dessein.** Sur une liste de vingt cartes, un bouton par ligne
/// encombrerait ; c'est un texte qui se touche, effacé tant qu'aucune édition
/// n'est choisie, affirmé une fois qu'elle l'est.
///
/// **Le numéro de collection s'affiche avec l'extension.** L'édition étant
/// parfois retenue sans geste de l'utilisateur — quand le catalogue n'en connaît
/// qu'une —, il faut qu'un coup d'œil suffise à la confronter à ce qui est
/// imprimé en bas de la carte. C'est là que se joue la confirmation exigée par
/// le garde-fou §IV.8.
///
/// **La finition se règle ici**, sans ouvrir le sélecteur : c'est le seul choix
/// que le catalogue ne peut pas faire à notre place quand l'édition est unique,
/// et le seul qui distingue deux exemplaires par ailleurs identiques.
///
/// **Partagée entre l'étalement et la dictée**, pour que préciser une édition
/// soit le même geste partout où des cartes attendent d'entrer en collection.
/// La dictée s'en sert éteinte tant que le micro écoute — voir [enabled].
///
/// Usage canonique :
///
/// ```dart
/// EditionLine(
///   oracleId: item.card.oracleId,
///   cardName: item.card.matchedName,
///   lang: item.card.matchedLang,
///   printing: item.printing,
///   onChanged: (choice) => setState(() => item.printing = choice),
/// )
/// ```
library;

import 'package:flutter/material.dart';

import '../domain/card_printing.dart';
import 'printing_picker.dart';

class EditionLine extends StatelessWidget {
  const EditionLine({
    super.key,
    required this.oracleId,
    required this.cardName,
    required this.lang,
    required this.printing,
    required this.onChanged,
    this.enabled = true,
  });

  final String oracleId;
  final String cardName;

  /// Langue du nom trouvé : elle sert de préférence au sélecteur.
  final String? lang;

  /// Édition retenue, nulle tant que la carte part « à trier ».
  final PrintingChoice? printing;

  /// Reçoit le nouveau choix, ou `null` pour « ne pas préciser ».
  final ValueChanged<PrintingChoice?> onChanged;

  /// Faux rend la ligne inerte sans la cacher.
  ///
  /// **C'est la dictée qui l'exige.** Le micro y écoute en continu ; ouvrir une
  /// feuille modale pendant ce temps laisserait les cartes s'accumuler derrière
  /// elle, sans que l'on voie ce qui s'ajoute. La ligne reste donc visible —
  /// l'édition déjà retenue doit rester lisible pour être confrontée à la carte
  /// — mais elle ne se touche qu'une fois l'écoute arrêtée, au moment où l'on
  /// relit sa liste avant de l'enregistrer.
  final bool enabled;

  Future<void> _choose(BuildContext context) async {
    final chosen = await showPrintingPicker(
      context,
      oracleId: oracleId,
      cardName: cardName,
      currentPrintId: printing?.printing.printId,
      currentIsFoil: printing?.isFoil ?? false,
      // La langue du nom trouvé restreint la liste : on a reconnu la carte par
      // son nom français, c'est donc l'impression française qu'on tient.
      lang: lang,
      allowUnspecified: true,
    );
    if (chosen == null) return;
    onChanged(chosen.isUnspecified ? null : chosen);
  }

  /// Bascule normal / brillant sans quitter la liste.
  void _toggleFoil() {
    final current = printing;
    if (current == null) return;
    onChanged(PrintingChoice(current.printing, isFoil: !current.isFoil));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = printing;

    // Éteinte, la ligne garde son texte et perd sa couleur : elle informe
    // encore, elle n'appelle plus le geste.
    final Color color;
    if (!enabled) {
      color = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
    } else if (chosen == null) {
      color = theme.colorScheme.onSurfaceVariant;
    } else {
      color = theme.colorScheme.primary;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: InkWell(
            onTap: enabled ? () => _choose(context) : null,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    chosen == null ? Icons.layers_outlined : Icons.layers,
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      chosen == null
                          ? "Préciser l'édition"
                          : _label(chosen.printing),
                      style: theme.textTheme.labelSmall?.copyWith(color: color),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Sans édition retenue, la finition n'a rien à régler : le prix est
        // alors celui de l'impression la moins chère, toutes finitions
        // confondues.
        if (chosen != null && chosen.printing.hasFoil) ...[
          const SizedBox(width: 8),
          _FoilChip(
            value: chosen.isFoil,
            // Une édition qui n'existe qu'en brillante ne se débascule pas.
            onTap: enabled && chosen.printing.hasNonfoil ? _toggleFoil : null,
          ),
        ],
      ],
    );
  }

  static String _label(CardPrinting printing) {
    final number = printing.collectorNumber;
    return [
      printing.setCode.toUpperCase(),
      if (number != null) '#$number',
    ].join(' ');
  }
}

/// Marqueur de finition brillante, à même la liste.
///
/// Assez petit pour ne pas concurrencer la case à cocher et les quantités, mais
/// touchable : c'est un réglage qu'on prend au vol, en regardant la carte.
class _FoilChip extends StatelessWidget {
  const _FoilChip({required this.value, required this.onTap});

  final bool value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = value
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return Tooltip(
      message: value ? 'Exemplaire brillant' : 'Exemplaire normal',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: value ? theme.colorScheme.primaryContainer : null,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: value
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                value ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                size: 12,
                color: color,
              ),
              const SizedBox(width: 4),
              // **« Brillant » et non « Foil ».** Le classeur nomme la même
              // finition en français partout — filtre « Brillantes », bascule
              // « Normale / Brillante », actions « un exemplaire brillant ».
              // Deux mots pour la facette qui double le prix ne disaient pas
              // qu'il s'agissait de la même. Le mot est au masculin ici :
              // il qualifie l'exemplaire, comme le dit l'infobulle.
              Text(
                'Brillant',
                style: theme.textTheme.labelSmall?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
