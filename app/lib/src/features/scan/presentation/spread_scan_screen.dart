/// Scan d'un étalement : plusieurs cartes sur une même photo.
///
/// Distinct du scan d'une carte parce que le geste l'est : on ne cherche pas
/// *quelle* carte on tient, mais *lesquelles* sont là. Le résultat n'est donc
/// pas une proposition à départager mais une liste à valider, où l'on décoche ce
/// qui a été mal lu et où l'on ajuste les quantités.
///
/// **Aucune carte n'entre en collection sans validation** — garde-fou §IV.8. Il
/// pèse davantage ici qu'ailleurs : valider vingt cartes d'un geste rend une
/// erreur d'autant plus facile à laisser passer, et une carte saisie à tort
/// fausse ensuite toutes les suggestions de decks.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../config/selected_game.dart';
import '../../../diagnostics/diagnostics.dart';
import '../../card_search/domain/card_hit.dart';
import '../../card_search/presentation/card_picker.dart';
import '../../card_search/presentation/owned_badge.dart';
import '../../collection/data/collection_repository.dart';
import '../../printings/data/printing_repository.dart';
import '../../printings/domain/card_printing.dart';
import '../../printings/presentation/card_art_view.dart';
import '../../printings/presentation/printing_picker.dart';
import '../application/scan_service.dart';
import '../data/photo_source.dart';

/// Une carte repérée sur la photo, telle que l'utilisateur peut l'amender.
class _Spotted {
  _Spotted(SpreadFind find, {this.keep = true})
    : card = find.card,
      quantity = find.copies,
      fromPhoto = true;

  /// Une carte que la photo n'a pas vue, ajoutée à la main.
  ///
  /// Elle arrive **cochée** : on ne la désigne pas par accident, on est allé la
  /// chercher dans le catalogue. C'est l'inverse exact du recours par
  /// illustration, qui propose sans qu'on ait rien demandé.
  _Spotted.manual(this.card) : quantity = 1, keep = true, fromPhoto = false;

  /// La carte retenue. **Remplaçable** : une ligne mal lue se corrige sur
  /// place, faute de quoi la seule issue était de la décocher et de ressaisir
  /// la carte ailleurs — c'est-à-dire de perdre le geste.
  CardHit card;

  /// Vrai quand la ligne vient de la photo, faux quand elle a été ajoutée à la
  /// main.
  ///
  /// **Le compteur d'en-tête en dépend.** Il répond à « la photo a-t-elle tout
  /// vu ? » ; une carte que l'utilisateur vient d'ajouter lui-même gonflerait
  /// ce nombre et lui ferait dire le contraire de ce qu'il sert à dire.
  final bool fromPhoto;

  bool keep;

  /// Quantité proposée, pré-remplie par le nombre d'exemplaires vus sur la
  /// photo. Reste modifiable : la reconnaissance propose, l'utilisateur décide.
  int quantity;

  /// Édition possédée, quand elle est connue.
  ///
  /// **Facultative, et elle doit le rester.** L'intérêt de l'étalement est de
  /// saisir vingt cartes d'un geste ; imposer un choix d'édition par carte
  /// annulerait ce gain. Sans elle, la carte est valorisée au prix le moins
  /// cher connu — un plancher assumé, jamais une invention.
  ///
  /// Deviner cette édition à partir de l'illustration a été mesuré puis
  /// écarté : la géométrie d'une carte n'est reconstructible qu'à ±13 %, et
  /// au-delà de 5 % une carte sur trois recevrait la mauvaise édition. Un
  /// geste juste vaut mieux qu'un calcul faux.
  ///
  /// Elle est en revanche remplie d'office quand la carte n'a **qu'une seule**
  /// édition : il n'y a alors rien à deviner, et rien à choisir. C'est le cas
  /// de quatre cartes du catalogue sur dix.
  PrintingChoice? printing;

  /// Remplace la carte, et **oublie l'édition** retenue pour la précédente.
  ///
  /// Les deux gestes ne se séparent pas : une édition désigne un tirage d'une
  /// carte donnée, et la garder après un remplacement ferait enregistrer
  /// l'extension d'une carte sous l'identité d'une autre — une ligne fausse
  /// que rien à l'écran ne signalerait. La quantité, elle, survit : c'est le
  /// nombre de cartons posés sur la table, et corriger un nom ne les fait pas
  /// disparaître.
  void replaceWith(CardHit replacement) {
    card = replacement;
    printing = null;
  }
}

class SpreadScanScreen extends ConsumerStatefulWidget {
  const SpreadScanScreen({super.key});

  @override
  ConsumerState<SpreadScanScreen> createState() => _SpreadScanScreenState();
}

class _SpreadScanScreenState extends ConsumerState<SpreadScanScreen> {
  final List<_Spotted> _spotted = [];
  bool _busy = false;
  bool _saving = false;
  bool _scanned = false;

  /// La photo n'a rien donné — le seul cas où il n'y a rien d'autre à montrer.
  String? _error;

  /// Des noms ont été lus, aucun ne correspond au catalogue.
  ///
  /// Distingue le seul cas où « rapprochez-vous » est un mauvais conseil : la
  /// lecture a fonctionné, c'est le catalogue interrogé qui ne contient pas ces
  /// cartes. Le geste utile est alors de vérifier le jeu saisi, pas la photo.
  bool _readButUnmatched = false;

  /// Ces cartes viennent du recours par illustration, pas d'un nom lu.
  bool _fromArtwork = false;

  /// Le recours a hesite : il propose, il n'affirme pas.
  bool _uncertain = false;

  /// L'enregistrement a échoué, alors que la liste, elle, est intacte.
  ///
  /// **Deux pannes, deux champs.** Elles partageaient `_error`, si bien qu'une
  /// coupure réseau au moment d'« Ajouter » remplaçait la liste par un message
  /// plein écran : dix-sept lignes mesurées sur une photo réelle, leurs cases
  /// cochées, leurs quantités et les éditions choisies une par une
  /// disparaissaient d'un coup, et rien ne les ramenait. La dictée, elle,
  /// gardait déjà les siennes pour la même erreur — c'est son bandeau qu'on
  /// imite ici.
  String? _saveError;

  Future<void> _capture(ImageSource source) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final theme = Theme.of(context);
      final photo = await ref
          .read(photoSourceProvider)
          .capture(
            source: source,
            toolbarColor: theme.colorScheme.surfaceContainerHigh,
            toolbarWidgetColor: theme.colorScheme.onSurface,
            webContext: context,
          );
      if (photo == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final service = await ref.read(scanServiceProvider.future);
      final found = await service.recognisePhoto(
        photo.bytes,
        photoPath: photo.path,
      );

      if (!mounted) return;
      setState(() {
        _spotted
          ..clear()
          ..addAll(
            found.cards.map(
              // **Une carte suggérée arrive décochée.** Quand le recours par
              // illustration hésite, il propose plusieurs candidats dont un
              // seul est le bon : les cocher d'office ferait entrer les autres
              // en collection au premier « Ajouter ». « Affirmer à tort coûte
              // plus cher que suggérer » (§IV.8).
              (find) => _Spotted(find, keep: found.isConfident),
            ),
          );
        _readButUnmatched = found.readButUnmatched;
        _fromArtwork = found.fromArtwork;
        _uncertain = found.fromArtwork && !found.isConfident;
        _scanned = true;
      });
      await _fillSoleEditions();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Précise d'office les cartes qui n'admettent qu'une seule édition.
  ///
  /// **Ce n'est pas une devinette** : quand le catalogue ne connaît qu'une
  /// édition, la désigner n'apporte aucune information que la carte elle-même
  /// ne porte déjà. Demander le geste quand même revenait à faire ouvrir une
  /// liste d'un seul élément, vingt fois de suite.
  ///
  /// L'échec est sans conséquence sur le scan : les lignes restent affichées et
  /// l'édition se précise à la main, comme avant. Le journal de mesure en garde
  /// trace pour qui enquête.
  ///
  /// [targets] restreint le travail aux lignes qui viennent de changer — une
  /// carte remplacée, une carte ajoutée à la main. Sans lui, chaque correction
  /// relancerait la requête pour les seize autres lignes, dont l'édition est
  /// déjà réglée.
  Future<void> _fillSoleEditions([Iterable<_Spotted>? targets]) async {
    final concerned = (targets ?? _spotted).toList(growable: false);
    if (concerned.isEmpty) return;
    final repository = ref.read(printingRepositoryProvider);

    // Groupé par langue du nom trouvé : au plus deux requêtes, une par langue
    // présente sur la photo, plutôt qu'une par carte.
    final byLang = <String, Set<String>>{};
    for (final spotted in concerned) {
      byLang
          .putIfAbsent(spotted.card.matchedLang, () => <String>{})
          .add(spotted.card.oracleId);
    }

    final sole = <String, CardPrinting>{};
    try {
      for (final entry in byLang.entries) {
        sole.addAll(
          await repository.soleEditions(entry.value, lang: entry.key),
        );
      }
    } catch (e) {
      diagnose('sole_editions_failed', {'error': '$e'});
      return;
    }

    if (!mounted || sole.isEmpty) return;
    setState(() {
      for (final spotted in concerned) {
        final only = sole[spotted.card.oracleId];
        if (only == null) continue;
        // Une édition qui n'existe qu'en brillante l'est d'office : enregistrer
        // sa jumelle normale reviendrait à inventer un exemplaire impossible.
        spotted.printing ??= PrintingChoice(
          only,
          isFoil: !only.hasNonfoil && only.hasFoil,
        );
      }
    });
  }

  /// Remplace une ligne mal reconnue par la bonne carte.
  ///
  /// **Ce que la décocher ne remplaçait pas.** Une carte mal lue n'est pas une
  /// carte absente : elle est sur la table, elle a été photographiée, et jusqu'ici
  /// la seule issue était de la décocher puis d'aller la saisir au clavier
  /// ailleurs — c'est-à-dire de payer deux fois le même geste, et le plus
  /// souvent de l'oublier.
  ///
  /// Le nom lu pré-remplit la recherche : quand la lecture n'a raté qu'une
  /// lettre, la bonne carte est déjà à l'écran quand la feuille s'ouvre.
  Future<void> _replace(_Spotted item) async {
    final chosen = await showCardPicker(
      context,
      title: 'Remplacer par',
      initialQuery: item.card.matchedName,
    );
    if (chosen == null || !mounted) return;
    setState(() => item.replaceWith(chosen));
    await _fillSoleEditions([item]);
  }

  /// Ajoute une carte que la photo n'a pas vue.
  ///
  /// **Le pendant du remplacement, et le seul autre défaut qu'on peut corriger
  /// sans reprendre la photo.** Le compteur d'en-tête annonce « seize trouvées »
  /// quand dix-sept sont sur la table ; rephotographier pour une carte oblige à
  /// tout revalider, et l'écrire ailleurs suppose de s'en souvenir.
  ///
  /// La ligne ajoutée **ne compte pas** dans « trouvées sur la photo » : ce
  /// nombre est le témoin de ce que la reconnaissance a vu, et le gonfler
  /// reviendrait à effacer l'écart qu'il sert justement à montrer.
  Future<void> _addManually() async {
    final chosen = await showCardPicker(context, title: 'Ajouter une carte');
    if (chosen == null || !mounted) return;
    final added = _Spotted.manual(chosen);
    setState(() => _spotted.add(added));
    await _fillSoleEditions([added]);
  }

  Future<void> _saveAll() async {
    final kept = _spotted.where((s) => s.keep).toList();
    if (kept.isEmpty) return;

    setState(() {
      _saving = true;
      _saveError = null;
    });
    final repository = ref.read(collectionRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    var added = 0;
    try {
      for (final item in kept) {
        await repository.add(
          item.card.oracleId,
          quantity: item.quantity,
          printId: item.printing?.printing.printId,
          isFoil: item.printing?.isFoil ?? false,
        );
        added += item.quantity;
      }
      ref.invalidate(collectionProvider);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '$added carte${added > 1 ? 's' : ''} ajoutée'
            '${added > 1 ? 's' : ''}',
          ),
        ),
      );
      navigator.pop();
    } catch (e) {
      // La liste reste : `added` dit combien de cartes sont déjà passées, et
      // ré-appuyer sur « Ajouter » les compterait deux fois. Décocher ce qui
      // est enregistré est le seul geste que l'utilisateur puisse faire à
      // notre place — encore faut-il qu'il voie encore ses lignes.
      if (mounted) {
        setState(() => _saveError = 'Enregistrement impossible : $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keptCount = _spotted
        .where((s) => s.keep)
        .fold<int>(0, (sum, s) => sum + s.quantity);
    // L'en-tête témoigne de la photo, le bouton d'ajout de la sélection : les
    // lignes ajoutées à la main appartiennent au second, jamais au premier.
    final fromPhoto = _spotted.where((s) => s.fromPhoto).toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: const Text('Photographier des cartes')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                _Header(
                  cards: fromPhoto.fold<int>(0, (n, s) => n + s.quantity),
                  distinct: fromPhoto.length,
                  manual: _spotted.length - fromPhoto.length,
                  scanned: _scanned,
                ),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                if (_saveError != null) _SaveError(message: _saveError!),
                Expanded(child: _results(theme)),
                _Actions(
                  busy: _busy,
                  saving: _saving,
                  keptCount: keptCount,
                  onCapture: _capture,
                  onSave: _saveAll,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _results(ThemeData theme) {
    if (_error != null) {
      return _Note(icon: Icons.error_outline, text: _error!);
    }
    if (!_scanned) {
      return const _Note(
        icon: Icons.grid_view,
        text:
            'Photographiez une carte, ou étalez-en plusieurs en laissant un '
            'jour entre elles — un demi-centimètre suffit.',
      );
    }
    if (_spotted.isEmpty) {
      // **Deux causes opposées, deux gestes opposés.** Confondre les deux
      // envoyait nettoyer des protège-cartes quand la lecture était parfaite.
      if (_readButUnmatched) {
        final game = ref.watch(selectedGameProvider);
        return _Note(
          icon: Icons.translate,
          text: game == Game.riftbound
              ? 'Des noms ont bien été lus, mais aucun ne figure au catalogue '
                    'Riftbound — qui n\'existe qu\'en anglais. Une carte '
                    'française ne peut pas être reconnue par son nom : '
                    'photographiez-la seule, son illustration la trahira.'
              : 'Des noms ont bien été lus, mais aucun ne correspond au '
                    'catalogue ${game.label}. Vérifiez le jeu sélectionné.',
        );
      }
      return const _Note(
        icon: Icons.search_off,
        text:
            'Aucun nom n\'a pu être lu. Rapprochez-vous, '
            'ou évitez les reflets sur les protège-cartes.',
      );
    }

    return Column(
      children: [
        // **Dire d'où vient la carte.** Un nom lu et une illustration
        // rapprochée n'ont pas la même assise : le premier se vérifie d'un
        // coup d'œil sur le carton, le second repose sur une ressemblance.
        // L'utilisateur juge mieux quand il sait laquelle des deux voies a
        // parlé.
        if (_fromArtwork)
          _Note(
            icon: _uncertain ? Icons.help_outline : Icons.image_search,
            text: _uncertain
                ? 'Aucun nom n\'a pu être lu. Voici les cartes dont '
                      'l\'illustration ressemble le plus — cochez la vôtre.'
                : 'Aucun nom n\'a pu être lu : cette carte a été reconnue à '
                      'son illustration.',
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            // Une ligne de plus que de cartes : « ajouter une carte » vit au
            // bas de la liste, là où l'on arrive après avoir tout relu et où
            // l'on constate qu'il en manque une.
            itemCount: _spotted.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) => index == _spotted.length
                ? _AddByHand(onTap: _saving ? null : _addManually)
                : _SpottedTile(
                    item: _spotted[index],
                    onChanged: () => setState(() {}),
                    onCorrect: () => _replace(_spotted[index]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _SpottedTile extends StatelessWidget {
  const _SpottedTile({
    required this.item,
    required this.onChanged,
    required this.onCorrect,
  });

  final _Spotted item;
  final VoidCallback onChanged;

  /// Ouvre la correction de la carte elle-même — pas de son édition.
  final VoidCallback onCorrect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = item.card;

    // **Voir avant de valider en bloc.** Un étalement propose des cartes lues
    // de loin, parfois de travers ; l'illustration est ce qui permet de
    // reconnaître la sienne d'un coup d'œil, là où un nom demande à être lu et
    // comparé. Le geste est celui du sélecteur d'édition : maintenir la ligne.
    return GestureDetector(
      onLongPress: () => showCardArt(
        context,
        oracleId: card.oracleId,
        title: card.matchedName,
        lang: card.matchedLang,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: item.keep
              ? theme.colorScheme.surfaceContainerHigh
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Checkbox(
              value: item.keep,
              onChanged: (v) {
                item.keep = v ?? false;
                onChanged();
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // **Le nom est ce qu'on corrige**, donc c'est lui qu'on
                      // touche. Un bouton de plus sur une ligne qui en porte
                      // déjà quatre (cocher, moins, plus, édition) se serait
                      // disputé la place avec eux ; le crayon dit qu'il y a
                      // quelque chose à toucher sans en prendre.
                      // `Expanded`, non `Flexible` : sous contrainte lâche, une
                      // `Row` à taille minimale réclame sa largeur naturelle et
                      // déborde de ce qui manque — 1,6 px ici, mesurés. Une
                      // largeur ferme oblige le nom à s'élider, ce qu'il sait
                      // faire.
                      Expanded(
                        child: InkWell(
                          onTap: onCorrect,
                          borderRadius: BorderRadius.circular(6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  card.matchedName,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: item.keep
                                        ? null
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.edit_outlined,
                                size: 13,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // **Ce qu'on possède déjà, avant d'en ajouter.** Sans ce
                      // chiffre, une carte en main ne dit pas si elle complète
                      // un jeu de quatre ou si elle en ouvre un — et une
                      // collection se saisit en plusieurs séances.
                      //
                      // **Sur la ligne du nom, en forme dense, et les deux
                      // décisions sont mesurées.** La pastille pleine prend
                      // 117,5 px quand cette ligne n'en laisse que 106 sur un
                      // écran de 320 : elle débordait de 22 px. La ligne
                      // d'édition, essayée ensuite, débordait encore de 5,6 —
                      // et c'était de toute façon le mauvais endroit : sur un
                      // écran étroit, quelque chose doit céder, et un nom
                      // tronqué reste identifiable là où « MS… » ne permet plus
                      // de confronter le numéro imprimé (§IV.8).
                      if (card.owned > 0) ...[
                        const SizedBox(width: 8),
                        // **Ni `Expanded` ni `Flexible` ici, et l'aperçu l'a
                        // montré** : deux enfants flexibles se partagent
                        // l'espace libre à parts égales, si bien que le nom
                        // était amputé à « Archi… » avec la moitié de la ligne
                        // vide à sa droite. Le compte fait quelques dizaines de
                        // pixels et n'a rien à négocier ; c'est au nom, en
                        // `Expanded`, de prendre tout le reste et de s'élider
                        // quand il le faut.
                        OwnedBadge(quantity: card.owned, dense: true),
                      ],
                    ],
                  ),
                  if (card.isLocalized)
                    Text(
                      card.name,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 4),
                  _EditionLine(item: item, onChanged: onChanged),
                ],
              ),
            ),
            // Les exemplaires identiques ne sont pas comptés : la lecture des noms
            // ne distingue pas deux cartes côte à côte d'un nom lu deux fois. La
            // quantité s'ajuste donc à la main.
            IconButton(
              // **Resserrés, pour rendre au nom la place que le compte prend.**
              // Deux boutons pleine taille et leur nombre occupaient 116 dp des
              // 360 d'un téléphone étroit ; l'aperçu montrait « Levée de b… »
              // là où le nom tient largement. La cible tactile reste au-dessus
              // des 40 dp que réclame Material.
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Un de moins',
              onPressed: item.quantity > 1
                  ? () {
                      item.quantity--;
                      onChanged();
                    }
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '${item.quantity}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Un de plus',
              onPressed: () {
                item.quantity++;
                onChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Dernière ligne de la liste : la carte que la photo n'a pas vue.
///
/// **Elle ne dit pas « Ajouter », et c'est un test qui l'a montré.** Le mot est
/// déjà pris par le bouton d'enregistrement — « Ajouter (17) » —, où il désigne
/// l'écriture en collection ; le porter aussi sur une ligne qui ne fait que
/// compléter la liste donnait deux gestes de portée très différente sous un
/// verbe unique. « Saisir » est le mot que le projet emploie déjà pour la
/// frappe au clavier.
///
/// **Pourquoi au bas de la liste et non dans la barre d'actions.** La barre
/// porte les gestes qui engagent la photo entière — reprendre, importer,
/// enregistrer ; celui-ci corrige la liste, comme les cases à cocher et les
/// quantités au-dessus. Il vit donc au même endroit qu'elles, et on l'atteint
/// après avoir tout relu, c'est-à-dire au moment précis où l'on s'aperçoit
/// qu'il en manque une.
///
/// **Absente quand la photo n'a rien trouvé, à dessein.** L'écran montre alors
/// un conseil de prise de vue, et le geste utile est de reprendre la photo :
/// saisir dix-sept cartes une à une n'est pas ce que cet écran sert à faire —
/// l'écran de saisie au clavier est là pour ça.
class _AddByHand extends StatelessWidget {
  const _AddByHand({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Saisir une carte oubliée'),
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.busy,
    required this.saving,
    required this.keptCount,
    required this.onCapture,
    required this.onSave,
  });

  final bool busy;
  final bool saving;
  final int keptCount;
  final void Function(ImageSource) onCapture;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || saving
                      ? null
                      : () => onCapture(ImageSource.camera),
                  // Sans ce resserrement, « Photographier » se brisait en
                  // « Photographie / r » sur un téléphone de 360 dp — vu sur
                  // l'aperçu, jamais dans un test.
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.photo_camera, size: 18),
                  label: const Text('Photographier', maxLines: 1),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy || saving
                      ? null
                      : () => onCapture(ImageSource.gallery),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Importer', maxLines: 1),
                ),
              ),
            ],
          ),
          if (keptCount > 0) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: saving ? null : onSave,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: saving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.playlist_add_check),
                label: Text('Ajouter ($keptCount)'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Consigne de cadrage avant le scan, décompte des cartes trouvées après.
///
/// **Le nombre est ce que l'utilisateur peut vérifier sans rien relire.** Il
/// sait combien de cartes il a posées sur la table ; comparer deux nombres lui
/// dit immédiatement s'il ne lui reste qu'à contrôler des noms, ou s'il doit en
/// plus partir à la recherche d'une carte manquante. Sans lui, une carte ratée
/// ne se remarque qu'en recomptant la liste — donc jamais.
///
/// **Il compte les cartes posées, pas les lignes de la liste.** Quinze cartes
/// dont six doublons ne font que neuf lignes ; annoncer neuf ferait croire à
/// six cartes perdues. C'est le nombre d'exemplaires qui se compare à la table,
/// et le nombre de cartes différentes ne vient qu'en second — utile, mais ce
/// n'est pas ce que l'utilisateur a compté en les posant.
///
/// **Il ignore les cases à cocher.** Le bouton d'ajout, lui, décompte la
/// sélection. Les deux répondent à deux questions distinctes — « la photo
/// a-t-elle tout vu ? » et « qu'est-ce que je m'apprête à enregistrer ? » — et
/// les confondre rendrait le premier inutilisable dès la première case
/// décochée, alors que c'est justement après avoir corrigé qu'on veut savoir
/// s'il manque quelque chose.
///
/// Il suit en revanche les **quantités** : corriger un doublon que la photo a
/// sous-compté rapproche le total de ce qui est sur la table, et l'utilisateur
/// voit sa correction aboutir.
class _Header extends StatelessWidget {
  const _Header({
    required this.cards,
    required this.distinct,
    required this.manual,
    required this.scanned,
  });

  /// Exemplaires trouvés sur la photo, doublons compris.
  final int cards;

  /// Cartes différentes vues sur la photo, c'est-à-dire lignes issues du scan.
  final int distinct;

  /// Lignes ajoutées à la main, **comptées à part**.
  ///
  /// Les fondre dans [cards] ferait dire au témoin le contraire de ce qu'il
  /// sert à dire : on ajoute une carte à la main précisément parce que la photo
  /// ne l'a pas vue, et l'écart entre la table et la photo est ce qu'on veut
  /// garder sous les yeux. Les afficher tout de même, parce que rien d'autre
  /// n'explique qu'« Ajouter (17) » suive « 16 trouvées ».
  final int manual;

  final bool scanned;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!scanned || cards == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
        child: Text(
          'Photographiez vos cartes étalées, noms bien visibles. '
          'Ce sont eux qui sont lus, pas les illustrations.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Icon(
            Icons.style_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text:
                        '$cards carte${cards > 1 ? 's' : ''} '
                        'trouvée${cards > 1 ? 's' : ''} sur la photo',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (distinct != cards)
                    TextSpan(
                      text: '   $distinct différentes',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (manual > 0)
                    TextSpan(
                      text:
                          '   +$manual à la main',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// L'échec d'enregistrement, annoncé sans emporter la liste.
///
/// Un bandeau et non une page : ce qui a échoué est l'écriture, pas la
/// reconnaissance. Les lignes repérées, leurs quantités et les éditions déjà
/// choisies restent dessous, prêtes pour un second essai.
class _SaveError extends StatelessWidget {
  const _SaveError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ligne d'édition d'une carte repérée : ce qu'on possède, ou rien.
///
/// **Discrète à dessein.** Sur une liste de vingt cartes, un bouton par ligne
/// encombrerait ; c'est un texte qui se touche, effacé tant qu'aucune édition
/// n'est choisie, affirmé une fois qu'elle l'est.
///
/// **Le numéro de collection s'affiche avec l'extension.** L'édition étant
/// désormais parfois retenue sans geste de l'utilisateur, il faut qu'un coup
/// d'œil suffise à la confronter à ce qui est imprimé en bas de la carte —
/// c'est là que se joue la confirmation exigée par le garde-fou §IV.8.
///
/// **La finition se règle ici**, sans ouvrir le sélecteur : c'est le seul choix
/// que le catalogue ne peut pas faire à notre place quand l'édition est unique,
/// et le seul qui distingue deux exemplaires par ailleurs identiques.
class _EditionLine extends StatelessWidget {
  const _EditionLine({required this.item, required this.onChanged});

  final _Spotted item;
  final VoidCallback onChanged;

  Future<void> _choose(BuildContext context) async {
    final chosen = await showPrintingPicker(
      context,
      oracleId: item.card.oracleId,
      cardName: item.card.matchedName,
      currentPrintId: item.printing?.printing.printId,
      currentIsFoil: item.printing?.isFoil ?? false,
      // La langue du nom trouvé restreint la liste : on a reconnu la carte par
      // son nom français, c'est donc l'impression française qu'on tient.
      lang: item.card.matchedLang,
      allowUnspecified: true,
    );
    if (chosen == null) return;
    item.printing = chosen.isUnspecified ? null : chosen;
    onChanged();
  }

  /// Bascule normal / brillant sans quitter la liste.
  void _toggleFoil() {
    final printing = item.printing;
    if (printing == null) return;
    item.printing = PrintingChoice(printing.printing, isFoil: !printing.isFoil);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final printing = item.printing;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: InkWell(
            onTap: () => _choose(context),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    printing == null ? Icons.layers_outlined : Icons.layers,
                    size: 14,
                    color: printing == null
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      printing == null
                          ? "Préciser l'édition"
                          : _label(printing.printing),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: printing == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.primary,
                      ),
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
        if (printing != null && printing.printing.hasFoil) ...[
          const SizedBox(width: 8),
          _FoilChip(
            value: printing.isFoil,
            // Une édition qui n'existe qu'en brillante ne se débascule pas.
            onTap: printing.printing.hasNonfoil ? _toggleFoil : null,
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
