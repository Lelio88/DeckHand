/// Les deux tailles d'image, déduites de l'URL — pour Scryfall et pour le dépôt.
///
/// **Ce que ces tests protègent, et pourquoi il n'y avait rien.** Le catalogue
/// ne stocke qu'une URL par impression ; la carte entière et sa vignette légère
/// s'en déduisent par substitution de segment. C'est gratuit tant que les
/// sources nomment leurs tailles pareil, et invisible le jour où l'une cesse de
/// le faire : la vignette redevient `null`, la grande arrive seule, et la page
/// de classeur met sept fois plus longtemps à dire quelque chose sans qu'aucune
/// erreur ne soit levée.
///
/// **Le dépôt d'images de DeckHand calque cette convention exprès.** Les rendus
/// Wankul sont hébergés — leur éditeur l'a autorisé, son CDN refusant de les
/// servir — sous `.../normal/<id>.jpg` et `.../small/<id>.jpg`. Ce choix a
/// évité d'ajouter un cas particulier dans un module que les cinq jeux
/// partagent ; encore faut-il qu'il reste vrai des deux côtés.
library;

import 'package:deckhand/src/features/printings/domain/scryfall_image.dart';
import 'package:flutter_test/flutter_test.dart';

/// Une URL du dépôt, telle que `app/card_art.py` la compose.
const _depot =
    'https://abc.supabase.co/storage/v1/object/public/card-art/'
    'wankul/normal/b4372ef1-1c81-4d21-a91e-2c281cf86103.jpg';

const _scryfall =
    'https://cards.scryfall.io/art_crop/front/e/0/e040b456-1234.jpg?178';

void main() {
  group('le dépôt d\'images', () {
    test('sa grande image est servie telle quelle', () {
      // Elle ne porte pas `/art_crop/` : rien à substituer, et surtout rien à
      // casser. Une URL qui le porterait serait réécrite et pointerait à côté.
      expect(fullCardImage(_depot), _depot);
    });

    test('sa vignette légère se déduit du segment de taille', () {
      expect(
        previewCardImage(_depot),
        'https://abc.supabase.co/storage/v1/object/public/card-art/'
        'wankul/small/b4372ef1-1c81-4d21-a91e-2c281cf86103.jpg',
      );
    });

    test('un seul segment est remplacé, pas le nom du bucket', () {
      // `card-art` ressemble à `art_crop` de loin ; la substitution ne doit
      // toucher que le segment de taille.
      expect(previewCardImage(_depot), contains('/card-art/'));
    });
  });

  group('Scryfall', () {
    test('la carte entière se déduit de l\'illustration', () {
      expect(fullCardImage(_scryfall), contains('/normal/'));
      expect(fullCardImage(_scryfall), isNot(contains('/art_crop/')));
    });

    test('la vignette légère aussi', () {
      expect(previewCardImage(_scryfall), contains('/small/'));
    });
  });

  test('une URL hors convention garde sa grande et perd sa vignette', () {
    // Le repli est asymétrique et c'est voulu : mieux vaut afficher l'image
    // qu'on a que rien du tout, mais inventer une vignette qui n'existe pas
    // ferait clignoter la grille sur des 404.
    const inconnue = 'https://exemple.test/une/image.jpg';
    expect(fullCardImage(inconnue), inconnue);
    expect(previewCardImage(inconnue), isNull);
  });

  test('une URL absente ou vide ne produit rien', () {
    expect(fullCardImage(null), isNull);
    expect(fullCardImage(''), isNull);
    expect(previewCardImage(null), isNull);
    expect(previewCardImage(''), isNull);
  });
}
