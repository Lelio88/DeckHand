/// La carte reconnue, affichée en calque au-dessus d'une vidéo (#14).
///
/// **Ce que cet écran est.** Une *browser source* pour OBS, pas un site. Fond
/// transparent, aucune navigation, aucun texte qui ne serve la lecture. Il ne
/// touche jamais la vidéo : OBS filme, DeckHand publie ce qu'il a vu, et cette
/// page le montre.
///
/// **Il se tait quand le réseau tombe.** L'issue en fait une exigence, et elle
/// est juste : un message d'erreur en plein direct est pire que rien. Une
/// interrogation qui échoue est donc **sans effet** — la dernière carte reste
/// affichée, et la suivante la remplacera quand la réponse reviendra. C'est
/// aussi la raison de préférer une interrogation périodique à une connexion
/// persistante : une connexion coupée demande une reconnexion, donc du code qui
/// peut échouer au pire moment ; une requête ratée ne demande rien.
///
/// **Aucun secret dans l'adresse.** La source finira dans une capture d'écran :
/// elle ne porte qu'une adresse de partage, celle-là même qui ouvre le classeur
/// public. Ce qu'elle donne à lire est borné par la base — collection publiée,
/// extensions choisies — et non par cette page.
///
/// **L'attribution est visible**, garde-fou §IV.2 : une page vue par des
/// inconnus porte son crédit, fût-elle un calque.
///
/// Usage : `https://…/?o=<adresse-de-partage>` dans une browser source OBS,
/// fond transparent coché.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../collection/data/collection_repository.dart';
import '../domain/recent_addition.dart';

/// Adresse de partage lue dans l'URL pour le mode overlay, ou `null`.
///
/// **Un paramètre distinct de celui du classeur**, et non un drapeau ajouté à
/// lui : les deux pages n'ont ni le même public ni la même forme, et confondre
/// leurs adresses ferait ouvrir un calque transparent à qui voulait consulter
/// une collection.
///
/// Comme pour le classeur, on regarde avant **et** après le `#` : Flutter sert
/// ses routes tantôt derrière un fragment, tantôt non.
String? overlayFromUrl(Uri url) {
  final direct = url.queryParameters['o'];
  if (direct != null && direct.isNotEmpty) return direct;

  final fragment = url.fragment;
  if (fragment.isEmpty) return null;
  final question = fragment.indexOf('?');
  if (question < 0) return null;
  final inner = Uri.splitQueryString(fragment.substring(question + 1))['o'];
  return (inner == null || inner.isEmpty) ? null : inner;
}

/// Cadence d'interrogation.
///
/// **Une seconde et demie, et c'est un choix.** Assez court pour qu'une carte
/// posée devant l'objectif apparaisse avant que le spectateur ne s'impatiente,
/// assez long pour qu'un direct de deux heures ne fasse que cinq mille
/// requêtes — le prix d'une page qui se recharge, étalé.
const Duration overlayPollInterval = Duration(milliseconds: 1500);

/// Combien de temps une carte reste affichée après son arrivée.
///
/// Passé ce délai, le calque s'efface : un overlay qui garde la dernière carte
/// indéfiniment finit par mentir sur ce qui se passe à l'écran.
const Duration overlayLinger = Duration(seconds: 12);

class OverlayScreen extends ConsumerStatefulWidget {
  const OverlayScreen({super.key, required this.handle});

  /// Ce que portait l'adresse : un nom choisi, ou l'identifiant brut.
  final String handle;

  @override
  ConsumerState<OverlayScreen> createState() => _OverlayScreenState();
}

class _OverlayScreenState extends ConsumerState<OverlayScreen> {
  Timer? _timer;

  /// **L'effacement a besoin de son propre réveil.** Une première version
  /// comparait l'heure courante dans `build` ; rien ne provoquant de
  /// reconstruction à l'échéance, la carte serait restée à l'écran jusqu'à
  /// l'arrivée de la suivante — c'est-à-dire indéfiniment sur un direct qui
  /// s'arrête. Le test l'a montré avant l'antenne.
  Timer? _hide;

  RecentAddition? _card;

  /// Le dernier mouvement déjà vu. **Comparer les identifiants et non les
  /// noms** : deux exemplaires successifs de la même carte sont deux
  /// événements, et une comparaison par nom en avalerait le second.
  int? _lastSeen;

  @override
  void initState() {
    super.initState();
    unawaited(_poll());
    _timer = Timer.periodic(overlayPollInterval, (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final rows = await ref
          .read(collectionRepositoryProvider)
          .recentAdditions(widget.handle);
      if (!mounted || rows.isEmpty) return;
      final latest = rows.first;

      // **La première réponse ne déclenche rien.** Au lancement d'OBS, la
      // dernière carte du journal peut dater de la veille ; l'afficher ferait
      // croire qu'on vient de l'ouvrir.
      if (_lastSeen == null) {
        _lastSeen = latest.movementId;
        return;
      }
      if (latest.movementId == _lastSeen) return;

      setState(() {
        _lastSeen = latest.movementId;
        _card = latest;
      });
      _hide?.cancel();
      _hide = Timer(overlayLinger, () {
        if (mounted) setState(() => _card = null);
      });
    } on Object {
      // **Sans effet, et c'est l'exigence.** Réseau coupé, base indisponible,
      // réponse illisible : la carte affichée reste, et rien ne s'écrit à
      // l'écran. Un direct ne doit jamais montrer une erreur de DeckHand.
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    return Scaffold(
      // Le calque est transparent : c'est OBS qui fournit le fond, et une
      // couleur ici s'imprimerait sur la vidéo.
      backgroundColor: Colors.transparent,
      body: card == null
          ? const SizedBox.shrink()
          : Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _CardBanner(card: card),
              ),
            ),
    );
  }
}

class _CardBanner extends StatelessWidget {
  const _CardBanner({required this.card});

  final RecentAddition card;

  @override
  Widget build(BuildContext context) {
    final art = card.artCropUrl;
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        // Un fond sombre translucide plutôt qu'opaque : la vidéo reste
        // devinable derrière, ce qui ancre le calque dans la scène.
        color: const Color(0xCC101014),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (art != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                art,
                width: 132,
                fit: BoxFit.cover,
                // Une illustration qui ne charge pas ne doit pas trouer le
                // calque : la bannière tient sans elle.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          if (art != null) const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  card.displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _subtitle(card),
                  style: const TextStyle(color: Color(0xFFB9BCC6), fontSize: 13),
                ),
                const SizedBox(height: 8),
                _Badge(card: card),
                const SizedBox(height: 8),
                // Garde-fou §IV.2 : le crédit est visible de qui regarde, même
                // ici. Un calque est vu par plus d'inconnus qu'un écran « à
                // propos ».
                const Text(
                  'Données : Scryfall',
                  style: TextStyle(color: Color(0x99FFFFFF), fontSize: 10),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _subtitle(RecentAddition card) {
    final parts = <String>[
      if (card.setCode != null) card.setCode!.toUpperCase(),
      if (card.collectorNumber != null) '#${card.collectorNumber}',
      if (card.isFoil) 'brillante',
      if (card.priceEur != null) '${card.priceEur!.toStringAsFixed(2)} €',
    ];
    return parts.join('  ·  ');
  }
}

/// Ce qui a de la valeur pour un spectateur : la carte comble-t-elle un trou ?
class _Badge extends StatelessWidget {
  const _Badge({required this.card});

  final RecentAddition card;

  @override
  Widget build(BuildContext context) {
    final fills = card.fillsEmptySlot;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: fills ? const Color(0xFF1F6F43) : const Color(0xFF4A3B12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        fills
            ? 'nouvelle — case comblée'
            : 'doublon — ${card.copiesBefore + 1}ᵉ exemplaire',
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}
