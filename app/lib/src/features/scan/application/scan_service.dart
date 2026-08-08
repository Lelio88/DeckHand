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

import '../../../diagnostics/diagnostics.dart';
import '../../card_search/data/card_repository.dart';
import '../../card_search/domain/card_hit.dart';
import '../data/art_index_repository.dart';
import '../data/card_text_reader.dart';
import '../domain/art_box.dart';
import '../domain/art_hash_index.dart';
import '../domain/card_framing.dart';
import '../domain/card_name_text.dart';
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

  /// Cadre ayant donné la meilleure correspondance, utile au diagnostic.
  final CardFrame? frame;

  final String? error;

  bool get isEmpty => oracleIds.isEmpty;

  factory ScanOutcome.failure(String message) =>
      ScanOutcome(oracleIds: const [], isConfident: false, error: message);
}

/// Score au-delà duquel un nom lu est tenu pour certain.
///
/// La recherche rend 1,0 sur une égalité exacte après normalisation. Ce seuil
/// laisse passer une lettre mal lue sur un nom long sans admettre les
/// rapprochements approximatifs.
const double _decisiveScore = 0.9;

class ScanService {
  const ScanService(this._index, this._reader, this._cards);

  final ArtHashIndex _index;
  final CardTextReader _reader;
  final CardRepository _cards;

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
    final names = await _readNames(photoPath);

    if (names.isEmpty) return art;

    final found = await _searchNames(names, limit: limit);
    if (found.isEmpty) return art;

    // Les deux voies concordent : le doute est levé, quelle que soit la
    // distance d'empreinte — c'est la confirmation croisée qui fait foi.
    final confirmed = art.oracleIds.isNotEmpty && found.contains(art.oracleIds.first);

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
  Future<List<CardHit>> recogniseSpread(String photoPath) async {
    final lines = await _reader.readLines(photoPath);
    final candidates = spreadNameCandidates(lines);
    _diagnoseRead(lines, candidates);
    if (candidates.isEmpty) return const [];

    // Les recherches partent ensemble : une photo d'étalement en produit des
    // dizaines, et les enchaîner rendrait l'attente insupportable.
    final results = await Future.wait(
      candidates.map((candidate) async {
        try {
          return await _cards.search(candidate.text, limit: 1);
        } catch (_) {
          return const <CardHit>[];
        }
      }),
    );

    final found = <String, CardHit>{};
    for (var i = 0; i < results.length; i++) {
      final hits = results[i];
      if (hits.isEmpty) {
        _diagnoseMatch(candidates[i], null, kept: false);
        continue;
      }
      final hit = hits.first;
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
      // Une même carte peut être lue deux fois — nom scindé sur deux lignes,
      // ou deux exemplaires côte à côte. Le second cas mériterait une quantité,
      // mais rien ne permet de le distinguer du premier de façon fiable.
      found.putIfAbsent(hit.oracleId, () => hit);
    }
    return found.values.toList(growable: false);
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
    diagnose('spread_read', {'lines': lines.length, 'kept': candidates.length});
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
  void _diagnoseMatch(NameCandidate candidate, CardHit? hit, {required bool kept}) {
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

    final card = cropToCardFrame(decoded);
    final outcome = _index.searchAny(artHashCandidates(card), limit: limit);

    return ScanOutcome(
      oracleIds: outcome.result.candidates
          .map((c) => c.oracleId)
          .toList(growable: false),
      isConfident: outcome.result.isConfident,
      frame: outcome.source,
    );
  }

  Future<List<String>> _readNames(String? path) async {
    if (path == null) return const [];
    return cardNameCandidates(await _reader.readLines(path));
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
final scanServiceProvider = FutureProvider<ScanService>((ref) async {
  final index = await ref.watch(artHashIndexProvider.future);
  return ScanService(
    index,
    ref.watch(cardTextReaderProvider),
    ref.watch(cardRepositoryProvider),
  );
});
