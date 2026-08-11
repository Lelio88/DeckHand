/// Index d'empreintes embarqué, et recherche de la carte correspondante.
///
/// **Une recherche linéaire suffit.** Trente mille comparaisons de 64 bits se
/// font en quelques millisecondes ; une structure d'index sophistiquée (BK-tree,
/// LSH) ajouterait de la complexité pour un gain imperceptible à cette échelle.
///
/// **Le vrai sujet n'est pas de trouver le plus proche, c'est de savoir se
/// taire.** Une carte absente de l'index — un jeton, une carte abîmée, un
/// mauvais cadrage — aura toujours un plus proche voisin. Le proposer serait un
/// faux positif, et l'utilisateur enregistrerait une carte qu'il ne possède pas.
/// D'où deux garde-fous : une distance maximale, et une marge minimale avec le
/// candidat suivant.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'art_hash.dart';

/// Distance au-delà de laquelle une correspondance n'est plus crédible.
///
/// Calibré sur les mesures : une photo dégradée s'écarte de 3 à 12 bits de son
/// illustration de référence, auxquels s'ajoutent 0 à 5 bits imputables aux
/// différences entre décodeurs JPEG. Au-delà, il s'agit vraisemblablement d'une
/// autre carte.
const int maxTrustedDistance = 12;

/// Écart minimal entre les deux meilleurs candidats pour trancher.
///
/// Deux illustrations distinctes sont séparées d'une quinzaine de bits ; si les
/// deux premiers candidats sont plus serrés que cela, rien ne permet de choisir.
const int minConfidenceMargin = 4;

/// Une carte candidate et sa distance à l'empreinte recherchée.
typedef HashMatch = ({String oracleId, int distance});

/// Résultat d'une recherche.
class HashSearchResult {
  const HashSearchResult(this.candidates);

  /// Candidats classés par distance croissante.
  final List<HashMatch> candidates;

  HashMatch? get best => candidates.isEmpty ? null : candidates.first;

  /// Écart entre le meilleur candidat et le suivant, ou `null` s'il est seul.
  int? get margin => candidates.length < 2
      ? null
      : candidates[1].distance - candidates[0].distance;

  /// Vrai lorsque la correspondance peut être proposée sans réserve.
  ///
  /// Un candidat isolé est jugé fiable dès lors qu'il est assez proche : il n'y
  /// a rien avec quoi le confondre.
  bool get isConfident {
    final top = best;
    if (top == null || top.distance > maxTrustedDistance) return false;
    final gap = margin;
    return gap == null || gap >= minConfidenceMargin;
  }
}

/// Une entrée de l'index.
typedef IndexEntry = ({String oracleId, ArtHash hash});

class ArtHashIndex {
  ArtHashIndex._(this._hashes, this._oracleIds);

  /// Empreintes concaténées, [hashBytes] octets par carte. Un tableau contigu
  /// plutôt qu'une liste d'objets : moins d'allocations, et un parcours qui
  /// reste dans le cache processeur.
  final Uint8List _hashes;
  final List<String> _oracleIds;

  int get length => _oracleIds.length;

  factory ArtHashIndex.fromEntries(List<IndexEntry> entries) {
    final hashes = Uint8List(entries.length * hashBytes);
    final ids = <String>[];
    for (var i = 0; i < entries.length; i++) {
      hashes.setRange(
        i * hashBytes,
        (i + 1) * hashBytes,
        entries[i].hash.bytes,
      );
      ids.add(entries[i].oracleId);
    }
    return ArtHashIndex._(hashes, ids);
  }

  /// Cherche les cartes dont l'empreinte est la plus proche de [query].
  ///
  /// **On ne garde que les meilleures, on ne trie pas les autres.** Une
  /// première version construisait les trente-et-un mille distances puis les
  /// triait pour en prendre cinq : mesuré au banc (`tool/frame_bench.dart`),
  /// cela coûtait 5 à 7 ms sur un processeur de bureau — autant que la lecture
  /// et la conversion de l'image réunies, et donc bien davantage sur un
  /// téléphone. Le tri et les allocations n'étaient pas le prix de la
  /// recherche, ils étaient le prix de la mise en forme.
  ///
  /// La sélection ci-dessous garde un tampon de [limit] éléments, insérés à
  /// leur place. `limit` valant cinq, l'insertion est plus courte qu'une
  /// comparaison de fonction, et la boucle n'alloue plus rien.
  ///
  /// Effet de bord souhaitable : à distance égale, l'ordre du catalogue est
  /// désormais préservé — `List.sort` n'est pas stable en Dart, et deux appels
  /// identiques pouvaient rendre deux ordres.
  HashSearchResult search(ArtHash query, {int limit = 5}) {
    if (_oracleIds.isEmpty) return const HashSearchResult([]);

    final keep = limit < 1 ? 1 : limit;
    final q = query.bytes;

    // Distances des candidats retenus, triées ; `_kept` compte ce qui est
    // réellement rempli tant qu'on n'a pas vu `keep` cartes.
    final bestDistance = Int32List(keep);
    final bestIndex = Int32List(keep);
    var kept = 0;
    // Au-delà de cette distance, un candidat ne peut plus entrer : le test
    // rejette la quasi-totalité du catalogue en une comparaison.
    var worst = 1 << 30;

    for (var i = 0; i < _oracleIds.length; i++) {
      final base = i * hashBytes;
      var distance = 0;
      for (var b = 0; b < hashBytes; b++) {
        distance += _popcount[_hashes[base + b] ^ q[b]];
      }
      if (kept == keep && distance >= worst) continue;

      var at = kept < keep ? kept : keep - 1;
      while (at > 0 && bestDistance[at - 1] > distance) {
        bestDistance[at] = bestDistance[at - 1];
        bestIndex[at] = bestIndex[at - 1];
        at--;
      }
      bestDistance[at] = distance;
      bestIndex[at] = i;
      if (kept < keep) kept++;
      worst = bestDistance[kept - 1];
    }

    return HashSearchResult([
      for (var i = 0; i < kept; i++)
        (oracleId: _oracleIds[bestIndex[i]], distance: bestDistance[i]),
    ]);
  }

  /// Sérialise l'index pour le conserver localement.
  ///
  /// Format : `[nombre d'entrées : uint32]` puis, par entrée,
  /// `[empreinte : 8 octets][longueur de l'identifiant : uint8][identifiant UTF-8]`.
  /// La longueur est portée par chaque entrée plutôt que fixée, pour ne pas
  /// dépendre du format des identifiants.
  Uint8List toBytes() {
    final builder = BytesBuilder();
    final count = ByteData(4)..setUint32(0, length, Endian.little);
    builder.add(count.buffer.asUint8List());

    for (var i = 0; i < length; i++) {
      builder.add(_hashes.sublist(i * hashBytes, (i + 1) * hashBytes));
      final id = utf8.encode(_oracleIds[i]);
      if (id.length > 255) {
        throw ArgumentError('identifiant trop long : ${_oracleIds[i]}');
      }
      builder.addByte(id.length);
      builder.add(id);
    }
    return builder.toBytes();
  }

  factory ArtHashIndex.fromBytes(Uint8List bytes) {
    if (bytes.length < 4) {
      throw ArgumentError('index tronqué : ${bytes.length} octets');
    }
    final view = ByteData.sublistView(bytes);
    final count = view.getUint32(0, Endian.little);

    final entries = <IndexEntry>[];
    var offset = 4;
    for (var i = 0; i < count; i++) {
      if (offset + hashBytes + 1 > bytes.length) {
        throw ArgumentError('index tronqué à l\'entrée $i');
      }
      final hash = ArtHash(
        Uint8List.fromList(bytes.sublist(offset, offset + hashBytes)),
      );
      offset += hashBytes;
      final idLength = bytes[offset];
      offset += 1;
      if (offset + idLength > bytes.length) {
        throw ArgumentError('identifiant tronqué à l\'entrée $i');
      }
      final id = utf8.decode(bytes.sublist(offset, offset + idLength));
      offset += idLength;
      entries.add((oracleId: id, hash: hash));
    }
    return ArtHashIndex.fromEntries(entries);
  }
}

/// Nombre de bits à 1 dans un octet, précalculé.
final Uint8List _popcount = Uint8List.fromList([
  for (var i = 0; i < 256; i++)
    i.toRadixString(2).split('').where((c) => c == '1').length,
]);

/// Recherche à partir de plusieurs empreintes candidates.
///
/// Une carte photographiée produit une empreinte par cadre possible ; on ignore
/// lequel s'applique. Chaque hypothèse est donc cherchée, et la meilleure
/// l'emporte — un mauvais gabarit découpe l'illustration de travers et produit
/// une empreinte éloignée de tout, il ne peut pas gagner par hasard.
extension MultiQuerySearch on ArtHashIndex {
  ({HashSearchResult result, K? source}) searchAny<K>(
    Map<K, ArtHash> queries, {
    int limit = 5,
  }) {
    HashSearchResult? best;
    K? source;

    for (final entry in queries.entries) {
      final candidate = search(entry.value, limit: limit);
      final currentBest = best?.best?.distance;
      final candidateBest = candidate.best?.distance;
      if (candidateBest == null) continue;
      if (currentBest == null || candidateBest < currentBest) {
        best = candidate;
        source = entry.key;
      }
    }

    return (result: best ?? const HashSearchResult([]), source: source);
  }
}
