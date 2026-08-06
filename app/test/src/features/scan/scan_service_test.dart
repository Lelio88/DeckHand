/// Tests de la reconnaissance d'une carte à partir d'une photo.
///
/// La photo est fabriquée : un décor autour d'une fausse carte, elle-même
/// porteuse d'une illustration texturée à l'emplacement du gabarit. On vérifie
/// que la chaîne complète — cadrage, découpe, empreinte, recherche — retrouve
/// bien la carte, et surtout qu'elle refuse de conclure quand elle ne le
/// devrait pas.
library;

import 'dart:typed_data';

import 'package:deckhand/src/features/scan/application/scan_service.dart';
import 'package:deckhand/src/features/scan/domain/art_box.dart';
import 'package:deckhand/src/features/scan/domain/art_hash.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/card_framing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Fausse carte : fond uni, illustration texturée dans la zone du gabarit.
img.Image fakeCard(CardFrame frame, {int seed = 0, int width = 400}) {
  final height = (width / cardAspectRatio).round();
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
  test('une photo bien cadrée retrouve la carte', () {
    final card = fakeCard(CardFrame.modern, seed: 1);
    final service = ScanService(indexOf({'cible': card}, CardFrame.modern));

    final outcome = service.recognise(photoOf(card));

    expect(outcome.candidates.first.oracleId, 'cible');
    expect(outcome.isConfident, isTrue);
    expect(outcome.frame, CardFrame.modern);
  });

  test('une carte au cadre ancien est reconnue aussi', () {
    final card = fakeCard(CardFrame.legacy, seed: 2);
    final service = ScanService(indexOf({'ancienne': card}, CardFrame.legacy));

    final outcome = service.recognise(photoOf(card));

    expect(outcome.candidates.first.oracleId, 'ancienne');
    expect(outcome.frame, CardFrame.legacy);
  });

  test('une carte absente de l\'index n\'est pas affirmée', () {
    final connue = fakeCard(CardFrame.modern, seed: 3);
    final inconnue = fakeCard(CardFrame.modern, seed: 99);
    final service = ScanService(indexOf({'connue': connue}, CardFrame.modern));

    final outcome = service.recognise(photoOf(inconnue));

    expect(
      outcome.isConfident,
      isFalse,
      reason:
          'proposer une carte non possédée fausserait toutes les suggestions',
    );
  });

  test('des candidats sont proposés même sans certitude', () {
    final connue = fakeCard(CardFrame.modern, seed: 4);
    final inconnue = fakeCard(CardFrame.modern, seed: 88);
    final service = ScanService(indexOf({'connue': connue}, CardFrame.modern));

    final outcome = service.recognise(photoOf(inconnue));

    expect(outcome.candidates, isNotEmpty);
  });

  test('le nombre de candidats est limité', () {
    final cards = {
      for (var i = 0; i < 6; i++) 'c$i': fakeCard(CardFrame.modern, seed: i),
    };
    final service = ScanService(indexOf(cards, CardFrame.modern));

    final outcome = service.recognise(photoOf(cards['c0']!), limit: 2);

    expect(outcome.candidates.length, 2);
  });

  test('une image illisible est signalée sans planter', () {
    final service = ScanService(
      indexOf({'x': fakeCard(CardFrame.modern)}, CardFrame.modern),
    );
    final outcome = service.recognise(Uint8List.fromList([1, 2, 3, 4]));

    expect(outcome.isEmpty, isTrue);
    expect(outcome.error, isNotNull);
  });

  test('un index vide est signalé plutôt que de renvoyer un faux résultat', () {
    final service = ScanService(ArtHashIndex.fromEntries([]));
    final outcome = service.recognise(photoOf(fakeCard(CardFrame.modern)));

    expect(outcome.error, contains('Index'));
  });
}
