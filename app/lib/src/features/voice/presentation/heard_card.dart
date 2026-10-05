/// Une ligne de la dictée : la carte entendue, ce que la recherche en a fait,
/// et ce qui a été dit et retenu de son impression.
///
/// **Sortie de l'écran pour qu'il reste lisible**, non pour être partagée :
/// seule la dictée s'en sert. L'écran orchestre l'écoute et les requêtes ;
/// la ligne porte les règles qui disent ce qu'elle enregistre — quelle
/// édition, quelle finition, et pourquoi elle n'en a pas.
///
/// **Elle est mutable**, comme l'était sa version privée : l'écran la modifie
/// dans un `setState`, et la liste en garde l'identité — c'est ce qui permet à
/// une réponse du catalogue d'atteindre sa ligne même si d'autres se sont
/// ajoutées entre-temps.
library;

import '../../card_search/domain/card_hit.dart';
import '../../printings/presentation/printing_picker.dart' show PrintingChoice;
import '../domain/spoken_printing.dart';

/// Une carte dictée, avec ce que la recherche en a fait.
class HeardCard {
  HeardCard({
    required this.spoken,
    required this.quantity,
    this.match,
    this.alternatives = const [],
    this.asked = SpokenPrinting.none,
  }) : note = asked.foil && asked.set == null ? _foilPending : null;

  final String spoken;
  int quantity;
  final CardHit? match;
  final List<CardHit> alternatives;

  /// Ce que la dictée a dit de l'impression : extension, numéro, finition.
  ///
  /// C'est aussi une part de l'identité de la ligne — voir le cumul dans
  /// `_absorb`.
  final SpokenPrinting asked;

  /// Pourquoi l'édition dite n'a pas été retenue, tant qu'elle ne l'est pas.
  ///
  /// **Une édition dite et non retenue doit le dire.** Sans ce mot, la ligne
  /// « Préciser l'édition » ressemblerait à une carte dont on n'a rien dit,
  /// et l'on croirait avoir été entendu.
  String? note;

  /// Recherche à rouvrir dans le sélecteur : l'extension entendue, quand elle
  /// laisse plusieurs éditions ou qu'elle n'est qu'approchée.
  String? pickerQuery;

  /// Édition retenue : d'office quand le catalogue n'en connaît qu'une, à la
  /// voix quand celle qui est dite ne laisse rien à choisir, à la main le reste
  /// du temps.
  ///
  /// **Elle se remplit seule, et se touche une fois l'écoute arrêtée.** La
  /// dictée est la voie « mains occupées » : un sélecteur modal ouvert pendant
  /// que le micro écoute laisserait les cartes s'accumuler derrière lui. Mais
  /// cet argument tombe dès que l'on a coupé — c'est-à-dire au moment où l'on
  /// relit sa liste avant de l'enregistrer, et où toutes les autres voies
  /// d'ajout proposent de préciser. Sans ce geste, la dictée était la seule à
  /// envoyer dans la pile à trier tout ce que le catalogue ne tranchait pas.
  ///
  /// Le remplissage d'office garde sa raison d'être : quand une carte n'admet
  /// qu'une seule édition, la désigner n'apporte aucune information que la
  /// carte elle-même ne porte déjà.
  PrintingChoice? printing;

  /// Vrai dès que l'utilisateur a lui-même statué sur l'édition.
  ///
  /// **Ce que ce drapeau protège.** Choisir « ne pas préciser » laisse
  /// [printing] nul, exactement comme une carte jamais examinée ; sans marque,
  /// la reprise de l'écoute relancerait le remplissage d'office et écraserait
  /// ce choix par l'édition unique que l'on venait d'écarter.
  ///
  /// Il protège aussi d'une réponse tardive : une recherche d'édition dite,
  /// partie avant qu'on ne coupe le micro et choisisse au doigt, ne défait pas
  /// ce choix en revenant — voir [settle].
  bool printingIsUserSet = false;

  bool get isResolved => match != null;

  /// L'édition choisie à la main : elle remplace tout ce que la dictée en
  /// disait.
  void choose(PrintingChoice? choice) {
    printing = choice;
    printingIsUserSet = true;
    note = null;
  }

  /// Reporte sur la ligne ce que le catalogue a établi de l'édition dite.
  ///
  /// [resolution] nulle : le catalogue n'a pas répondu. Sans effet sur une
  /// ligne dont l'utilisateur a déjà tranché l'édition : ce qui vient du
  /// catalogue ne défait jamais un geste.
  ///
  /// [pickerQuery] absente laisse en place celle d'une réponse précédente : le
  /// remplissage des éditions uniques repasse sur la ligne sans connaître la
  /// recherche qui a ramené ses candidates.
  void settle(PrintingResolution? resolution, {String? pickerQuery}) {
    if (printingIsUserSet) return;
    if (pickerQuery != null) this.pickerQuery = pickerQuery;
    final heard = _heardEdition;
    switch (resolution) {
      case PrintingRetained(:final printing, :final isFoil):
        this.printing = PrintingChoice(printing, isFoil: isFoil);
        note = null;
      case PrintingApproximate(:final candidate):
        final found = candidate.setName ?? candidate.setCode.toUpperCase();
        note = '« $heard » : $found ? À confirmer';
      case PrintingAmbiguous():
        note = '« $heard » : plusieurs éditions, à choisir';
      case PrintingNotFound():
        note = 'Édition « $heard » introuvable';
      case PrintingNotInFoil():
        note = asked.set == null
            ? 'Aucune édition brillante pour cette carte'
            : "« $heard » n'existe pas en brillante";
      case null:
        note = 'Édition « $heard » : catalogue injoignable';
    }
  }

  /// L'édition telle qu'entendue : « m21 #137 ».
  String get _heardEdition {
    final number = asked.number;
    return number == null ? '${asked.set}' : '${asked.set} #$number';
  }
}

/// La brillante dite sans édition ne s'enregistre pas seule : une carte
/// brillante sans édition entrerait dans la pile à trier, d'où le rangement ne
/// la sort pas — il déplace la ligne normale. Il faut le dire avant
/// « Ajouter », pas après.
const _foilPending =
    "Brillante : précisez l'édition, sinon la carte part normale";
