/// Tests du découpage de l'illustration et de la recherche multi-gabarits.
library;

import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/card_bounds.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Fausse carte : un fond uni, et une zone d'illustration texturée à
/// l'emplacement du cadre demandé.
img.Image fakeCard(CardFrame frame, {int width = 400, int height = 560}) {
  final card = img.Image(width: width, height: height);
  img.fill(card, color: img.ColorRgb8(30, 30, 30));

  final box = frame.box;
  final x0 = (box.left * width).round();
  final y0 = (box.top * height).round();
  final x1 = (box.right * width).round();
  final y1 = (box.bottom * height).round();

  for (var x = x0; x < x1; x++) {
    for (var y = y0; y < y1; y++) {
      card.setPixelRgb(x, y, (x * 5) % 256, (y * 3) % 256, (x + y) % 256);
    }
  }
  return card;
}

void main() {
  group('découpage', () {
    test('les proportions découpées correspondent au gabarit', () {
      final card = img.Image(width: 400, height: 560);
      final crop = cropArt(card, CardFrame.modern);
      final box = CardFrame.modern.box;

      expect(crop.width, ((box.right - box.left) * 400).round());
      expect(crop.height, ((box.bottom - box.top) * 560).round());
    });

    test('les deux gabarits ne découpent pas la même zone', () {
      final card = img.Image(width: 400, height: 560);
      expect(
        cropArt(card, CardFrame.modern).width,
        isNot(cropArt(card, CardFrame.legacy).width),
      );
    });

    test('une image minuscule ne fait pas échouer le découpage', () {
      final crop = cropArt(img.Image(width: 4, height: 6), CardFrame.modern);
      expect(crop.width, greaterThan(0));
      expect(crop.height, greaterThan(0));
    });

    test('une carte produit une empreinte par cadre de son jeu', () {
      final candidates = artHashCandidates(fakeCard(CardFrame.modern));

      expect(
        candidates.keys.map((h) => h.frame),
        containsAll(CardFrame.values.where((f) => f.game == 'magic')),
      );
    });

    test("les cadres d'un autre jeu ne sont pas essayés", () {
      // Découper une carte Magic au gabarit Riftbound produit une empreinte qui
      // ne veut plus rien dire, mais qui peut rencontrer par hasard une entrée
      // de l'index. Le pipeline est mesuré à zéro faux positif annoncé avec
      // assurance : c'est ce résultat que le cloisonnement protège.
      final magic = artHashCandidates(fakeCard(CardFrame.modern));
      final riftbound = artHashCandidates(
        fakeCard(CardFrame.modern),
        game: 'riftbound',
      );

      expect(magic.keys.every((h) => h.frame.game == 'magic'), isTrue);
      expect(riftbound.keys.every((h) => h.frame.game == 'riftbound'), isTrue);
      expect(magic.keys.toSet().intersection(riftbound.keys.toSet()), isEmpty);
    });
  });

  group('recherche multi-gabarits', () {
    test('le bon cadre est retenu', () {
      // L'index ne contient que l'illustration telle qu'un cadre moderne la cadre.
      final card = fakeCard(CardFrame.modern);
      final reference = computeArtHash(cropArt(card, CardFrame.modern));
      final index = ArtHashIndex.fromEntries([
        (oracleId: 'cible', printId: 'cible', hash: reference),
      ]);

      final outcome = index.searchAny(artHashCandidates(card));

      expect(outcome.source?.frame, CardFrame.modern);
      expect(outcome.result.best?.oracleId, 'cible');
      expect(outcome.result.best?.distance, 0);
    });

    test('un index vide ne renvoie rien', () {
      final outcome = ArtHashIndex.fromEntries(
        [],
      ).searchAny(artHashCandidates(fakeCard(CardFrame.modern)));
      expect(outcome.result.best, isNull);
      expect(outcome.source, isNull);
    });
  });

  group('cartes couchées', () {
    // Un quadrilatère droit, aux proportions d'une carte : c'est ce que rend la
    // détection quand une carte couchée est glissée dans une pochette verticale
    // — ce sont les bords de la pochette qu'elle trouve.
    const upright = CardQuad(
      topLeft: (x: 0, y: 0),
      topRight: (x: 716, y: 0),
      bottomRight: (x: 716, y: 1000),
      bottomLeft: (x: 0, y: 1000),
    );
    const landscape = CardQuad(
      topLeft: (x: 0, y: 0),
      topRight: (x: 1000, y: 0),
      bottomRight: (x: 1000, y: 716),
      bottomLeft: (x: 0, y: 716),
    );

    test('quatre quarts de tour rendent le quadrilatère de départ', () {
      final back = upright.quarterTurned(1).quarterTurned(3);
      expect(back.topLeft, upright.topLeft);
      expect(back.topRight, upright.topRight);
      expect(back.bottomRight, upright.bottomRight);
      expect(back.bottomLeft, upright.bottomLeft);
    });

    test('un quart de tour déplace les coins sans bouger un pixel', () {
      final turned = upright.quarterTurned(1);
      expect(turned.topLeft, upright.bottomLeft);
      expect(turned.topRight, upright.topLeft);
      expect(turned.bottomRight, upright.topRight);
      expect(turned.bottomLeft, upright.bottomRight);
      // Le quadrilatère tourné couvre exactement la même zone.
      expect(turned.aspect, closeTo(1 / upright.aspect, 0.001));
    });

    test('le demi-tour n\'est pas l\'identité', () {
      // Une empreinte n'y survit pas : mesuré sur du carton, la même carte lue
      // dans le mauvais sens passe du rang 1 au rang 185.
      expect(upright.quarterTurned(2).topLeft, isNot(upright.topLeft));
    });

    test(
      'un cadre couché est cherché dans les deux sens sur un quad droit',
      () {
        final photo = img.Image(width: 800, height: 1100);
        final keys = artHashCandidatesInQuad(
          photo,
          upright,
          game: 'riftbound',
        ).keys.toSet();

        expect(keys, contains((frame: CardFrame.riftbound, quarterTurns: 0)));
        expect(
          keys,
          contains((frame: CardFrame.riftboundWide, quarterTurns: 1)),
        );
        expect(
          keys,
          contains((frame: CardFrame.riftboundWide, quarterTurns: 3)),
        );
        // La lecture droite du cadre couché est remplacée, pas complétée : elle
        // ne peut rien identifier, mais elle tirerait une fois de plus dans
        // l'index.
        expect(
          keys,
          isNot(contains((frame: CardFrame.riftboundWide, quarterTurns: 0))),
        );
      },
    );

    test('un cadre droit dans un quad couché est redressé, pas lu tel quel', () {
      // **La réciproque est faite, et l'ancien refus se trompait de
      // conclusion.** Il disait : « une carte debout ne se présente pas
      // couchée, donc un quadrilatère couché signale une détection fausse ».
      // Sur 36 photos réelles, treize montrent un carton posé de travers : la
      // prémisse est fausse.
      //
      // Mais il avait raison sur le danger. La lecture *telle quelle* — tour 0
      // d'un cadre droit dans un quadrilatère couché — prélève l'empreinte sur
      // une bande de texte, et c'est exactement l'hypothèse qui a produit les
      // deux cartes inventées du banc. Elle est donc **remplacée** par les deux
      // quarts de tour, jamais complétée.
      final photo = img.Image(width: 1100, height: 800);
      for (final game in ['magic', 'yugioh']) {
        final keys = artHashCandidatesInQuad(
          photo,
          landscape,
          game: game,
        ).keys.toSet();

        expect(
          keys.map((h) => h.quarterTurns).toSet(),
          {1, 3},
          reason: '$game : un carton couché ne se lit que redressé',
        );
      }
    });

    test('un carton debout admet le demi-tour, pas le quart de tour', () {
      // Une carte posée à l'envers donne un quadrilatère **debout** : seul le
      // demi-tour la redresse, et une empreinte n'y survit pas. Le banc en
      // compte une, et elle n'était pas reconnue.
      final photo = img.Image(width: 800, height: 1100);
      for (final game in ['magic', 'yugioh']) {
        final keys = artHashCandidatesInQuad(
          photo,
          upright,
          game: game,
        ).keys.toSet();

        expect(
          keys.map((h) => h.quarterTurns).toSet(),
          {0, 2},
          reason: '$game : un quart de tour coucherait une carte debout',
        );
      }
    });

    test('le rapport du quadrilatère élimine la moitié des sens', () {
      // **Deux hypothèses par cadre, jamais quatre.** Chaque hypothèse est un
      // tirage de plus dans l'index, avec sa chance de passer les deux
      // garde-fous sur du bruit. Mesuré sur le banc réel : les quatre sens
      // rendent 8 cartes justes et 2 inventées, les deux sens que le rapport
      // autorise en rendent 8 et 1 — le sens géométriquement impossible
      // n'apportait que le faux positif.
      for (final quad in [upright, landscape]) {
        for (final game in ['magic', 'yugioh', 'riftbound']) {
          final keys = artHashCandidatesInQuad(
            img.Image(width: 800, height: 1100),
            quad,
            game: game,
          ).keys.toList();

          expect(
            keys.length,
            2 * keys.map((h) => h.frame).toSet().length,
            reason: '$game, quadrilatère de rapport ${quad.aspect}',
          );
        }
      }
    });

    test('la carte couchée se retrouve par son quart de tour', () {
      // L'index ne porte que l'illustration telle qu'elle est cadrée sur la
      // carte couchée. La photo, elle, la présente droite — c'est le cas de la
      // pochette. Seule une hypothèse tournée peut retomber dessus.
      final wide = fakeCard(CardFrame.riftboundWide, width: 1000, height: 716);
      final index = ArtHashIndex.fromEntries([
        (
          oracleId: 'champ-de-bataille',
          printId: 'champ-de-bataille',
          hash: computeArtHash(cropArt(wide, CardFrame.riftboundWide)),
        ),
      ]);

      // La même carte, posée droite dans la photo : on la tourne d'un quart.
      final asPhotographed = img.copyRotate(wide, angle: 90);
      final quad = CardQuad(
        topLeft: (x: 0, y: 0),
        topRight: (x: asPhotographed.width.toDouble(), y: 0),
        bottomRight: (
          x: asPhotographed.width.toDouble(),
          y: asPhotographed.height.toDouble(),
        ),
        bottomLeft: (x: 0, y: asPhotographed.height.toDouble()),
      );

      final outcome = index.searchAny(
        artHashCandidatesInQuad(asPhotographed, quad, game: 'riftbound'),
      );

      expect(outcome.source?.frame, CardFrame.riftboundWide);
      expect(outcome.source?.quarterTurns, isNot(0));
      expect(outcome.result.best?.oracleId, 'champ-de-bataille');
      // Le rééchantillonnage n'est pas exact au bit près ; ce qui compte est
      // que la bonne carte soit trouvée, et de très près.
      expect(
        outcome.result.best?.distance,
        lessThanOrEqualTo(maxTrustedDistance),
      );
    });

    test('un carton Magic posé de travers se retrouve', () {
      // **Le gain que la mesure a chiffré, tenu par un test.** Treize photos du
      // banc réel montrent un carton Magic couché ; aucune n'était reconnue,
      // parce qu'un gabarit droit n'était essayé que dans un seul sens.
      final carte = fakeCard(CardFrame.modern);
      final index = ArtHashIndex.fromEntries([
        (
          oracleId: 'carte-posee-de-travers',
          printId: 'carte-posee-de-travers',
          hash: computeArtHash(cropArt(carte, CardFrame.modern)),
        ),
      ]);

      // La même carte, posée en travers sur la table.
      final couchee = img.copyRotate(carte, angle: 90);
      final quad = CardQuad(
        topLeft: (x: 0, y: 0),
        topRight: (x: couchee.width.toDouble(), y: 0),
        bottomRight: (
          x: couchee.width.toDouble(),
          y: couchee.height.toDouble(),
        ),
        bottomLeft: (x: 0, y: couchee.height.toDouble()),
      );

      final outcome = index.searchAny(
        artHashCandidatesInQuad(couchee, quad, game: 'magic'),
      );

      expect(outcome.result.best?.oracleId, 'carte-posee-de-travers');
      expect(outcome.source?.quarterTurns, isNot(0));
      expect(
        outcome.result.best?.distance,
        lessThanOrEqualTo(maxTrustedDistance),
      );
    });

    test('un carton Magic posé à l\'envers se retrouve', () {
      // Le demi-tour compte autant que le quart : une empreinte n'y survit pas.
      final carte = fakeCard(CardFrame.modern);
      final index = ArtHashIndex.fromEntries([
        (
          oracleId: 'carte-a-l-envers',
          printId: 'carte-a-l-envers',
          hash: computeArtHash(cropArt(carte, CardFrame.modern)),
        ),
      ]);

      final envers = img.copyRotate(carte, angle: 180);
      final quad = CardQuad(
        topLeft: (x: 0, y: 0),
        topRight: (x: envers.width.toDouble(), y: 0),
        bottomRight: (x: envers.width.toDouble(), y: envers.height.toDouble()),
        bottomLeft: (x: 0, y: envers.height.toDouble()),
      );

      final outcome = index.searchAny(
        artHashCandidatesInQuad(envers, quad, game: 'magic'),
      );

      expect(outcome.result.best?.oracleId, 'carte-a-l-envers');
      expect(outcome.source?.quarterTurns, 2);
      expect(
        outcome.result.best?.distance,
        lessThanOrEqualTo(maxTrustedDistance),
      );
    });
  });
}
