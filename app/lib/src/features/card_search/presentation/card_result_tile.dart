/// Une ligne de résultat de l'écran Ajouter : la carte, l'édition que « + »
/// enregistrera, et les gestes qui l'écrivent en collection.
///
/// **La ligne enregistre ce qu'elle affiche.** Sélecteur, illustration et prix
/// décrivent l'édition retenue — celle qu'on a désignée, ou à défaut celle que
/// la ligne propose (garde-fou §IV.8) : l'unique édition, sinon la plus
/// possédée. C'est ce qui permet de la confronter à la carte qu'on tient avant
/// d'appuyer.
///
/// **Invariants.** Après le premier `await` d'un geste, rien ne passe plus par
/// `ref` ni par `context`, seulement par [_Anchors] : le nom suivant se tape
/// pendant que l'ajout voyage, et peut démonter la ligne avant la fin. Et la
/// ligne se construit avec la clé de sa carte : son état retient une édition,
/// qu'une ligne réutilisée pour une autre carte lui transmettrait.
///
/// ```dart
/// CardResultTile(
///   key: ValueKey(hit.oracleId),
///   hit: hit,
///   soleEdition: sole[hit.oracleId],
///   onAdd: onAdd,
/// )
/// ```
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collection/data/collection_repository.dart';
import '../../collection/data/collection_views.dart';
import '../../printings/data/printing_repository.dart';
import '../../printings/domain/card_printing.dart';
import '../../printings/presentation/card_art_view.dart';
import '../../printings/presentation/printing_picker.dart';
import '../domain/card_hit.dart';
import 'owned_badge.dart';

/// Ce qui survit à une ligne de résultat : de quoi finir un geste commencé
/// sur elle.
///
/// **La ligne peut disparaître avant la fin du geste.** Le champ se vide à
/// l'appui, le nom suivant se tape pendant que l'ajout voyage, et la
/// notification reste quatre secondes : dans les deux cas, la liste peut être
/// remplacée et la ligne démontée. `ref` et `context` meurent avec elle —
/// l'ajout aboutissait alors sans confirmation, « Annuler » ne partait plus,
/// le choix d'édition ne s'ouvrait pas, tout cela sans rien dire.
///
/// **Invariant** : pris avant le premier `await`, et seul utilisé après. Le
/// navigateur sert d'ancrage aux feuilles qu'on ouvre ensuite : `Navigator.of`
/// reconnaît son propre contexte, et le thème comme les traductions sont posés
/// au-dessus de lui.
class _Anchors {
  _Anchors.of(BuildContext context)
    : container = ProviderScope.containerOf(context, listen: false),
      messenger = ScaffoldMessenger.of(context),
      navigator = Navigator.of(context);

  final ProviderContainer container;
  final ScaffoldMessengerState messenger;
  final NavigatorState navigator;
}

class CardResultTile extends ConsumerStatefulWidget {
  const CardResultTile({
    super.key,
    required this.hit,
    required this.onAdd,
    this.soleEdition,
  });

  final CardHit hit;

  /// L'unique édition de la carte, quand le catalogue n'en connaît qu'une.
  final CardPrinting? soleEdition;

  /// Prévient l'écran qu'un ajout part, pour qu'il libère le champ.
  final VoidCallback onAdd;

  @override
  ConsumerState<CardResultTile> createState() => _CardResultTileState();
}

class _CardResultTileState extends ConsumerState<CardResultTile> {
  bool _busy = false;

  /// Exemplaires possédés, tels que connus à l'affichage puis corrigés par les
  /// ajouts et retraits faits depuis cette carte. La liste de résultats n'étant
  /// pas rechargée après un ajout, sans cela le compteur resterait figé.
  int? _owned;

  /// Édition désignée par l'utilisateur lui-même. Le choix reste en place
  /// d'un ajout à l'autre : les exemplaires suivants de la même carte sont
  /// souvent de la même édition.
  PrintingChoice? _printing;

  /// Vrai dès que l'utilisateur a statué sur l'édition — y compris par « ne
  /// pas préciser », qui laisse [_printing] nul comme une ligne jamais
  /// examinée. Sans cette marque, la proposition reviendrait écraser le choix
  /// qu'on vient de faire.
  bool _decided = false;

  /// L'édition de cette carte dont on possède le plus d'exemplaires, si l'on
  /// en possède d'édition précisée.
  CardPrinting? _mostOwned;

  int get _quantity => _owned ?? widget.hit.owned;

  /// L'édition que « + » enregistrera, et que la ligne affiche.
  ///
  /// **Proposée tant qu'on n'a pas statué** (garde-fou §IV.8) : l'unique
  /// édition si le catalogue n'en connaît qu'une, sinon celle qu'on possède le
  /// plus — on range souvent le même tirage. Affichée avant l'appui, avec son
  /// illustration et son prix, elle se confronte à la carte qu'on tient ;
  /// appuyer sur « + » vaut alors choix. Rien à proposer, et préciser reste
  /// facultatif : la carte part à trier.
  PrintingChoice? get _retained {
    if (_decided) return _printing;
    final proposed = widget.soleEdition ?? _mostOwned;
    if (proposed == null) return null;
    // Une édition qui n'existe qu'en brillante l'est d'office : enregistrer
    // sa jumelle normale inventerait un exemplaire impossible.
    return PrintingChoice(
      proposed,
      isFoil: !proposed.hasNonfoil && proposed.hasFoil,
    );
  }

  @override
  void initState() {
    super.initState();
    // Seule une carte déjà possédée peut avoir une édition « la plus possédée ».
    if (widget.hit.owned > 0) unawaited(_loadMostOwned());
  }

  /// Demande au serveur l'édition la plus possédée de cette carte.
  ///
  /// `card_printings` trie déjà les éditions par exemplaires possédés, puis par
  /// sortie la plus récente — ce qui départage deux éditions à égalité : une
  /// ligne suffit. Des exemplaires tous sans édition ne comptent pour aucune,
  /// et ne proposent donc rien.
  Future<void> _loadMostOwned() async {
    final hit = widget.hit;
    try {
      final top = await ref
          .read(printingRepositoryProvider)
          .forCard(hit.oracleId, limit: 1, lang: hit.matchedLang);
      if (!mounted || top.isEmpty || top.first.owned == 0) return;
      setState(() => _mostOwned = top.first);
    } catch (_) {
      // Sans proposition, la ligne reste « Toutes éditions » — l'état d'avant,
      // jamais une perte. Rien ne justifie d'interrompre la saisie pour cela.
    }
  }

  /// Ouvre le sélecteur, retient l'édition choisie, et ajoute la carte.
  ///
  /// **Désigner une édition, c'est avoir la carte en main.** Exiger ensuite un
  /// appui sur « + » ajoutait un geste à un moment où la décision est déjà
  /// prise, et sur une saisie de deux mille cartes ce geste se paie deux mille
  /// fois. Le choix vaut donc validation.
  ///
  /// « Ne pas préciser » ne déclenche rien : c'est un réglage qu'on annule, pas
  /// une carte qu'on tient. Le bouton « + » reste pour les exemplaires suivants
  /// de la même édition.
  Future<void> _choosePrinting() async {
    final hit = widget.hit;
    final current = _retained;
    final chosen = await showPrintingPicker(
      context,
      oracleId: hit.oracleId,
      cardName: hit.matchedName,
      currentPrintId: current?.printing.printId,
      currentIsFoil: current?.isFoil ?? false,
      lang: hit.matchedLang,
      allowUnspecified: current != null,
    );
    if (chosen == null || !mounted) return;
    // Le sélecteur renvoie une édition vide pour « ne pas préciser » — `null`
    // signifiant déjà « refermé sans choisir ».
    final printing = chosen.isUnspecified ? null : chosen;
    setState(() {
      _printing = printing;
      _decided = true;
    });
    if (printing != null) await _add();
  }

  /// Rattache après coup les exemplaires ajoutés sans édition.
  ///
  /// C'est le rattrapage du geste rapide : on ajoute d'abord, la notification
  /// propose de préciser, un appui suffit. Le moment compte — c'est celui où
  /// l'on a encore la carte en main.
  ///
  /// Le sélecteur s'ouvre depuis le navigateur et non depuis cette ligne, que
  /// le nom suivant a pu démonter entre-temps — voir [_Anchors].
  Future<void> _specifyAfterAdd(
    _Anchors anchors,
    CardHit hit,
    int quantity,
  ) async {
    final chosen = await showPrintingPicker(
      anchors.navigator.context,
      oracleId: hit.oracleId,
      cardName: hit.matchedName,
    );
    if (chosen == null || chosen.isUnspecified) return;

    final messenger = anchors.messenger;
    try {
      await anchors.container
          .read(collectionRepositoryProvider)
          .setPrinting(
            hit.oracleId,
            fromPrintId: null,
            toPrintId: chosen.printing.printId,
            toFoil: chosen.isFoil,
            quantity: quantity,
          );
      refreshCollectionViews(anchors.container.invalidate);
      if (mounted) {
        setState(() {
          _printing = chosen;
          _decided = true;
        });
      }
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Édition enregistrée : ${chosen.printing.label}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Édition non enregistrée : $e')),
      );
    }
  }

  Future<void> _add() async {
    setState(() => _busy = true);
    widget.onAdd();
    // Tout ce qui sert après l'envoi est pris avant, voir [_Anchors].
    final anchors = _Anchors.of(context);
    final messenger = anchors.messenger;
    final hit = widget.hit;
    final printing = _retained;

    try {
      final total = await anchors.container
          .read(collectionRepositoryProvider)
          .add(
            hit.oracleId,
            printId: printing?.printing.printId,
            isFoil: printing?.isFoil ?? false,
          );
      refreshCollectionViews(anchors.container.invalidate);
      if (mounted) setState(() => _owned = total);
      // Sans cela les messages s'empilent et l'utilisateur lit un retour périmé :
      // en ajoutant trois cartes d'affilée, la dernière notification affichée
      // concernait encore la première carte.
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            printing == null
                ? '${hit.matchedName} ajoutée — vous en avez $total'
                // « brillante » et non « foil », comme partout ailleurs.
                : '${hit.matchedName} · ${printing.printing.setCode.toUpperCase()}${printing.isFoil ? " brillante" : ""} — vous en avez $total',
          ),
          duration: const Duration(seconds: 4),
          // Flutter fait persister indéfiniment toute notification porteuse
          // d'une action : la durée ci-dessus serait ignorée et le bandeau
          // attendrait un balayage, recouvrant entre-temps les commandes de
          // l'écran suivant. L'action est ici une commodité, pas une question
          // posée — elle n'a pas à retenir l'écran.
          persist: false,
          // Sans édition choisie, la notification sert de rampe d'accès vers le
          // sélecteur : c'est l'instant où l'on tient la carte, donc le seul où
          // l'on sait de quelle extension elle vient.
          action: printing == null
              ? SnackBarAction(
                  label: 'Préciser l\'édition',
                  onPressed: () => unawaited(_specifyAfterAdd(anchors, hit, 1)),
                )
              : SnackBarAction(
                  label: 'Annuler',
                  onPressed: () =>
                      unawaited(_undo(anchors, hit.oracleId, printing)),
                ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ajout impossible : $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Retire l'exemplaire qu'on vient d'ajouter, et le dit s'il échoue.
  ///
  /// Ne passe que par [_Anchors] : la ligne a pu être démontée depuis.
  Future<void> _undo(
    _Anchors anchors,
    String oracleId,
    PrintingChoice printing,
  ) async {
    try {
      // `remove` rend ce qu'il a retiré, non ce qui reste : le compte affiché
      // s'en déduit par soustraction. Zéro veut dire que la ligne n'existait
      // plus — un second appui, ou un retrait fait ailleurs entre-temps — et
      // le badge ne doit alors pas bouger.
      final removed = await anchors.container
          .read(collectionRepositoryProvider)
          .remove(
            oracleId,
            printId: printing.printing.printId,
            isFoil: printing.isFoil,
          );
      refreshCollectionViews(anchors.container.invalidate);
      if (mounted) {
        setState(() => _owned = (_quantity - removed).clamp(0, _quantity));
      }
    } catch (e) {
      anchors.messenger.showSnackBar(
        SnackBar(content: Text('Annulation impossible : $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final printing = _retained;

    // **La ligne décrit l'édition retenue, pas la carte en général.** Tant
    // qu'aucune n'est choisie, l'illustration est celle d'une impression de
    // référence et le prix celui de la moins chère — un plancher assumé. Une
    // fois l'édition désignée, les deux doivent la suivre : c'est l'illustration
    // qui permet de vérifier qu'on a bien désigné celle qu'on tient, et laisser
    // le prix plancher afficherait 1,55 € sur une édition qui en vaut 9.
    //
    // Le repli sur le prix plancher quand l'édition n'est pas cotée n'est pas
    // une approximation de confort : c'est exactement ce que la collection
    // comptera pour elle (`COALESCE(prix de l'édition, prix le moins cher)`).
    final art = printing?.printing.artCropUrl ?? hit.artUrl;
    final price =
        printing?.printing.priceFor(foil: printing.isFoil) ?? hit.priceEur;

    // **Maintenir montre la carte**, comme partout ailleurs. C'est l'écran où
    // l'on décide d'écrire une carte en collection, et la vignette de 56 × 42
    // ne permet pas de lever un doute entre deux noms voisins. L'édition
    // choisie voyage avec l'aperçu : une carte rééditée change parfois
    // d'illustration, et en montrer une autre ferait douter de sa saisie.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => showCardArt(
        context,
        oracleId: hit.oracleId,
        title: hit.matchedName,
        lang: hit.matchedLang,
        printId: printing?.printing.printId,
        foil: printing?.isFoil ?? false,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // L'illustration précède le nom : c'est elle qu'on reconnaît en
            // premier, et le seul repère qui sépare deux cartes homonymes.
            Padding(
              padding: const EdgeInsets.only(right: 12, top: 2),
              child: CardArtThumbnail(url: art),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hit.matchedName,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Le nom oracle n'est rappelé que s'il diffère : inutile de
                  // répéter la même chaîne sous une carte trouvée en anglais.
                  if (hit.isLocalized)
                    Text(
                      hit.name,
                      style: muted,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 6),
                  Text(
                    hit.typeLine ?? '',
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_quantity > 0) OwnedBadge(quantity: _quantity),
                      if (hit.legalPauper) const _FormatChip('Pauper'),
                      if (hit.legalModern) const _FormatChip('Modern'),
                      if (hit.legalCommander) const _FormatChip('Commander'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _PrintingSelector(choice: printing, onTap: _choosePrinting),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  price == null ? '—' : '${price.toStringAsFixed(2)} €',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                IconButton.filledTonal(
                  onPressed: _busy ? null : _add,
                  tooltip: 'Ajouter à ma collection',
                  icon: _busy
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Le choix d'édition, posé sur la tuile plutôt que caché derrière un menu.
///
/// Affiche « Toutes éditions » tant que rien n'est choisi : c'est la description
/// exacte de ce qui sera enregistré, là où « Choisir une édition » laisserait
/// croire à une étape obligatoire.
class _PrintingSelector extends StatelessWidget {
  const _PrintingSelector({required this.choice, required this.onTap});

  final PrintingChoice? choice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = choice != null;
    final color = chosen
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // **Un glyphe, un sens.** `Icons.style` est d'abord celui de
            // l'onglet Collection — « des cartes » —, visible en permanence
            // sous tous les écrans, et il servait aussi à dire « choisir
            // l'édition ». Les feuillets empilés disent ce dont il s'agit :
            // plusieurs impressions d'une même carte, dont on désigne une.
            // Le contraste vide/plein, lui, est conservé : c'est ce qui
            // distingue « à préciser » de « précisée ».
            Icon(
              chosen ? Icons.layers : Icons.layers_outlined,
              size: 15,
              color: color,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                chosen
                    ? '${choice!.printing.label}'
                          '${choice!.isFoil ? ' · brillante' : ''}'
                    : 'Toutes éditions',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: chosen ? FontWeight.w600 : null,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}

class _FormatChip extends StatelessWidget {
  const _FormatChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
