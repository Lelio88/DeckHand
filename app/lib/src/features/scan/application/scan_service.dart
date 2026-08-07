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

import '../../card_search/data/card_repository.dart';
import '../../card_search/domain/card_hit.dart';
import '../data/art_index_repository.dart';
import '../data/card_text_reader.dart';
import '../domain/art_box.dart';
import '../domain/art_hash_index.dart';
import '../domain/card_framing.dart';
import '../domain/card_name_text.dart';

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
      // La carte lue passe en tête ; les candidats par illustration restent
      // proposés derrière, au cas où la lecture se serait trompée.
      oracleIds: [
        ...found,
        ...art.oracleIds.where((id) => !found.contains(id)),
      ].take(limit).toList(growable: false),
      isConfident: confirmed || found.length == 1,
      method: confirmed ? ScanMethod.nameAndArt : ScanMethod.name,
      readName: names.first,
      frame: art.frame,
    );
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
  /// Les recherches partent ensemble : la lecture propose souvent trois lignes,
  /// et les enchaîner tripleraient l'attente pour rien.
  Future<List<String>> _searchNames(
    List<String> names, {
    required int limit,
  }) async {
    final results = await Future.wait(
      names.map((name) async {
        try {
          return await _cards.search(name, limit: 2);
        } catch (_) {
          // Sans réseau, la lecture ne sert à rien : l'empreinte prend le relais.
          return const <CardHit>[];
        }
      }),
    );

    final ids = <String>[];
    for (final hits in results) {
      for (final hit in hits) {
        if (!ids.contains(hit.oracleId)) ids.add(hit.oracleId);
        if (ids.length >= limit) return ids;
      }
    }
    return ids;
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
