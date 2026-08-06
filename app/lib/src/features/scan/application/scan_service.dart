/// Reconnaissance d'une carte à partir d'une photo.
///
/// Enchaîne le cadrage, le découpage de l'illustration selon les deux gabarits
/// de cadre, le calcul des empreintes et la recherche dans l'index embarqué.
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

import '../data/art_index_repository.dart';
import '../domain/art_box.dart';
import '../domain/art_hash_index.dart';
import '../domain/card_framing.dart';

/// Ce qu'une tentative de reconnaissance a produit.
class ScanOutcome {
  const ScanOutcome({
    required this.candidates,
    required this.isConfident,
    this.frame,
    this.error,
  });

  /// Cartes proposées, la plus probable en tête.
  final List<HashMatch> candidates;

  /// Vrai si un candidat se détache assez pour être proposé sans réserve.
  /// Faux n'empêche pas d'afficher les candidats — cela change le ton : on
  /// suggère au lieu d'affirmer.
  final bool isConfident;

  /// Cadre ayant donné la meilleure correspondance, utile au diagnostic.
  final CardFrame? frame;

  final String? error;

  bool get isEmpty => candidates.isEmpty;

  factory ScanOutcome.failure(String message) =>
      ScanOutcome(candidates: const [], isConfident: false, error: message);
}

class ScanService {
  const ScanService(this._index);

  final ArtHashIndex _index;

  /// Reconnaît la carte présente sur [photoBytes].
  ///
  /// Les candidats sont renvoyés même lorsque la confiance est faible : mieux
  /// vaut proposer trois cartes à départager que de ne rien montrer et laisser
  /// l'utilisateur sans recours.
  ScanOutcome recognise(Uint8List photoBytes, {int limit = 3}) {
    // `decodeImage` renvoie null sur un format inconnu, mais **lève** sur des
    // octets tronqués ou corrompus — les deux arrivent avec une photo
    // interrompue en cours d'écriture.
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(photoBytes);
    } on Object {
      return ScanOutcome.failure('Image illisible.');
    }
    if (decoded == null) {
      return ScanOutcome.failure('Image illisible.');
    }
    if (_index.length == 0) {
      return ScanOutcome.failure('Index de reconnaissance non chargé.');
    }

    final card = cropToCardFrame(decoded);
    final outcome = _index.searchAny(artHashCandidates(card), limit: limit);

    return ScanOutcome(
      candidates: outcome.result.candidates,
      isConfident: outcome.result.isConfident,
      frame: outcome.source,
    );
  }
}

/// Service de reconnaissance, disponible dès que l'index est chargé.
final scanServiceProvider = FutureProvider<ScanService>((ref) async {
  final index = await ref.watch(artHashIndexProvider.future);
  return ScanService(index);
});
