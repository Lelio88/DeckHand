/// Tests de la reconnaissance d'une carte à partir d'une photo.
///
/// La photo est fabriquée : un décor autour d'une fausse carte, elle-même
/// porteuse d'une illustration texturée à l'emplacement du gabarit. On vérifie
/// que la chaîne complète — cadrage, découpe, empreinte, recherche — retrouve
/// bien la carte, et surtout qu'elle refuse de conclure quand elle ne le
/// devrait pas.
library;

import 'dart:typed_data';

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/scan/application/scan_service.dart';
import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/card_geometry.dart';
import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../helpers/fakes.dart';

/// Fausse carte : fond uni, illustration texturée dans la zone du gabarit.
img.Image fakeCard(CardFrame frame, {int seed = 0, int width = 400}) {
  // La fausse carte prend les proportions du jeu de son cadre : composer au
  // format d'un autre jeu déplacerait la zone d'illustration sans le dire.
  final height = (width / cardAspectFor(frame.game)).round();
  final card = img.Image(width: width, height: height);
  img.fill(card, color: img.ColorRgb8(28, 28, 34));

  final box = frame.box;
  final x0 = (box.left * width).round();
  final y0 = (box.top * height).round();
  final x1 = (box.right * width).round();
  final y1 = (box.bottom * height).round();

  for (var x = x0; x < x1; x++) {
    for (var y = y0; y < y1; y++) {
      card.setPixelRgb(
        x,
        y,
        (x * 7 + seed * 31) % 256,
        (y * 5 + seed * 17) % 256,
        (x + y + seed * 53) % 256,
      );
    }
  }
  return card;
}

/// Photo réaliste : la carte remplit la hauteur du cadre, du décor l'entoure
/// latéralement — ce que produit un cadrage dans le guide affiché à l'écran.
///
/// Le cadrage retient le plus grand rectangle aux proportions d'une carte : il
/// ne peut donc pas isoler une carte plus petite que l'image dans les deux
/// dimensions. C'est assumé — le guide de visée est là pour que l'utilisateur
/// remplisse le cadre.
Uint8List photoOf(img.Image card, {double widthFactor = 1.6}) {
  final photo = img.Image(
    width: (card.width * widthFactor).round(),
    height: card.height,
  );
  img.fill(photo, color: img.ColorRgb8(90, 70, 50));
  img.compositeImage(
    photo,
    card,
    dstX: (photo.width - card.width) ~/ 2,
    dstY: 0,
  );
  return Uint8List.fromList(img.encodePng(photo));
}

ArtHashIndex indexOf(Map<String, img.Image> cards, CardFrame frame) =>
    ArtHashIndex.fromEntries([
      for (final e in cards.entries)
        (oracleId: e.key, hash: computeArtHash(cropArt(e.value, frame))),
    ]);

void main() {
  test('une photo bien cadrée retrouve la carte', () async {
    final card = fakeCard(CardFrame.modern, seed: 1);
    final service = ScanService(
      indexOf({'cible': card}, CardFrame.modern),
      FakeCardTextReader(),
      FakeCardRepository(),
    );

    final outcome = await service.recognise(photoOf(card));

    expect(outcome.oracleIds.first, 'cible');
    expect(outcome.isConfident, isTrue);
    expect(outcome.frame, CardFrame.modern);
  });

  test('une carte au cadre ancien est reconnue aussi', () async {
    final card = fakeCard(CardFrame.legacy, seed: 2);
    final service = ScanService(
      indexOf({'ancienne': card}, CardFrame.legacy),
      FakeCardTextReader(),
      FakeCardRepository(),
    );

    final outcome = await service.recognise(photoOf(card));

    expect(outcome.oracleIds.first, 'ancienne');
    expect(outcome.frame, CardFrame.legacy);
  });

  test('une carte absente de l\'index n\'est pas affirmée', () async {
    final connue = fakeCard(CardFrame.modern, seed: 3);
    final inconnue = fakeCard(CardFrame.modern, seed: 99);
    final service = ScanService(
      indexOf({'connue': connue}, CardFrame.modern),
      FakeCardTextReader(),
      FakeCardRepository(),
    );

    final outcome = await service.recognise(photoOf(inconnue));

    expect(
      outcome.isConfident,
      isFalse,
      reason:
          'proposer une carte non possédée fausserait toutes les suggestions',
    );
  });

  test('des candidats sont proposés même sans certitude', () async {
    final connue = fakeCard(CardFrame.modern, seed: 4);
    final inconnue = fakeCard(CardFrame.modern, seed: 88);
    final service = ScanService(
      indexOf({'connue': connue}, CardFrame.modern),
      FakeCardTextReader(),
      FakeCardRepository(),
    );

    final outcome = await service.recognise(photoOf(inconnue));

    expect(outcome.oracleIds, isNotEmpty);
  });

  test('le nombre de candidats est limité', () async {
    final cards = {
      for (var i = 0; i < 6; i++) 'c$i': fakeCard(CardFrame.modern, seed: i),
    };
    final service = ScanService(
      indexOf(cards, CardFrame.modern),
      FakeCardTextReader(),
      FakeCardRepository(),
    );

    final outcome = await service.recognise(photoOf(cards['c0']!), limit: 2);

    expect(outcome.oracleIds.length, 2);
  });

  test('une image illisible est signalée sans planter', () async {
    final service = ScanService(
      indexOf({'x': fakeCard(CardFrame.modern)}, CardFrame.modern),
      FakeCardTextReader(),
      FakeCardRepository(),
    );
    final outcome = await service.recognise(Uint8List.fromList([1, 2, 3, 4]));

    expect(outcome.isEmpty, isTrue);
    expect(outcome.error, isNotNull);
  });

  test(
    'un index vide est signalé plutôt que de renvoyer un faux résultat',
    () async {
      final service = ScanService(
        ArtHashIndex.fromEntries([]),
        FakeCardTextReader(),
        FakeCardRepository(),
      );
      final outcome = await service.recognise(
        photoOf(fakeCard(CardFrame.modern)),
      );

      expect(outcome.error, contains('Index'));
    },
  );

  group("le nom lu prime sur l'illustration", () {
    test("une carte absente de l'index est retrouvee par son nom", () async {
      // Cas mesure sur le terrain : illustration d'une reedition inconnue de
      // l'index, mais nom parfaitement lisible.
      final service = ScanService(
        indexOf({
          'autre-carte': fakeCard(CardFrame.modern, seed: 9),
        }, CardFrame.modern),
        FakeCardTextReader()
          ..lines = [const ReadLine('Cherchauloin', 0.05, 0.04)],
        FakeCardRepository()..results = [_hit('farseek')],
      );

      final outcome = await service.recognise(
        photoOf(fakeCard(CardFrame.modern, seed: 3)),
        photoPath: '/photo.png',
      );

      expect(outcome.oracleIds.first, 'farseek');
      expect(outcome.method, ScanMethod.name);
      expect(outcome.readName, 'Cherchauloin');
    });

    test('nom et illustration concordants lèvent le doute', () async {
      final card = fakeCard(CardFrame.modern, seed: 4);
      final service = ScanService(
        indexOf({'cible': card}, CardFrame.modern),
        FakeCardTextReader()..lines = [const ReadLine('Foudre', 0.05, 0.04)],
        FakeCardRepository()..results = [_hit('cible')],
      );

      final outcome = await service.recognise(
        photoOf(card),
        photoPath: '/p.png',
      );

      expect(outcome.method, ScanMethod.nameAndArt);
      expect(outcome.isConfident, isTrue);
    });

    test("sans texte lisible, l'illustration reprend la main", () async {
      final card = fakeCard(CardFrame.modern, seed: 5);
      final service = ScanService(
        indexOf({'cible': card}, CardFrame.modern),
        FakeCardTextReader(),
        FakeCardRepository(),
      );

      final outcome = await service.recognise(
        photoOf(card),
        photoPath: '/p.png',
      );

      expect(outcome.oracleIds.first, 'cible');
      expect(outcome.method, ScanMethod.art);
    });

    test(
      "un nom introuvable au catalogue ne masque pas l'illustration",
      () async {
        final card = fakeCard(CardFrame.modern, seed: 6);
        final service = ScanService(
          indexOf({'cible': card}, CardFrame.modern),
          FakeCardTextReader()
            ..lines = [const ReadLine('Zzzz Illisible', 0.05, 0.04)],
          FakeCardRepository(), // aucune correspondance
        );

        final outcome = await service.recognise(
          photoOf(card),
          photoPath: '/p.png',
        );

        expect(
          outcome.oracleIds.first,
          'cible',
          reason:
              "une lecture ratee ne doit pas priver du recours par empreinte",
        );
      },
    );
  });

  group('les gabarits sont ceux du jeu saisi', () {
    // **Le cloisonnement existait sans jamais servir.** `art_box.dart` sait
    // restreindre les cadres à un jeu, et un test le vérifiait — mais sur la
    // fonction seule. Le service, lui, ne le lui avait jamais demandé : le
    // défaut du paramètre (`magic`) s'appliquait donc toujours. Une carte
    // Riftbound était découpée aux coordonnées d'un cadre Magic, puis cherchée
    // dans l'index Riftbound. La voie principale de reconnaissance de ce jeu —
    // faute de catalogue traduit, l'empreinte y est la voie principale et non
    // le recours — était débranchée, et le test terrain aurait imputé l'échec
    // aux gabarits.
    test('une carte Riftbound est découpée au gabarit Riftbound', () async {
      final card = fakeCard(CardFrame.riftbound, seed: 11);
      final service = ScanService(
        indexOf({'cible': card}, CardFrame.riftbound),
        FakeCardTextReader(),
        FakeCardRepository(),
        game: Game.riftbound,
      );

      final outcome = await service.recognise(photoOf(card));

      expect(outcome.oracleIds.first, 'cible');
      expect(outcome.frame, CardFrame.riftbound);
      expect(outcome.isConfident, isTrue);
    });

    test("aucun cadre d'un autre jeu n'est essayé", () async {
      // Contre-épreuve du même câblage : le cadre retenu doit appartenir au jeu
      // saisi quoi qu'on photographie. C'est ce qui protège le zéro faux
      // positif annoncé avec assurance — un découpage étranger produit une
      // empreinte qui ne veut rien dire mais peut rencontrer une entrée par
      // hasard.
      final magic = fakeCard(CardFrame.modern, seed: 12);
      final service = ScanService(
        indexOf({'magic': magic}, CardFrame.modern),
        FakeCardTextReader(),
        FakeCardRepository(),
        game: Game.riftbound,
      );

      final outcome = await service.recognise(photoOf(magic));

      expect(outcome.frame?.game, 'riftbound');
    });

    test('le catalogue est interrogé dans le jeu saisi', () async {
      // **Mesuré sur une vraie carte, et c'est le journal qui l'a dit.** Une
      // carte Riftbound française photographiée en mode Riftbound se voyait
      // proposer « United Front » et « Arcaniste du Bûcher de gel » — deux
      // cartes Magic. Le nom lu partait au catalogue sans son jeu, et le
      // défaut du paramètre valait `magic` : la recherche interrogeait donc
      // l'autre catalogue, où seul le hasard des scores décide.
      final cards = FakeCardRepository();
      final service = ScanService(
        indexOf({'x': fakeCard(CardFrame.riftbound)}, CardFrame.riftbound),
        FakeCardTextReader()
          ..lines = [const ReadLine('Archer du Val gelé', 0.05, 0.04)],
        cards,
        game: Game.riftbound,
      );

      await service.recognise(
        photoOf(fakeCard(CardFrame.riftbound)),
        photoPath: '/p.png',
      );

      expect(cards.lastGame, Game.riftbound);
    });

    test("l'étalement interroge lui aussi le bon catalogue", () async {
      final cards = FakeCardRepository();
      final service = ScanService(
        ArtHashIndex.fromEntries([]),
        FakeCardTextReader()
          ..lines = [const ReadLine('Icevale Archer', 0.10, 0.03)],
        cards,
        game: Game.riftbound,
      );

      await service.recogniseSpread('etalement.jpg');

      expect(cards.lastGame, Game.riftbound);
    });

    test('Magic reste le jeu par défaut', () async {
      final card = fakeCard(CardFrame.modern, seed: 13);
      final service = ScanService(
        indexOf({'cible': card}, CardFrame.modern),
        FakeCardTextReader(),
        FakeCardRepository(),
      );

      final outcome = await service.recognise(photoOf(card));

      expect(outcome.frame, CardFrame.modern);
    });
  });

  group("l'étalement interroge le catalogue en un seul aller-retour", () {
    ScanService serviceReading(
      List<ReadLine> lines,
      FakeCardRepository cards,
    ) => ScanService(
      ArtHashIndex.fromEntries([]),
      FakeCardTextReader()..lines = lines,
      cards,
    );

    test('toutes les lignes partent dans la même requête', () async {
      // **Ce test protège une mesure, pas un goût.** Une requête par ligne
      // coûtait 77 secondes sur une photo de dix-sept cartes : 112 lignes
      // candidates, et le serveur les traitant l'une après l'autre, les
      // grouper par vagues de 25 ne changeait rien — chaque vague durait 15 s,
      // soit exactement 25 × 600 ms. En un appel, les mêmes lignes reviennent
      // en 3,3 s.
      final cards = FakeCardRepository()
        ..results = [
          _spreadHit('11111111-1111-1111-1111-111111111111', 'Foudre'),
          _spreadHit('22222222-2222-2222-2222-222222222222', 'Anneau solaire'),
        ];
      final service = serviceReading(const [
        ReadLine('Foudre', 0.10, 0.03),
        ReadLine('Anneau solaire', 0.50, 0.03),
      ], cards);

      final found = (await service.recogniseSpread('etalement.jpg')).cards;

      expect(found.map((f) => f.card.name), ['Foudre', 'Anneau solaire']);
      expect(
        cards.lastBulkQuery,
        ['Foudre', 'Anneau solaire'],
        reason:
            "les deux noms doivent partir ensemble ; s'ils partaient un "
            "par un, le dernier appel ne porterait que le second",
      );
    });

    test(
      'une panne du catalogue remonte au lieu de passer pour un vide',
      () async {
        // **La régression qui a coûté le plus cher.** Le code rattrapait toute
        // erreur en rendant « aucune carte trouvée ». Une coupure réseau
        // devenait alors indiscernable d'un étalement illisible : l'écran
        // restait muet, et le journal ne portait aucune trace de la panne.
        // Il a fallu rejouer les requêtes depuis le poste pour comprendre.
        final cards = FakeCardRepository()
          ..results = [
            _spreadHit('33333333-3333-3333-3333-333333333333', 'Foudre'),
          ]
          ..searchError = Exception('connexion perdue');
        final service = serviceReading(const [
          ReadLine('Foudre', 0.10, 0.03),
        ], cards);

        await expectLater(
          service.recogniseSpread('etalement.jpg'),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('quatre exemplaires posés donnent une quantité de quatre', () async {
      // **Vérité terrain.** Une photo portait onze cartes dont quatre du même
      // dinosaure — deux anglaises, deux françaises — et deux Mister Hyde.
      // L'appareil lisait bien les quatre lignes ; elles étaient fusionnées en
      // une carte de quantité 1, et la perte ne se voyait nulle part.
      final cards = FakeCardRepository()
        ..results = [
          _spreadHit('44444444-4444-4444-4444-444444444444', 'Dino'),
        ];
      final service = serviceReading(const [
        ReadLine('Dino', 0.20, 0.010, 0.10, 0.15),
        ReadLine('Dino', 0.20, 0.010, 0.45, 0.15),
        ReadLine('Dino', 0.60, 0.010, 0.10, 0.15),
        ReadLine('Dino', 0.60, 0.010, 0.45, 0.15),
      ], cards);

      final found = (await service.recogniseSpread('etalement.jpg')).cards;

      expect(found.length, 1, reason: 'une seule identité de carte');
      expect(found.single.copies, 4);
    });

    test('un exemplaire unique reste à un', () async {
      // Contre-épreuve : sur la photo de dix-sept cartes toutes différentes, le
      // décompte ne doit inventer aucun exemplaire. C'est l'erreur que
      // l'utilisateur ne peut pas voir venir — une quantité trop haute
      // s'enregistre sans rien signaler.
      final cards = FakeCardRepository()
        ..results = [
          _spreadHit('55555555-5555-5555-5555-555555555555', 'Foudre'),
        ];
      final service = serviceReading(const [
        ReadLine('Foudre', 0.20, 0.010, 0.10, 0.15),
      ], cards);

      final found = (await service.recogniseSpread('etalement.jpg')).cards;

      expect(found.single.copies, 1);
    });

    test(
      'deux lectures différentes de la même carte comptent deux fois',
      () async {
        // Deux exemplaires sont rarement lus à l'identique — « Dinosaure de la
        // Terre sauvage » et « Dinosaure de la Terre sauyage » —, et un
        // exemplaire anglais rejoint son homologue français sur la même identité.
        // Le regroupement doit donc se faire à la carte, pas à la ligne lue.
        final cards = FakeCardRepository()
          ..results = [
            _spreadHit('66666666-6666-6666-6666-666666666666', 'Dinosaure'),
            _spreadHit(
              '66666666-6666-6666-6666-666666666666',
              'Savage Land Dino',
            ),
          ];
        final service = serviceReading(const [
          ReadLine('Dinosaure', 0.20, 0.010, 0.10, 0.15),
          ReadLine('Savage Land Dino', 0.60, 0.010, 0.45, 0.15),
        ], cards);

        final found = (await service.recogniseSpread('etalement.jpg')).cards;

        expect(found.length, 1, reason: 'même identité, deux langues');
        expect(found.single.copies, 2);
      },
    );

    test('un nom coupé en deux ne fabrique pas un second exemplaire', () async {
      // Deux morceaux d'un nom trop long sont sur des lignes consécutives.
      // Mesuré : les exemplaires réels les plus rapprochés étaient à 8,3
      // hauteurs de texte, un nom coupé tiendrait dans une ou deux.
      final cards = FakeCardRepository()
        ..results = [
          _spreadHit('77777777-7777-7777-7777-777777777777', 'Foudre'),
        ];
      final service = serviceReading(const [
        ReadLine('Foudre', 0.200, 0.010, 0.10, 0.15),
        ReadLine('Foudre', 0.212, 0.010, 0.10, 0.15),
      ], cards);

      final found = (await service.recogniseSpread('etalement.jpg')).cards;

      expect(found.single.copies, 1);
    });

    test("sans photo, le filtrage des citations ne s'applique pas", () async {
      // **Le filtrage est un supplément, jamais une dépendance.** Les jeux
      // d'essai ne fournissent pas d'image, et le scan doit rendre exactement
      // ce qu'il rendait avant que ce garde-fou existe.
      final cards = FakeCardRepository()
        ..results = [
          _spreadHit('88888888-8888-8888-8888-888888888888', 'Foudre'),
          _spreadHit('99999999-9999-9999-9999-999999999999', 'Anneau'),
        ];
      final service = serviceReading(const [
        ReadLine('Foudre', 0.10, 0.010, 0.10, 0.15),
        ReadLine('Anneau', 0.60, 0.010, 0.55, 0.15),
      ], cards);

      final found = (await service.recogniseSpread('etalement.jpg')).cards;

      expect(found.length, 2);
    });

    test('une image illisible ne met pas le scan en échec', () async {
      // Une reconnaissance qui marche ne peut pas être mise en échec par son
      // garde-fou : si le décodage échoue, on rend le résultat non filtré.
      final cards = FakeCardRepository()
        ..results = [
          _spreadHit('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Foudre'),
          _spreadHit('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Anneau'),
        ];
      final service = serviceReading(const [
        ReadLine('Foudre', 0.10, 0.010, 0.10, 0.15),
        ReadLine('Anneau', 0.60, 0.010, 0.55, 0.15),
      ], cards);

      final found = (await service.recogniseSpread(
        'etalement.jpg',
        photoBytes: Uint8List.fromList(const [1, 2, 3, 4]),
      )).cards;

      expect(found.length, 2);
    });

    test('une photo sans nom lisible ne sollicite pas le réseau', () async {
      // Un aller-retour à vide se paierait quand même 600 ms, et le serveur
      // n'a rien à en faire.
      final cards = FakeCardRepository();
      final service = serviceReading(const [
        ReadLine('© 2026 Wizards of the Coast', 0.96, 0.02),
      ], cards);

      expect((await service.recogniseSpread('etalement.jpg')).isEmpty, isTrue);
      expect(cards.lastBulkQuery, isNull);
    });
  });

  group('un étalement vide dit laquelle des deux causes', () {
    // **Le geste à faire n'est pas le même**, et l'écran donnait toujours le
    // premier conseil. Mesuré sur une carte Riftbound française : « Archer du
    // Val gelé » lu sans une faute, et l'application répondait « aucun nom n'a
    // pu être lu, évitez les reflets sur les protège-cartes ».
    test('aucun nom lu : la lecture est en cause', () async {
      final service = ScanService(
        ArtHashIndex.fromEntries([]),
        FakeCardTextReader()
          ..lines = [const ReadLine('© 2026 Wizards of the Coast', 0.96, 0.02)],
        FakeCardRepository(),
      );

      final found = await service.recogniseSpread('etalement.jpg');

      expect(found.isEmpty, isTrue);
      expect(found.namesRead, 0);
      expect(found.readButUnmatched, isFalse);
    });

    test(
      'des noms lus, aucun au catalogue : la lecture est hors de cause',
      () async {
        final service = ScanService(
          ArtHashIndex.fromEntries([]),
          FakeCardTextReader()
            ..lines = [const ReadLine('Archer du Val gelé', 0.10, 0.03)],
          FakeCardRepository(), // catalogue muet, comme le Riftbound anglais
        );

        final found = await service.recogniseSpread('etalement.jpg');

        expect(found.isEmpty, isTrue);
        expect(found.namesRead, greaterThan(0));
        expect(found.readButUnmatched, isTrue);
      },
    );
  });

  test('une panne du catalogue ne passe pas pour une carte inconnue', () async {
    // L'étalement a été corrigé de ce piège — il laisse remonter la panne ; le
    // scan à l'unité, jamais. Une coupure réseau y ressemblait trait pour trait
    // à une carte absente, et l'écran proposait de recadrer : recadrer une
    // photo irréprochable ne rétablit pas une connexion.
    final service = ScanService(
      indexOf({'autre': fakeCard(CardFrame.modern, seed: 5)}, CardFrame.modern),
      FakeCardTextReader()..lines = [const ReadLine('Foudre', 0.05, 0.04)],
      FakeCardRepository()..searchError = Exception('connexion perdue'),
    );

    final outcome = await service.recognise(
      photoOf(fakeCard(CardFrame.modern, seed: 8)),
      photoPath: '/p.png',
    );

    expect(outcome.catalogueUnreachable, isTrue);
    expect(outcome.readName, 'Foudre');
  });

  test(
    'sans panne, rien ne prétend que le catalogue est injoignable',
    () async {
      final service = ScanService(
        indexOf({
          'autre': fakeCard(CardFrame.modern, seed: 6),
        }, CardFrame.modern),
        FakeCardTextReader()..lines = [const ReadLine('Foudre', 0.05, 0.04)],
        FakeCardRepository(),
      );

      final outcome = await service.recognise(
        photoOf(fakeCard(CardFrame.modern, seed: 9)),
        photoPath: '/p.png',
      );

      expect(outcome.catalogueUnreachable, isFalse);
    },
  );

  test('un nom lu sans correspondance reste affichable', () async {
    // `readName` est documenté comme servant à expliquer une erreur de lecture,
    // et restait nul précisément là où il sert le plus : un nom net qui ne
    // rencontre aucune carte. L'écran annonçait alors un nom illisible.
    final service = ScanService(
      indexOf({
        'autre': fakeCard(CardFrame.modern, seed: 42),
      }, CardFrame.modern),
      FakeCardTextReader()
        ..lines = [const ReadLine('Archer du Val gelé', 0.05, 0.04)],
      FakeCardRepository(), // aucune correspondance
    );

    final outcome = await service.recognise(
      photoOf(fakeCard(CardFrame.modern, seed: 7)),
      photoPath: '/p.png',
    );

    expect(outcome.readName, 'Archer du Val gelé');
  });

  group('un seul flux photo', () {
    test(
      "des noms lus donnent les cartes, sans toucher à l'illustration",
      () async {
        // Le cas nominal : c'est le comportement de l'étalement, et il doit
        // rester exactement le même — une carte seule n'est qu'un étalement d'une.
        final cards = FakeCardRepository()
          ..results = [_spreadHit('bolt', 'Lightning Bolt')];
        final service = ScanService(
          ArtHashIndex.fromEntries([]),
          FakeCardTextReader()
            ..lines = [const ReadLine('Lightning Bolt', 0.10, 0.03)],
          cards,
        );

        final outcome = await service.recognisePhoto(
          photoOf(fakeCard(CardFrame.modern, seed: 40)),
          photoPath: 'photo.jpg',
        );

        expect(outcome.cards.map((c) => c.card.oracleId), ['bolt']);
        expect(outcome.fromArtwork, isFalse);
      },
    );

    test("sans aucun nom retrouvé, l'illustration prend le relais", () async {
      // **La raison d'être de la fusion.** Une carte dont le nom ne se lit
      // pas — reflet, carton abîmé, texte masqué — était reconnue seule et
      // ignorée en étalement. Le même carton, deux résultats.
      final card = fakeCard(CardFrame.modern, seed: 41);
      final service = ScanService(
        indexOf({'cible': card}, CardFrame.modern),
        FakeCardTextReader(),
        FakeCardRepository()..results = [_spreadHit('cible', 'Cible')],
      );

      final outcome = await service.recognisePhoto(photoOf(card));

      expect(outcome.cards.single.card.oracleId, 'cible');
      expect(outcome.fromArtwork, isTrue);
    });

    test("le recours ne relit pas un texte qui n'a rien donné", () async {
      // Une seconde passe d'OCR coûterait des centaines de millisecondes pour
      // relire ce qui vient de ne rien rendre. Le recours est l'illustration
      // *seule*.
      final card = fakeCard(CardFrame.modern, seed: 42);
      final reader = FakeCardTextReader();
      final service = ScanService(
        indexOf({'cible': card}, CardFrame.modern),
        reader,
        FakeCardRepository(),
      );

      await service.recognisePhoto(photoOf(card), photoPath: 'photo.jpg');

      expect(reader.reads, 1, reason: 'une seule lecture, pas deux');
    });

    test(
      "un nom lu mais introuvable laisse sa chance à l'illustration",
      () async {
        // Les deux échecs ne se ressemblent pas : ici l'appareil a lu quelque
        // chose, mais le catalogue n'en veut pas. L'illustration peut encore
        // trancher, et le texte mérite une seconde lecture —
        // `cardNameCandidates` ne cible pas les mêmes lignes que
        // `spreadNameCandidates`.
        final card = fakeCard(CardFrame.modern, seed: 43);
        final reader = FakeCardTextReader()
          ..lines = [const ReadLine('Nom Illisible Xyz', 0.10, 0.03)];
        final service = ScanService(
          indexOf({'cible': card}, CardFrame.modern),
          reader,
          FakeCardRepository()..results = [_spreadHit('cible', 'Cible')],
        );

        final outcome = await service.recognisePhoto(
          photoOf(card),
          photoPath: 'photo.jpg',
        );

        expect(outcome.cards.single.card.oracleId, 'cible');
        expect(outcome.fromArtwork, isTrue);
        expect(reader.reads, 2, reason: 'le nom unique se cherche autrement');
      },
    );

    test('une reconnaissance incertaine propose sans affirmer', () async {
      // « Affirmer à tort coûte plus cher que suggérer » : l'écran présentera
      // ces candidats sans les cocher.
      final inconnue = fakeCard(CardFrame.modern, seed: 77);
      final service = ScanService(
        indexOf({
          'autre': fakeCard(CardFrame.modern, seed: 44),
        }, CardFrame.modern),
        FakeCardTextReader(),
        FakeCardRepository()..results = [_spreadHit('autre', 'Autre')],
      );

      final outcome = await service.recognisePhoto(photoOf(inconnue));

      expect(outcome.fromArtwork, isTrue);
      expect(outcome.isConfident, isFalse);
    });
  });
}

CardHit _hit(String oracleId) => CardHit(
  oracleId: oracleId,
  name: 'Lightning Bolt',
  matchedName: 'Foudre',
  matchedLang: 'fr',
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
);

/// Carte du catalogue telle que la rend la recherche groupée.
CardHit _spreadHit(String oracleId, String name) => CardHit(
  oracleId: oracleId,
  name: name,
  matchedName: name,
  matchedLang: 'fr',
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  score: 1,
);
