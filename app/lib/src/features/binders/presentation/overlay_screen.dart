/// La carte reconnue, affichée en calque au-dessus d'une vidéo (#14, #21).
///
/// **Ce que cet écran est.** Une *browser source* pour OBS, pas un site. Fond
/// transparent, aucune navigation, aucun texte qui ne serve la lecture. Il ne
/// touche jamais la vidéo : OBS filme, DeckHand publie ce qu'il a vu, et cette
/// page le montre.
///
/// **Deux sources, et le scan prime.** Le calque montre ce que le diffuseur
/// scanne, et ce qu'un spectateur a fait monter depuis le chat (`!montre`). Une
/// carte scannée arrive **physiquement devant l'objectif** : elle passe donc
/// toujours devant une désignation, qui n'est qu'une curiosité. L'inverse
/// serait un calque qui cache ce qu'on est en train de filmer.
///
/// **Une désignation évincée n'est pas perdue.** Elle n'est marquée vue qu'au
/// moment où elle s'affiche : recouverte par un scan, elle remonte au tour
/// suivant, une fois le scan effacé. La laisser tomber ferait disparaître sans
/// trace la demande d'un spectateur — et il n'y a pas de file pour la rattraper.
///
/// **Il se tait quand le réseau tombe.** L'issue en fait une exigence, et elle
/// est juste : un message d'erreur en plein direct est pire que rien. Une
/// interrogation qui échoue est donc **sans effet** — la dernière carte reste
/// affichée, et la suivante la remplacera quand la réponse reviendra. C'est
/// aussi la raison de préférer une interrogation périodique à une connexion
/// persistante : une connexion coupée demande une reconnexion, donc du code qui
/// peut échouer au pire moment ; une requête ratée ne demande rien. Les deux
/// sources échouent **séparément** : une base qui refuse la désignation ne doit
/// pas emporter l'annonce des cartes scannées.
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
import '../domain/spotlight_card.dart';

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
///
/// **Le délai de garde côté base doit rester au-dessus.** Il vaut trente
/// secondes (`public_request_spotlight`) : en deçà de ces douze-là, une nouvelle
/// désignation remplacerait une carte que le demandeur précédent n'a pas fini de
/// voir. Si cette constante devait dépasser trente, c'est la migration qu'il
/// faudrait revoir.
const Duration overlayLinger = Duration(seconds: 12);

/// Ce que le calque affiche, quelle qu'en soit la source.
///
/// **Une seule bannière pour deux origines.** Un scan et une désignation
/// n'apportent pas la même information — l'un dit « nouvelle ou doublon »,
/// l'autre « demandée par untel » — mais ils occupent la même place et se lisent
/// pareil. Les fondre ici évite deux widgets qui divergeraient au premier
/// changement de style.
@immutable
class OverlayCard {
  const OverlayCard({
    required this.name,
    required this.badge,
    required this.badgeColor,
    required this.fromScan,
    this.setCode,
    this.collectorNumber,
    this.artCropUrl,
    this.priceEur,
    this.isFoil = false,
  });

  final String name;
  final String badge;
  final Color badgeColor;

  /// Vrai quand la carte vient du journal, c'est-à-dire d'un carton réellement
  /// passé devant l'objectif. C'est ce qui lui donne la priorité.
  final bool fromScan;

  final String? setCode;
  final String? collectorNumber;
  final String? artCropUrl;
  final double? priceEur;
  final bool isFoil;

  factory OverlayCard.scanned(RecentAddition card) => OverlayCard(
    name: card.displayName,
    badge: card.fillsEmptySlot
        ? 'nouvelle — case comblée'
        : 'doublon — ${card.copiesBefore + 1}ᵉ exemplaire',
    badgeColor: card.fillsEmptySlot
        ? const Color(0xFF1F6F43)
        : const Color(0xFF4A3B12),
    fromScan: true,
    setCode: card.setCode,
    collectorNumber: card.collectorNumber,
    artCropUrl: card.artCropUrl,
    priceEur: card.priceEur,
    isFoil: card.isFoil,
  );

  factory OverlayCard.designated(SpotlightCard card) => OverlayCard(
    name: card.displayName,
    // **Le demandeur est l'information.** Sans son nom, une désignation se
    // confondrait avec un scan et perdrait ce qui en fait une interaction.
    badge: card.requestedBy == null
        ? 'demandée dans le chat'
        : 'demandée par ${card.requestedBy}',
    // Une couleur à part : le spectateur doit distinguer d'un coup d'œil ce que
    // le diffuseur vient d'ouvrir de ce que le chat a réclamé.
    badgeColor: const Color(0xFF2F3E7A),
    fromScan: false,
    setCode: card.setCode,
    collectorNumber: card.collectorNumber,
    artCropUrl: card.artCropUrl,
    priceEur: card.priceEur,
  );
}

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

  OverlayCard? _card;

  /// Le dernier mouvement déjà vu. **Comparer les identifiants et non les
  /// noms** : deux exemplaires successifs de la même carte sont deux
  /// événements, et une comparaison par nom en avalerait le second.
  int? _lastSeen;

  /// La dernière demande **affichée**, et non la dernière reçue : une
  /// désignation recouverte par un scan doit pouvoir remonter ensuite.
  int? _lastShownRequest;

  /// Vrai tant qu'aucune réponse n'est revenue de la désignation. La première
  /// ne fait qu'établir la référence, comme pour le journal.
  bool _firstSpotlight = true;

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

  /// Lance une lecture dont l'échec est sans effet.
  ///
  /// **Sans effet, et c'est l'exigence.** Réseau coupé, base indisponible,
  /// réponse illisible : la carte affichée reste, et rien ne s'écrit à l'écran.
  /// Un direct ne doit jamais montrer une erreur de DeckHand.
  Future<T?> _quiet<T>(Future<T?> Function() read) async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }

  Future<void> _poll() async {
    final repo = ref.read(collectionRepositoryProvider);
    final (additions, designated) = await (
      _quiet(() => repo.recentAdditions(widget.handle)),
      _quiet(() => repo.spotlight(widget.handle)),
    ).wait;
    if (!mounted) return;

    if (_takeAddition(additions)) return;
    _takeDesignation(designated);
  }

  /// Affiche la dernière carte scannée si elle est neuve. Rend vrai si elle a
  /// pris la place — auquel cas la désignation attend son tour.
  bool _takeAddition(List<RecentAddition>? rows) {
    if (rows == null || rows.isEmpty) return false;
    final latest = rows.first;

    // **La première réponse ne déclenche rien.** Au lancement d'OBS, la
    // dernière carte du journal peut dater de la veille ; l'afficher ferait
    // croire qu'on vient de l'ouvrir.
    if (_lastSeen == null) {
      _lastSeen = latest.movementId;
      return false;
    }
    if (latest.movementId == _lastSeen) return false;

    _lastSeen = latest.movementId;
    _show(OverlayCard.scanned(latest));
    return true;
  }

  void _takeDesignation(SpotlightCard? card) {
    if (card == null) {
      _firstSpotlight = false;
      return;
    }
    if (_firstSpotlight) {
      // Comme pour le journal : un calque rouvert ne rejoue pas la demande
      // d'avant la coupure.
      _firstSpotlight = false;
      _lastShownRequest = card.requestId;
      return;
    }
    if (card.requestId == _lastShownRequest) return;

    // Le scan à l'écran garde la main. La demande n'est pas marquée vue : elle
    // remontera au tour suivant, une fois la carte scannée effacée.
    if (_card?.fromScan ?? false) return;

    _lastShownRequest = card.requestId;
    _show(OverlayCard.designated(card));
  }

  void _show(OverlayCard card) {
    setState(() => _card = card);
    _hide?.cancel();
    _hide = Timer(overlayLinger, () {
      if (mounted) setState(() => _card = null);
    });
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

  final OverlayCard card;

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
                  card.name,
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: card.badgeColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    card.badge,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
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

  static String _subtitle(OverlayCard card) {
    final parts = <String>[
      if (card.setCode != null) card.setCode!.toUpperCase(),
      if (card.collectorNumber != null) '#${card.collectorNumber}',
      if (card.isFoil) 'brillante',
      if (card.priceEur != null) '${card.priceEur!.toStringAsFixed(2)} €',
    ];
    return parts.join('  ·  ');
  }
}
