/// La composition d'URL d'illustration, et le défaut qu'elle répare.
///
/// **Aucune illustration Pokémon ne s'affichait dans l'application** — ni dans
/// la recherche, ni dans les classeurs, ni dans les aperçus — depuis
/// l'ingestion du jeu. TCGdex publie une base et refuse de la servir nue ; le
/// jumeau Dart d'`image_url()` n'existait pas.
///
/// Le symptôme était une vignette vide, c'est-à-dire exactement ce qu'affiche
/// une carte dont la source n'a pas encore répondu. Rien ne distinguait la
/// panne de la lenteur, et il a fallu ouvrir Pokémon sur l'appareil pour la
/// voir.
library;

import 'package:deckhand/src/common/card_art_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TCGdex exige une qualité', () {
    test('une base nue reçoit son suffixe', () {
      expect(
        cardArtUrl('https://assets.tcgdex.net/en/pl/pl4/1'),
        'https://assets.tcgdex.net/en/pl/pl4/1/high.png',
      );
    });

    test('une barre finale n_est pas doublée', () {
      // La doubler donnerait un 404, soit le défaut qu'on corrige.
      expect(
        cardArtUrl('https://assets.tcgdex.net/en/pl/pl4/1/'),
        'https://assets.tcgdex.net/en/pl/pl4/1/high.png',
      );
    });

    test('la composition est idempotente', () {
      // L'appelant ne sait pas toujours si l'URL a déjà été composée ; deux
      // passages ne doivent pas produire `/high.png/high.png`.
      const composee = 'https://assets.tcgdex.net/en/pl/pl4/1/high.png';
      expect(cardArtUrl(composee), composee);
      expect(cardArtUrl(cardArtUrl(composee)), composee);
    });
  });

  group('les sept autres sources servent des URL complètes', () {
    test('elles traversent sans être touchées', () {
      const intactes = [
        'https://cards.scryfall.io/art_crop/front/f/e/fefbf149.jpg',
        'https://images.ygoprodeck.com/images/cards/89631139.jpg',
        'https://cmsassets.rgpub.io/sanity/images/dsfx7636/a7fe105f.png',
        'https://cdn.swu-db.com/images/cards/ASH/924.png',
        'https://optcgapi.com/media/static/Card_Images/OP01-024_p3.jpg',
        'https://cards.lorcast.io/card/digital/normal/crd_a9407e39.avif',
        'https://udqoptxqipmxqwfhgted.supabase.co/storage/v1/object/public/'
            'card-art/wankul/normal/abc.jpg',
      ];
      for (final url in intactes) {
        expect(cardArtUrl(url), url, reason: url);
      }
    });

    test('le test porte sur l_hôte, pas sur le jeu', () {
      // L'appelant ne connaît pas toujours le jeu de la carte qu'il affiche,
      // alors qu'il a toujours son URL. Une URL d'un autre hôte contenant
      // « tcgdex » dans son chemin ne doit pas être touchée.
      const etranger = 'https://exemple.test/tcgdex/carte.png';
      expect(cardArtUrl(etranger), etranger);
    });
  });
}
