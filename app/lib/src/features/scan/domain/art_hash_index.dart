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
typedef HashMatch = ({String oracleId, String printId, int distance});

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
///
/// **Deux identités, pas une.** `oracleId` désigne la carte ; `printId` désigne
/// l'**impression** dont l'illustration a produit cette empreinte. Une carte
/// Magic sur quatre en porte plusieurs (7 853 sur 32 808), si bien que rendre la
/// seule carte laissait l'écran afficher une autre version que celle scannée —
/// et la confirmation exigée au §IV.8 devient impossible à donner en conscience
/// quand la vignette montre autre chose que ce qu'on tient.
typedef IndexEntry = ({String oracleId, String printId, ArtHash hash});

/// Marque de format du cache local.
///
/// Change dès que la disposition des octets change. Sans elle, un cache écrit
/// par une version antérieure serait relu de travers — et un index mal relu ne
/// plante pas, il reconnaît mal.
const int _formatMark = 0x44484132; // « DHA2 »

class ArtHashIndex {
  ArtHashIndex._(this._hashes, this._oracleIds, this._printIds);

  /// Empreintes concaténées, [hashBytes] octets par carte. Un tableau contigu
  /// plutôt qu'une liste d'objets : moins d'allocations, et un parcours qui
  /// reste dans le cache processeur.
  final Uint8List _hashes;
  final List<String> _oracleIds;

  /// L'impression dont vient chaque empreinte, parallèle à [_oracleIds].
  final List<String> _printIds;

  int get length => _oracleIds.length;

  factory ArtHashIndex.fromEntries(List<IndexEntry> entries) {
    final hashes = Uint8List(entries.length * hashBytes);
    final ids = <String>[];
    final prints = <String>[];
    for (var i = 0; i < entries.length; i++) {
      hashes.setRange(
        i * hashBytes,
        (i + 1) * hashBytes,
        entries[i].hash.bytes,
      );
      ids.add(entries[i].oracleId);
      prints.add(entries[i].printId);
    }
    return ArtHashIndex._(hashes, ids, prints);
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
        (
          oracleId: _oracleIds[bestIndex[i]],
          printId: _printIds[bestIndex[i]],
          distance: bestDistance[i],
        ),
    ]);
  }

  /// La meilleure impression **parmi celles de cartes déjà identifiées**.
  ///
  /// **L'empreinte cesse d'identifier la carte pour ne plus faire que choisir
  /// l'édition** — et c'est là qu'elle est bonne. Chercher dans les 32 808
  /// illustrations du catalogue exige un cadrage juste à 3 % près et une photo
  /// sans reflet : mesuré, une carte tenue à la main plafonne à 14 ou 19 bits de
  /// sa propre référence, quand le seuil de confiance est à 12. La même
  /// empreinte, comparée aux deux ou trois illustrations d'**une** carte, les
  /// départage sans peine — les rivales y sont à trente bits, pas à douze.
  ///
  /// Le nom, lui, se lit malgré les reflets et ne dépend d'aucune édition :
  /// c'est l'ordre que le mode photo suit déjà, et que celui-ci rend praticable
  /// jusqu'au choix de l'impression.
  ///
  /// Rend `null` si aucune entrée ne porte l'une des cartes demandées — un
  /// catalogue peut connaître une carte sans posséder d'empreinte pour elle.
  HashMatch? searchWithin(Set<String> oracleIds, ArtHash query) {
    if (oracleIds.isEmpty) return null;
    final q = query.bytes;
    var meilleur = 1 << 30;
    var rang = -1;
    for (var i = 0; i < _oracleIds.length; i++) {
      if (!oracleIds.contains(_oracleIds[i])) continue;
      final base = i * hashBytes;
      var distance = 0;
      for (var b = 0; b < hashBytes; b++) {
        distance += _popcount[_hashes[base + b] ^ q[b]];
      }
      if (distance < meilleur) {
        meilleur = distance;
        rang = i;
      }
    }
    if (rang < 0) return null;
    return (
      oracleId: _oracleIds[rang],
      printId: _printIds[rang],
      distance: meilleur,
    );
  }

  /// Sérialise l'index pour le conserver localement.
  ///
  /// Format : `[marque : uint32][nombre d'entrées : uint32]` puis, par entrée,
  /// `[empreinte : 8 octets]` suivi de deux identifiants, chacun
  /// `[longueur : uint8][UTF-8]` — la carte, puis l'impression.
  ///
  /// **La marque existe pour rejeter un cache d'une version antérieure.** Le
  /// format n'en portait pas : ajouter un champ aurait fait relire les anciens
  /// caches de travers, sans rien pour le signaler. Un index mal relu ne plante
  /// pas, il reconnaît mal — c'est le pire des deux.
  Uint8List toBytes() {
    final builder = BytesBuilder();
    final header = ByteData(8)
      ..setUint32(0, _formatMark, Endian.little)
      ..setUint32(4, length, Endian.little);
    builder.add(header.buffer.asUint8List());

    void ecrire(String valeur) {
      final id = utf8.encode(valeur);
      if (id.length > 255) {
        throw ArgumentError('identifiant trop long : $valeur');
      }
      builder.addByte(id.length);
      builder.add(id);
    }

    for (var i = 0; i < length; i++) {
      builder.add(_hashes.sublist(i * hashBytes, (i + 1) * hashBytes));
      ecrire(_oracleIds[i]);
      ecrire(_printIds[i]);
    }
    return builder.toBytes();
  }

  factory ArtHashIndex.fromBytes(Uint8List bytes) {
    if (bytes.length < 8) {
      throw ArgumentError('index tronqué : ${bytes.length} octets');
    }
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(0, Endian.little) != _formatMark) {
      throw ArgumentError('index d\'un autre format : à retélécharger');
    }
    final count = view.getUint32(4, Endian.little);

    var offset = 8;
    String lire(int i) {
      if (offset + 1 > bytes.length) {
        throw ArgumentError('identifiant tronqué à l\'entrée $i');
      }
      final len = bytes[offset];
      offset += 1;
      if (offset + len > bytes.length) {
        throw ArgumentError('identifiant tronqué à l\'entrée $i');
      }
      final valeur = utf8.decode(bytes.sublist(offset, offset + len));
      offset += len;
      return valeur;
    }

    final entries = <IndexEntry>[];
    for (var i = 0; i < count; i++) {
      if (offset + hashBytes + 1 > bytes.length) {
        throw ArgumentError('index tronqué à l\'entrée $i');
      }
      final hash = ArtHash(
        Uint8List.fromList(bytes.sublist(offset, offset + hashBytes)),
      );
      offset += hashBytes;
      final oracleId = lire(i);
      final printId = lire(i);
      entries.add((oracleId: oracleId, printId: printId, hash: hash));
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
  ({HashSearchResult result, K? source, bool isConfident}) searchAny<K>(
    Map<K, ArtHash> queries, {
    int limit = 5,
    Set<K>? eligibles,
  }) {
    HashSearchResult? best;
    K? source;
    final parHypothese = <K, HashSearchResult>{};

    for (final entry in queries.entries) {
      final candidate = search(entry.value, limit: limit);
      parHypothese[entry.key] = candidate;
      // **Toutes les hypothèses sont cherchées, toutes ne peuvent pas régner.**
      // [eligibles] écarte de l'élection celles que l'appelant sait
      // invraisemblables — une carte lue à l'envers alors que son texte vient
      // d'être déchiffré à l'endroit. Leurs candidats restent dans la fusion :
      // si le jugement de l'appelant était faux, on perd la confiance, jamais
      // la bonne réponse.
      if (eligibles != null && !eligibles.contains(entry.key)) continue;
      final currentBest = best?.best?.distance;
      final candidateBest = candidate.best?.distance;
      if (candidateBest == null) continue;
      if (currentBest == null || candidateBest < currentBest) {
        best = candidate;
        source = entry.key;
      }
    }

    // **La fusion se fait même sans vainqueur élu.** Quand aucune hypothèse
    // éligible n'a rien trouvé, les autres ont peut-être quelque chose à
    // proposer : rendre une liste vide priverait l'écran des candidats à
    // départager, qui sont précisément ce qu'il sait faire d'un doute.
    //
    // **Les candidats des hypothèses perdantes ne sont plus jetés.** Seule la
    // liste de l'hypothèse gagnante survivait, et c'est ce qui a fait échouer
    // une reconnaissance pourtant correcte : sur une carte japonaise premium
    // sous pochette, le bon gabarit plaçait la bonne carte **en première
    // position** à 14 bits, quand un découpage absurde — cadre moderne lu à
    // l'envers sur une carte de 2002 — tombait par hasard à 11 bits d'une
    // autre. Le hasard gagnait, et la bonne réponse disparaissait de l'écran
    // au lieu d'y figurer parmi les candidats à départager.
    //
    // La fusion garde le meilleur relevé de chaque carte, toutes hypothèses
    // confondues : une carte ne peut plus être écartée parce qu'un *autre*
    // découpage a mieux marché ailleurs.
    // **Une hypothèse écartée de l'élection n'apporte pas non plus de
    // candidats**, dès lors qu'une éligible a répondu. Mesuré sur la carte qui
    // a motivé ce code : les trois candidats qui devançaient la bonne réponse
    // venaient *tous* des découpages retournés. Les garder « au cas où »
    // revenait à remplir la liste de bruit tiré au sort dans 51 000 empreintes,
    // et à en chasser la seule entrée qui voulait dire quelque chose.
    //
    // Le repli reste entier : si aucune éligible n'a rien trouvé, on fusionne
    // tout, car une liste de bruit vaut mieux qu'une liste vide.
    final retenues = (best == null || eligibles == null)
        ? parHypothese.entries
        : parHypothese.entries.where((e) => eligibles.contains(e.key));

    final meilleurParCarte = <String, HashMatch>{};
    for (final resultat in retenues) {
      for (final c in resultat.value.candidates) {
        final vu = meilleurParCarte[c.oracleId];
        if (vu == null || c.distance < vu.distance) {
          meilleurParCarte[c.oracleId] = c;
        }
      }
    }
    final fusionnes = meilleurParCarte.values.toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));
    final fusion = HashSearchResult(
      fusionnes.take(limit).toList(growable: false),
    );
    final margeFusionnee = fusion.margin;

    return (
      result: fusion,
      source: source,
      // **Deux marges à franchir : celle de l'hypothèse gagnante, puis celle
      // de la fusion.** La première dit si deux illustrations sont trop
      // proches pour être départagées à découpage constant. La seconde dit si
      // un **autre** découpage désigne une autre carte presque aussi bien —
      // et c'est exactement la signature d'une annonce tirée au sort : sur une
      // photo d'étalement ou une carte scindée, un gabarit tombe par hasard à
      // 7 à 12 bits d'une carte absente, avec une marge propre confortable,
      // pendant qu'un autre désigne une autre carte à un ou deux bits de là.
      //
      // **Mesuré sur le banc de photos réelles** (carte seule, étalements et
      // fonds nus), lecture projective : la marge propre seule annonçait sans
      // réserve 13 justes et 5 fausses ; la double garde en annonce 7 et
      // **aucune fausse**. Les
      // six justes perdues ne disparaissent pas : elles restent **en tête**
      // des candidats, à un geste de confirmation — que le §IV.8 exige de
      // toute façon. Une carte franche garde sa confiance : sans pochette, la
      // japonaise ressort à 4 bits avec 9 de marge, fusion comprise.
      isConfident:
          (best?.isConfident ?? false) &&
          (margeFusionnee == null || margeFusionnee >= minConfidenceMargin),
    );
  }
}
