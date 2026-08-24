/// Déclarer ce que l'on paie un booster.
///
/// **Pourquoi l'utilisateur est la source, et pas une table.** L'indicateur
/// « en boosters achetés » répond à « combien **j'aurais** dépensé ». Aucune
/// source ne publie ce prix, et il n'en existe pas un seul : relevé le même
/// jour, un booster Pokémon Méga-Évolution vaut 4,99 € chez une enseigne et
/// 9,90 € chez une autre. Un nombre inscrit dans le code serait faux pour à peu
/// près tout le monde, et faux sans le dire.
///
/// **Le repère reste affiché**, et c'est ce qui rend le réglage compréhensible :
/// sans lui, un champ vide demanderait un prix sans donner l'ordre de grandeur,
/// et l'on ne saurait pas non plus ce que l'application utilisait jusque-là.
///
/// **Vider le champ n'est pas saisir zéro.** Vider rend la main au repère ;
/// zéro est une réponse — « je n'achète pas de boosters » — et l'indicateur
/// affiche alors zéro euro. Confondre les deux empêcherait de revenir en
/// arrière autrement qu'en retapant le repère de mémoire.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../collection/domain/booster_size.dart';

/// Résultat d'un passage dans la boîte.
///
/// **Trois issues, et `null` n'en est pas une.** Fermer sans valider rend
/// `null` et ne touche à rien ; les deux autres cas sont des décisions à
/// enregistrer, et l'une d'elles est justement « plus de prix à moi ».
class BoosterPriceChoice {
  const BoosterPriceChoice(this.priceEur);

  /// Le prix retenu, ou `null` pour revenir au prix de repère.
  final double? priceEur;
}

/// Ouvre la boîte et rend la décision, ou `null` si elle a été refermée.
Future<BoosterPriceChoice?> showBoosterPriceDialog(
  BuildContext context, {
  required String gameLabel,
  required BoosterFacts facts,
  required double? current,
}) {
  return showDialog<BoosterPriceChoice>(
    context: context,
    builder: (_) => _BoosterPriceDialog(
      gameLabel: gameLabel,
      facts: facts,
      current: current,
    ),
  );
}

class _BoosterPriceDialog extends StatefulWidget {
  const _BoosterPriceDialog({
    required this.gameLabel,
    required this.facts,
    required this.current,
  });

  final String gameLabel;
  final BoosterFacts facts;

  /// Le prix déclaré, ou `null` si l'utilisateur n'a rien dit et que le repère
  /// s'applique.
  final double? current;

  @override
  State<_BoosterPriceDialog> createState() => _BoosterPriceDialogState();
}

class _BoosterPriceDialogState extends State<_BoosterPriceDialog> {
  late final TextEditingController _saisie = TextEditingController(
    // Le champ part **vide** quand rien n'a été déclaré : y écrire le repère
    // ferait passer une valeur d'usine pour une réponse de l'utilisateur, et
    // la première validation la graverait sans qu'il l'ait choisie.
    text: widget.current == null
        ? ''
        : widget.current!.toStringAsFixed(2).replaceAll('.', ','),
  );

  String? _erreur;

  @override
  void dispose() {
    _saisie.dispose();
    super.dispose();
  }

  void _valider() {
    final texte = _saisie.text.trim();
    if (texte.isEmpty) {
      Navigator.of(context).pop(const BoosterPriceChoice(null));
      return;
    }
    final prix = parseBoosterPrice(texte);
    if (prix == null) {
      setState(() => _erreur = 'Un prix, en euros — par exemple 6,90');
      return;
    }
    Navigator.of(context).pop(BoosterPriceChoice(prix));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repere = widget.facts.referencePriceEur.toStringAsFixed(2);

    return AlertDialog(
      title: const Text('Le prix que vous payez'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Un booster ${widget.gameLabel} contient '
            '${widget.facts.cards} cartes.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _saisie,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // Laisser passer la virgule ET le point : le clavier décimal
            // d'Android n'offre que l'un des deux selon la langue du système.
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            decoration: InputDecoration(
              labelText: 'Prix d’un booster',
              suffixText: '€',
              hintText: repere.replaceAll('.', ','),
              errorText: _erreur,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _valider(),
          ),
          const SizedBox(height: 12),
          Text(
            widget.current == null
                ? 'Sans réponse, DeckHand compte '
                      '${repere.replaceAll('.', ',')} € — '
                      '${widget.facts.source}.'
                : 'Videz le champ pour revenir au repère : '
                      '${repere.replaceAll('.', ',')} € '
                      '(${widget.facts.source}).',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _valider, child: const Text('Enregistrer')),
      ],
    );
  }
}
