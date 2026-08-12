/// Reconnaissance d'une carte à partir d'une photo.
///
/// **Deux voies, dans cet ordre.** La carte est d'abord identifiée par son
/// **nom imprimé**, lu sur la photo et confronté au catalogue par une recherche
/// tolérante aux fautes. À défaut seulement, on retombe sur l'empreinte de
/// l'illustration : cadrage, découpage selon les deux gabarits de cadre, calcul
/// d'empreinte et recherche dans l'index embarqué.
///
/// Cet ordre est le fruit du premier test terrain. L'empreinte seule suppose que
/// l'illustration exacte figure dans l'index — un quart des rééditions changent
/// d'art — et que le cadrage soit juste à 3 % près, soit deux millimètres et
/// demi. Le nom, lui, se lit de travers et ne dépend d'aucune édition.
///
/// L'empreinte garde deux rôles : servir de recours là où le texte est illisible
/// ou absent (web, carte abîmée, fort reflet), et **confirmer** un nom lu — quand
/// les deux voies désignent la même carte, le doute est levé.
///
/// Le service ne décide **jamais** d'ajouter une carte à la collection : il
/// propose des candidats, l'utilisateur tranche. C'est le garde-fou §IV.8 du
/// CLAUDE.md — aucune reconnaissance n'est assez sûre pour écrire sans
/// confirmation, et une carte enregistrée à tort fausse ensuite toutes les
/// suggestions de decks.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../../config/selected_game.dart';
import '../../../diagnostics/diagnostics.dart';
import '../../card_search/data/card_repository.dart';
import '../../card_search/domain/card_hit.dart';
import '../data/art_index_repository.dart';
import '../data/card_text_reader.dart';
import '../domain/art_box.dart';
import '../domain/art_hash_index.dart';
import '../domain/card_bounds.dart';
import '../domain/card_framing.dart';
import '../domain/card_name_text.dart';
import '../domain/card_segmentation.dart';
import '../domain/spread_names.dart';

/// Comment une carte a été identifiée. Détermine ce que l'écran annonce.
enum ScanMethod {
  /// Nom lu et retrouvé au catalogue, confirmé par l'illustration.
  nameAndArt,

  /// Nom lu et retrouvé au catalogue.
  name,

  /// Illustration seule — le texte n'a rien donné.
  art,
}

/// Ce qu'une tentative de reconnaissance a produit.
class ScanOutcome {
  const ScanOutcome({
    required this.oracleIds,
    required this.isConfident,
    this.method = ScanMethod.art,
    this.readName,
    this.readLines = const [],
    this.frame,
    this.error,
  });

  /// Cartes proposées, la plus probable en tête.
  final List<String> oracleIds;

  /// Vrai si un candidat se détache assez pour être proposé sans réserve.
  /// Faux n'empêche pas d'afficher les candidats — cela change le ton : on
  /// suggère au lieu d'affirmer.
  final bool isConfident;

  final ScanMethod method;

  /// Nom effectivement lu sur la carte. Affiché tel quel : quand la lecture se
  /// trompe, le voir explique l'erreur au lieu de la rendre incompréhensible.
  final String? readName;

  /// **Tout** le texte lu sur la photo, et pas seulement le nom.
  ///
  /// La reconnaissance rend aussi le type, les règles, l'illustrateur et la
  /// ligne d'extension ; jusqu'ici tout cela était jeté après avoir servi à
  /// trouver le nom. Or c'est là que se lit le code d'extension, qui précise
  /// l'édition — voir `readSetCode`. Les conserver ne coûte rien : elles sont
  /// déjà en mémoire.
  final List<ReadLine> readLines;

  /// Cadre ayant donné la meilleure correspondance, utile au diagnostic.
  final CardFrame? frame;

  final String? error;

  bool get isEmpty => oracleIds.isEmpty;

  /// Le même résultat, augmenté du texte lu sur la photo.
  ScanOutcome withLines(List<ReadLine> lines) => ScanOutcome(
    oracleIds: oracleIds,
    isConfident: isConfident,
    method: method,
    readName: readName,
    readLines: lines,
    frame: frame,
    error: error,
  );

  factory ScanOutcome.failure(String message) =>
      ScanOutcome(oracleIds: const [], isConfident: false, error: message);
}

/// Une carte repérée sur un étalement, et en combien d'exemplaires.
///
/// **Les exemplaires ne pouvaient pas être comptés jusqu'ici**, et c'était la
/// limite la plus coûteuse de l'étalement : sur une collection réelle, les
/// communes arrivent par quatre. Quatre exemplaires d'un même dinosaure étaient
/// lus quatre fois par l'appareil, puis fusionnés en une seule carte de
/// quantité 1 — la perte était silencieuse.
class SpreadFind {
  const SpreadFind(this.card, {this.copies = 1});

  final CardHit card;

  /// Nombre d'exemplaires distincts vus sur la photo.
  ///
  /// Sert de proposition, jamais de décision : l'écran la présente et
  /// l'utilisateur l'ajuste (garde-fou §IV.8).
  final int copies;
}

/// Score au-delà duquel un nom lu est tenu pour certain.
///
/// La recherche rend 1,0 sur une égalité exacte après normalisation. Ce seuil
/// laisse passer une lettre mal lue sur un nom long sans admettre les
/// rapprochements approximatifs.
const double _decisiveScore = 0.9;

class ScanService {
  const ScanService(
    this._index,
    this._reader,
    this._cards, {
    this.game = Game.magic,
  });

  final ArtHashIndex _index;
  final CardTextReader _reader;
  final CardRepository _cards;

  /// Jeu saisi, qui décide des gabarits d'illustration essayés.
  ///
  /// **Sans lui, le cloisonnement de `art_box.dart` ne servait à rien.** Les
  /// cadres y sont marqués par jeu et la fonction sait les filtrer, mais le
  /// service ne le lui demandait pas : le défaut du paramètre (`magic`)
  /// s'appliquait quel que soit le jeu réellement saisi. Une carte Riftbound
  /// était donc découpée aux coordonnées d'un cadre Magic — or l'empreinte est
  /// la voie **principale** pour ce jeu, faute de catalogue traduit, et non le
  /// recours qu'elle est en Magic.
  final Game game;

  /// Reconnaît la carte photographiée.
  ///
  /// Les candidats sont renvoyés même lorsque la confiance est faible : mieux
  /// vaut proposer trois cartes à départager que de ne rien montrer et laisser
  /// l'utilisateur sans recours.
  Future<ScanOutcome> recognise(
    Uint8List photoBytes, {
    String? photoPath,
    int limit = 3,
  }) async {
    // L'empreinte est calculée d'abord : elle ne dépend d'aucun service externe
    // et sert de recours quel que soit le sort de la lecture du texte.
    final art = _byArt(photoBytes, limit: limit);
    // Les lignes brutes sont gardées : le nom en sort, mais aussi la ligne
    // d'extension dont l'écran a besoin pour préciser l'édition.
    final lines = photoPath == null
        ? const <ReadLine>[]
        : await _reader.readLines(photoPath);
    final names = cardNameCandidates(lines);

    // Même quand le nom n'a rien donné, le texte lu garde sa valeur : la carte
    // identifiée par son illustration a, elle aussi, une extension à préciser.
    // Un nom illisible n'implique pas un code illisible — il est plus court et
    // en capitales.
    final byArt = art.withLines(lines);

    if (names.isEmpty) return byArt;

    final found = await _searchNames(names, limit: limit);
    if (found.isEmpty) return byArt;

    // Les deux voies concordent : le doute est levé, quelle que soit la
    // distance d'empreinte — c'est la confirmation croisée qui fait foi.
    final confirmed =
        art.oracleIds.isNotEmpty && found.contains(art.oracleIds.first);

    return ScanOutcome(
      // **Les candidats par illustration ne sont pas mêlés à ceux du nom.**
      // Quand le nom a répondu, ils n'apportent rien : ce sont les plus proches
      // d'un index où l'illustration cherchée est peut-être absente, donc du
      // bruit. Les afficher sous une carte correctement identifiée sème le
      // doute au lieu de l'éclairer — « Big Wheel » proposé avec « roue à
      // aiguiser » et « Skald chanteguerre » donne l'impression que l'app
      // hésite alors qu'elle sait.
      oracleIds: found.take(limit).toList(growable: false),
      isConfident: confirmed || found.length == 1,
      method: confirmed ? ScanMethod.nameAndArt : ScanMethod.name,
      readName: names.first,
      readLines: lines,
      frame: art.frame,
    );
  }

  /// Repère **toutes** les cartes visibles sur une photo d'étalement.
  ///
  /// Ne découpe pas l'image : chaque carte porte son nom, et un nom retrouvé au
  /// catalogue est une carte détectée. La séparation devient un effet de bord
  /// de la lecture — là où les tentatives de segmentation plafonnaient à 57 %.
  ///
  /// Renvoie les cartes dans l'ordre de lecture, de haut en bas. Une carte peut
  /// manquer (nom masqué, reflet) ; c'est assumé, l'utilisateur voit son
  /// étalement et complétera. L'inverse — inventer une carte qu'il validerait
  /// sans y penser — fausserait durablement ses suggestions de decks.
  Future<List<SpreadFind>> recogniseSpread(
    String photoPath, {
    Uint8List? photoBytes,
  }) async {
    final lines = await _reader.readLines(photoPath);
    final candidates = spreadNameCandidates(lines);
    _diagnoseRead(lines, candidates);
    if (candidates.isEmpty) return const [];

    // **Un seul aller-retour pour toutes les lignes.** Voir
    // `CardRepository.searchMany` : une requête par ligne coûtait 77 secondes
    // sur une photo de dix-sept cartes, contre 3,3 en un appel groupé.
    //
    // **L'échec n'est plus avalé.** La version précédente rattrapait chaque
    // erreur en rendant « aucune carte trouvée » : une coupure réseau
    // ressemblait alors trait pour trait à un étalement illisible, et l'écran
    // restait muet. L'erreur remonte désormais à l'appelant, qui l'affiche.
    final Map<String, CardHit> results;
    try {
      results = await _cards.searchMany(
        candidates.map((c) => c.text).toList(growable: false),
      );
    } catch (error) {
      diagnose('spread_search_failed', {
        'candidates': candidates.length,
        'error': error.toString(),
      });
      rethrow;
    }

    final found = <String, CardHit>{};
    final places = <String, List<NameCandidate>>{};
    for (var i = 0; i < candidates.length; i++) {
      final hit = results[candidates[i].text];
      if (hit == null) {
        _diagnoseMatch(candidates[i], null, kept: false);
        continue;
      }
      // Deux garde-fous, contre deux erreurs différentes. Le score sépare la
      // trouvaille du hasard : dans un catalogue de 31 634 cartes, n'importe
      // quelle ligne trouve *quelque chose*. La longueur écarte le fragment :
      // un nom masqué se lit tronqué, et un début de nom est un préfixe exact
      // d'une autre carte — que le score approuve sans hésiter.
      final kept =
          hit.score >= spreadScoreThreshold &&
          isPlausibleMatch(candidates[i].text, hit.matchedName);
      _diagnoseMatch(candidates[i], hit, kept: kept);
      if (!kept) continue;
      // **Les exemplaires se comptent par leur position, pas par leur texte.**
      // Deux exemplaires d'une même carte sont rarement lus à l'identique —
      // « Dinosaure de la Terre sauvage » et « Dinosaure de la Terre sauyage »
      // désignent la même carte —, et un exemplaire anglais rejoint son
      // homologue français sur la même identité. Le regroupement se fait donc
      // ici, à l'identité de carte, et non sur la ligne lue.
      found.putIfAbsent(hit.oracleId, () => hit);
      places.putIfAbsent(hit.oracleId, () => []).add(candidates[i]);
    }

    final rejected = _citationsAmong(places, photoBytes, found);
    return [
      for (final entry in found.entries)
        if (!rejected.contains(entry.key))
          SpreadFind(entry.value, copies: _countCopies(places[entry.key]!)),
    ];
  }

  /// Identifie les correspondances qui sont des **citations**, non des noms.
  ///
  /// **Le texte d'ambiance cite un personnage qui porte souvent le nom d'une
  /// vraie carte.** « Ka-Zar of the Savage Land » figure au bas des quatre
  /// dinosaures d'une photo, avec un score parfait : ni la longueur, ni le
  /// score, ni la casse ne peuvent s'en apercevoir. Le tiret d'ouverture en
  /// attrape la plupart, mais la reconnaissance le manque parfois.
  ///
  /// Ce qui les sépare vraiment est leur place **dans leur carte** : mesuré, le
  /// nom siège à 2-5 % d'un bord quand la citation est à 15-22 % du sien. Il
  /// suffit donc de ne garder, par carte, que la correspondance la plus collée à
  /// une extrémité — ce qui impose au passage un invariant vrai : *une carte
  /// porte un seul nom*.
  ///
  /// **Ce filtrage ne peut jamais dégrader le résultat.** Il ne s'applique qu'aux
  /// rectangles dont la taille est celle d'une carte isolée ; là où les cartes se
  /// touchent, les blocs soudés sont écartés et leurs lignes retombent sur le
  /// comportement d'avant. Sans photo, sans rectangle exploitable ou sans carte
  /// reconnue, rien n'est rejeté.
  Set<String> _citationsAmong(
    Map<String, List<NameCandidate>> places,
    Uint8List? photoBytes,
    Map<String, CardHit> found,
  ) {
    if (photoBytes == null || photoBytes.isEmpty || places.length < 2) {
      return const {};
    }

    // **Ce filtrage est un supplément, jamais une dépendance.** Il affine un
    // résultat déjà bon ; s'il échoue — image illisible, format inattendu,
    // mémoire — le scan doit rendre exactement ce qu'il rendait avant. Une
    // reconnaissance qui marche ne peut pas être mise en échec par son garde-fou.
    final List<CardBounds> cards;
    try {
      final photo = img.decodeImage(photoBytes);
      if (photo == null) return const {};
      cards = singleCards(findCards(photo));
    } catch (error) {
      diagnose('spread_cards_failed', {'error': error.toString()});
      return const {};
    }
    diagnose('spread_cards', {'found': cards.length});
    if (cards.isEmpty) return const {};

    // Position de chaque correspondance le long de chaque carte, de 0 à 1.
    // Hors de cet intervalle, la ligne appartient à la carte d'à côté.
    final byCard = <int, Map<String, double>>{};
    for (var i = 0; i < cards.length; i++) {
      final card = cards[i];
      final mx = card.width * boundsMargin;
      final my = card.height * boundsMargin;
      final horizontal = card.width > card.height;
      final lo = horizontal ? card.left : card.top;
      final hi = horizontal ? card.right : card.bottom;
      if (hi - lo <= 0) continue;

      final along = <String, double>{};
      for (final entry in places.entries) {
        for (final line in entry.value) {
          if (line.left < card.left - mx || line.left > card.right + mx) {
            continue;
          }
          if (line.top < card.top - my || line.top > card.bottom + my) continue;
          final axis = horizontal ? line.left : line.top;
          final at = (axis - lo) / (hi - lo);
          final seen = along[entry.key];
          // La plus intérieure des lectures : c'est celle qui appartient le
          // plus vraisemblablement à cette carte.
          if (seen == null || (at - 0.5).abs() < (seen - 0.5).abs()) {
            along[entry.key] = at;
          }
        }
      }
      if (along.isNotEmpty) byCard[i] = along;
    }

    // **Le sens se lit dans la photo, il ne peut pas être une constante.** Les
    // rectangles ne portant qu'une correspondance la désignent sans ambiguïté :
    // c'est un nom. La majorité dit de quel côté siègent les noms.
    final lonely = [
      for (final along in byCard.values)
        if (along.length == 1) along.values.first,
    ];
    if (lonely.isEmpty) return const {};
    final low = nameSitsLow(lonely);

    final suspect = <String>{};
    final elected = <String>{};
    for (final along in byCard.values) {
      for (final entry in along.entries) {
        // Hors du rectangle : la ligne est le nom de la carte voisine, pas une
        // citation portée par celle-ci. C'est ce qui sauve *Gorille
        // mercenaire*, dont le nom débordait de trois pour cent.
        if (entry.value < 0 || entry.value > 1) continue;
        // Mesuré depuis le bout qui porte les noms : une citation siège au
        // bout opposé, pas simplement au-delà du milieu.
        final fromNameEnd = low ? entry.value : 1 - entry.value;
        if (fromNameEnd > citationEnd) {
          suspect.add(entry.key);
        } else {
          elected.add(entry.key);
        }
      }
    }

    // Une carte citée ici peut être posée ailleurs : les quatre dinosaures
    // citent Ka-Zar, mais si une carte Ka-Zar était sur la table, son propre
    // rectangle la placerait du côté des noms.
    final rejected = suspect.difference(elected);
    if (rejected.isNotEmpty) {
      // **Nommer ce qui est rejeté, pas seulement le compter.** Les événements
      // `spread_match` sont émis avant ce filtrage et portent encore
      // `kept: true` sur une citation ; sans cette ligne, le journal se
      // contredirait sans qu'on puisse savoir laquelle a sauté.
      diagnose('spread_citations', {
        'low': low,
        'rejected': [for (final id in rejected) found[id]?.matchedName ?? id],
      });
    }
    return rejected;
  }

  /// Combien de cartes physiques ces lectures représentent.
  ///
  /// Chaque lecture est rattachée à un exemplaire déjà vu s'ils sont assez
  /// proches, sinon elle en ouvre un nouveau. C'est ce qui distingue un nom lu
  /// deux fois — parce que coupé, ou relu — de deux cartes posées sur la table.
  ///
  /// Le regroupement se fait de proche en proche : trois exemplaires alignés
  /// forment trois foyers distincts même si chacun est éloigné du suivant de
  /// tout juste plus que le seuil.
  int _countCopies(List<NameCandidate> readings) {
    final anchors = <NameCandidate>[];
    for (final reading in readings) {
      if (anchors.any((anchor) => areSameCard(reading, anchor))) continue;
      anchors.add(reading);
    }
    return anchors.length;
  }

  /// Consigne ce que l'appareil a réellement lu.
  ///
  /// **Les lignes brutes, avant tout filtrage.** Le filtre par taille n'est
  /// réglable que si l'on sait ce qu'il écarte : sans les hauteurs de toutes
  /// les lignes, ajuster son seuil reviendrait à deviner. Rejouées par
  /// `app/tool/sweep_spread_threshold.dart`, elles permettent de balayer le
  /// seuil hors ligne au lieu de reconstruire l'application à chaque essai —
  /// et sur une photo unique, donc comparable d'un seuil à l'autre.
  void _diagnoseRead(List<ReadLine> lines, List<NameCandidate> candidates) {
    if (!diagnosticsEnabled) return;
    final retained = candidates.map((c) => c.text).toSet();
    final size = _reader.lastImageSize;
    diagnose('spread_read', {
      'lines': lines.length,
      'kept': candidates.length,
      'w': size?.width,
      'h': size?.height,
    });
    for (final line in lines) {
      diagnose('spread_line', {
        'text': line.text,
        'top': line.top,
        'height': line.height,
        'left': line.left,
        'width': line.width,
        'kept': retained.contains(cleanNameLine(line.text)),
      });
    }
  }

  /// Consigne le verdict du catalogue sur un candidat.
  ///
  /// Sert de contrôle : l'outil de balayage refait ces recherches depuis le
  /// poste de travail, et doit retrouver les mêmes scores.
  void _diagnoseMatch(
    NameCandidate candidate,
    CardHit? hit, {
    required bool kept,
  }) {
    if (!diagnosticsEnabled) return;
    diagnose('spread_match', {
      'read': candidate.text,
      'matched': hit?.matchedName,
      'score': hit?.score,
      'kept': kept,
    });
  }

  /// Reconnaissance par l'illustration seule.
  ScanOutcome _byArt(Uint8List photoBytes, {required int limit}) {
    // `decodeImage` renvoie null sur un format inconnu, mais **lève** sur des
    // octets tronqués ou corrompus — les deux arrivent avec une photo
    // interrompue en cours d'écriture.
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(photoBytes);
    } on Object {
      return ScanOutcome.failure('Image illisible.');
    }
    if (decoded == null) return ScanOutcome.failure('Image illisible.');
    if (_index.length == 0) {
      return ScanOutcome.failure('Index de reconnaissance non chargé.');
    }

    // **Les coins de la carte d'abord, le cadre centré à défaut.** Découper à
    // une position fixe supposait que la carte remplisse l'image : mesuré, cet
    // espoir ne tolère que 2 à 3 % d'écart, et aucune carte sur quarante n'était
    // reconnue à partir d'un cadrage ordinaire. La détection ramène ce chiffre à
    // 37 sur 40 — et quand elle renonce, on retombe exactement sur l'ancien
    // comportement, jamais sur pire.
    final quad = findCard(decoded);
    final candidates = quad == null
        ? artHashCandidates(cropToCardFrame(decoded), game: game.id)
        : artHashCandidatesInQuad(decoded, quad, game: game.id);
    final outcome = _index.searchAny(candidates, limit: limit);
    _diagnoseArt(outcome, framed: quad != null);

    return ScanOutcome(
      oracleIds: outcome.result.candidates
          .map((c) => c.oracleId)
          .toList(growable: false),
      isConfident: outcome.result.isConfident,
      frame: outcome.source,
    );
  }

  /// Consigne ce que l'illustration a donné, et pourquoi.
  ///
  /// **Un échec d'empreinte est muet par nature.** « Aucune carte trouvée » ne
  /// dit ni où l'illustration a été prélevée, ni à quelle distance est tombé le
  /// plus proche voisin — c'est-à-dire précisément ce qui sépare un mauvais
  /// gabarit d'un mauvais cadrage, ou d'une carte réellement absente de
  /// l'index. Les quatre valeurs ci-dessous suffisent à trancher :
  ///
  /// - `framed` dit si les coins de la carte ont été trouvés ; à défaut on
  ///   retombe sur un cadre centré, qui suppose que la carte remplit l'image ;
  /// - `frame` nomme le gabarit vainqueur, et son jeu vérifie le cloisonnement ;
  /// - `distance` situe la correspondance vis-à-vis de [maxTrustedDistance] ;
  /// - `margin` dit si un second candidat la talonne.
  ///
  /// `index` accompagne le tout : un index de la mauvaise taille signale qu'on
  /// cherche dans le catalogue de l'autre jeu, ce qu'aucune des autres valeurs
  /// ne révélerait.
  void _diagnoseArt(
    ({HashSearchResult result, CardFrame? source}) outcome, {
    required bool framed,
  }) {
    if (!diagnosticsEnabled) return;
    final best = outcome.result.best;
    diagnose('art_match', {
      'game': game.id,
      'framed': framed,
      'frame': outcome.source?.name,
      'oracle_id': best?.oracleId,
      'distance': best?.distance,
      'margin': outcome.result.margin,
      'confident': outcome.result.isConfident,
      'index': _index.length,
    });
  }

  /// Confronte les noms lus au catalogue.
  ///
  /// **Le premier nom qui répond gagne, et lui seul.** Les lignes candidates
  /// sont ordonnées de haut en bas, et le nom d'une carte est toujours la
  /// première : les suivantes sont son type ou son texte de règles. Accumuler
  /// leurs résultats faisait apparaître « Roue à aiguiser » à côté de
  /// « Big Wheel » — une carte trouvée à partir d'une ligne qui n'était pas un
  /// nom, et qui transformait une identification sûre en « reconnaissance
  /// incertaine ».
  ///
  /// Les lignes suivantes ne servent donc que de repli, quand la première n'a
  /// rien donné — le cas d'un nom mal lu.
  Future<List<String>> _searchNames(
    List<String> names, {
    required int limit,
  }) async {
    for (final name in names) {
      final List<CardHit> hits;
      try {
        hits = await _cards.search(name, limit: limit);
      } catch (_) {
        // Sans réseau, la lecture ne sert à rien : l'empreinte prend le relais.
        return const [];
      }
      if (hits.isEmpty) continue;

      // **Un nom lu sans ambiguïté ne s'accompagne pas de voisins.** La
      // recherche est volontairement tolérante aux fautes ; sur « Cherchauloin »
      // elle renvoie aussi « Chercheur » et « Cherche-cœur », qui n'ont de sens
      // que si la lecture était douteuse. Les afficher sous une carte trouvée
      // net donne l'impression que l'app hésite alors qu'elle sait.
      final best = hits.first;
      if (best.score >= _decisiveScore) {
        return [best.oracleId];
      }
      return hits.map((h) => h.oracleId).toList(growable: false);
    }
    return const [];
  }
}

/// Service de reconnaissance, disponible dès que l'index est chargé.
///
/// **Le jeu suit l'index.** [artHashIndexProvider] observe déjà
/// [selectedGameProvider] pour ne charger que les empreintes du jeu courant ;
/// les gabarits doivent venir du même endroit, sous peine de découper une carte
/// d'un jeu pour la chercher dans l'index de l'autre.
final scanServiceProvider = FutureProvider<ScanService>((ref) async {
  final index = await ref.watch(artHashIndexProvider.future);
  return ScanService(
    index,
    ref.watch(cardTextReaderProvider),
    ref.watch(cardRepositoryProvider),
    game: ref.watch(selectedGameProvider),
  );
});
