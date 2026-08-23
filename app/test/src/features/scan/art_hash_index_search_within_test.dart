/// Choisir l'édition quand la carte est déjà connue (#8).
///
/// **Ce que ces tests protègent.** L'empreinte échoue à identifier une carte
/// dès que la photo porte des reflets — mesuré, une carte tenue à la main
/// plafonne à 14 ou 19 bits de sa propre référence, quand le seuil de confiance
/// est à 12. Mais départager les deux ou trois illustrations d'**une** carte
/// connue est un tout autre problème : les rivales y sont à trente bits.
library;

import 'dart:typed_data';

import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:flutter_test/flutter_test.dart';

ArtHash empreinte(int graine) => ArtHash(
  Uint8List.fromList([
    for (var b = 0; b < hashBytes; b++) (graine * 37 + b * 101) % 256,
  ]),
);

/// La même empreinte, abîmée de [bits] bits — ce que fait une photo médiocre.
ArtHash abimee(ArtHash source, int bits) {
  final octets = Uint8List.fromList(source.bytes);
  for (var i = 0; i < bits; i++) {
    octets[i % octets.length] ^= 1 << (i ~/ octets.length);
  }
  return ArtHash(octets);
}

void main() {
  final alpha1 = empreinte(1);
  final alpha2 = empreinte(2);
  final autre = empreinte(3);
  final index = ArtHashIndex.fromEntries([
    (oracleId: 'alpha', printId: 'alpha-a', hash: alpha1),
    (oracleId: 'alpha', printId: 'alpha-b', hash: alpha2),
    (oracleId: 'beta', printId: 'beta-a', hash: autre),
  ]);

  test('une empreinte trop abîmée pour le catalogue départage l’édition', () {
    // Vingt bits : bien au-delà du seuil de confiance, donc invisible pour la
    // recherche ordinaire. Entre deux éditions, l'écart reste franc.
    final vue = abimee(alpha1, 20);

    expect(index.search(vue).isConfident, isFalse);

    final choix = index.searchWithin({'alpha'}, vue);
    expect(choix, isNotNull);
    expect(choix!.printId, 'alpha-a');
  });

  test('la recherche restreinte ignore les cartes non demandées', () {
    // Même exacte, une empreinte d'une autre carte ne doit pas remonter : la
    // carte a été identifiée par son nom, on ne la remet pas en cause.
    final choix = index.searchWithin({'alpha'}, autre);

    expect(choix, isNotNull);
    expect(choix!.oracleId, 'alpha');
  });

  test('une carte sans empreinte ne rend rien plutôt qu’une voisine', () {
    // Le catalogue connaît des cartes dont aucune illustration n'est indexée ;
    // rendre le plus proche voisin d'une autre carte serait un faux positif.
    expect(index.searchWithin({'gamma'}, alpha1), isNull);
    expect(index.searchWithin(const {}, alpha1), isNull);
  });
}
