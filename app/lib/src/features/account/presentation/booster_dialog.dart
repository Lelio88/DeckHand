/// Déclarer ce qu'un booster contient et ce qu'on le paie.
///
/// **Pourquoi l'utilisateur est la source, et pas une table.** Les deux
/// indicateurs en boosters répondent à « combien **j'aurais** ouvert » et
/// « combien **j'aurais** dépensé ». Aucune source ne publie ces nombres au
/// singulier : relevé le même jour, un booster Pokémon Méga-Évolution vaut
/// 4,99 € chez une enseigne et 9,90 € chez une autre ; et un même jeu vend
/// plusieurs produits — Play Booster à 14 cartes, Collector à 15, Set à 12.
/// Un nombre inscrit dans le code serait faux pour à peu près tout le monde, et
/// faux sans le dire.
///
/// **Les deux réglages tiennent dans une seule boîte** parce qu'ils décrivent un
/// seul objet : le produit qu'on achète. Les séparer obligerait à ouvrir deux
/// fois pour déclarer « j'ouvre des Collector Boosters à 15 cartes, payés
/// 22 € », qui est une seule décision.
///
/// **Le repère reste affiché**, et c'est ce qui rend le réglage compréhensible :
/// sans lui, un champ vide demanderait une valeur sans donner l'ordre de
/// grandeur, et l'on ne saurait pas non plus ce que l'application utilisait
/// jusque-là.
///
/// **Vider un champ n'est pas saisir zéro.** Vider rend la main au repère ; zéro
/// est une réponse pour le prix — « je n'achète pas de boosters » — et
/// l'indicateur affiche alors zéro euro. Confondre les deux empêcherait de
/// revenir en arrière autrement qu'en retapant le repère de mémoire. **Pour la
/// taille, zéro est refusé** : aucun produit ne contient zéro carte, et les deux
/// indicateurs divisent par ce nombre.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../collection/domain/booster_size.dart';

/// Résultat d'un passage dans la boîte.
///
/// **Trois issues par champ, et `null` en haut n'en est pas une.** Fermer sans
/// valider rend `null` et ne touche à rien ; sinon chaque champ vaut soit une
/// valeur déclarée, soit `null` pour « rendez la main au repère ».
class BoosterChoice {
  const BoosterChoice({required this.cards, required this.priceEur});

  /// Cartes par booster, ou `null` pour revenir au repère.
  final int? cards;

  /// Le prix retenu, ou `null` pour revenir au prix de repère.
  final double? priceEur;
}

/// Ouvre la boîte et rend la décision, ou `null` si elle a été refermée.
Future<BoosterChoice?> showBoosterDialog(
  BuildContext context, {
  required String gameLabel,
  required BoosterFacts facts,
  required int? currentCards,
  required double? currentPrice,
}) {
  return showDialog<BoosterChoice>(
    context: context,
    builder: (_) => _BoosterDialog(
      gameLabel: gameLabel,
      facts: facts,
      currentCards: currentCards,
      currentPrice: currentPrice,
    ),
  );
}

class _BoosterDialog extends StatefulWidget {
  const _BoosterDialog({
    required this.gameLabel,
    required this.facts,
    required this.currentCards,
    required this.currentPrice,
  });

  final String gameLabel;
  final BoosterFacts facts;

  /// La taille déclarée, ou `null` si l'utilisateur n'a rien dit et que le
  /// repère s'applique.
  final int? currentCards;

  /// Le prix déclaré, ou `null` — même règle.
  final double? currentPrice;

  @override
  State<_BoosterDialog> createState() => _BoosterDialogState();
}

class _BoosterDialogState extends State<_BoosterDialog> {
  // Les champs partent **vides** quand rien n'a été déclaré : y écrire le repère
  // ferait passer une valeur d'usine pour une réponse de l'utilisateur, et la
  // première validation la graverait sans qu'il l'ait choisie.
  late final TextEditingController _taille = TextEditingController(
    text: widget.currentCards?.toString() ?? '',
  );
  late final TextEditingController _prix = TextEditingController(
    text: widget.currentPrice == null
        ? ''
        : widget.currentPrice!.toStringAsFixed(2).replaceAll('.', ','),
  );

  String? _erreurTaille;
  String? _erreurPrix;

  @override
  void dispose() {
    _taille.dispose();
    _prix.dispose();
    super.dispose();
  }

  void _valider() {
    final texteTaille = _taille.text.trim();
    final textePrix = _prix.text.trim();

    // Les deux champs sont éprouvés avant toute sortie : valider en s'arrêtant
    // au premier fautif n'afficherait qu'une erreur sur deux, et la seconde
    // n'apparaîtrait qu'après correction de la première.
    final cards = texteTaille.isEmpty ? null : parseBoosterSize(texteTaille);
    final prix = textePrix.isEmpty ? null : parseBoosterPrice(textePrix);
    final tailleFautive = texteTaille.isNotEmpty && cards == null;
    final prixFautif = textePrix.isNotEmpty && prix == null;

    if (tailleFautive || prixFautif) {
      setState(() {
        _erreurTaille = tailleFautive
            ? 'Un nombre de cartes, au moins une'
            : null;
        _erreurPrix = prixFautif ? 'Un prix, en euros — par exemple 6,90' : null;
      });
      return;
    }

    Navigator.of(context).pop(BoosterChoice(cards: cards, priceEur: prix));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repereTaille = '${widget.facts.cards}';
    final reperePrix = widget.facts.referencePriceEur
        .toStringAsFixed(2)
        .replaceAll('.', ',');
    final legende = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: const Text('Vos boosters'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ce que vous ouvrez en ${widget.gameLabel}, et ce que vous le '
              'payez.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('booster-cartes'),
              controller: _taille,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Cartes par booster',
                hintText: repereTaille,
                errorText: _erreurTaille,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.currentCards == null
                  ? 'Sans réponse, DeckHand compte $repereTaille cartes — '
                        'le format principal du jeu.'
                  : 'Videz le champ pour revenir au repère : '
                        '$repereTaille cartes.',
              style: legende,
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('booster-prix'),
              controller: _prix,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              // Laisser passer la virgule ET le point : le clavier décimal
              // d'Android n'offre que l'un des deux selon la langue du système.
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                labelText: 'Prix d’un booster',
                suffixText: '€',
                hintText: reperePrix,
                errorText: _erreurPrix,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _valider(),
            ),
            const SizedBox(height: 8),
            Text(
              widget.currentPrice == null
                  ? 'Sans réponse, DeckHand compte $reperePrix € — '
                        '${widget.facts.source}.'
                  : 'Videz le champ pour revenir au repère : $reperePrix € '
                        '(${widget.facts.source}).',
              style: legende,
            ),
          ],
        ),
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
