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
  HashSearchResult search(ArtHash query, {int limit = 5}) {
    if (_oracleIds.isEmpty) return const HashSearchResult([]);

    final matches = <HashMatch>[];
    final q = query.bytes;

    for (var i = 0; i < _oracleIds.length; i++) {
      final base = i * hashBytes;
      var distance = 0;
      for (var b = 0; b < hashBytes; b++) {
        distance += _popcount[_hashes[base + b] ^ q[b]];
      }
      matches.add((oracleId: _oracleIds[i], distance: distance));
    }

    matches.sort((a, b) => a.distance.compareTo(b.distance));
    return HashSearchResult(
      matches.take(limit < 1 ? 1 : limit).toList(growable: false),
    );
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
