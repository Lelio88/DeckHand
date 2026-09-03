/// Aperçu : rend la liste qui suit une photo, pour la REGARDER.
///
/// **Ce n'est pas un test de non-régression** — il n'assère rien, il fabrique
/// des captures. Il existe parce qu'une ligne de scan porte désormais cinq
/// choses à la fois — case à cocher, nom corrigeable, nom original, édition,
/// compte possédé, quantité — et qu'aucun test de largeur ne dit si l'ensemble
/// se lit. Le test de largeur, lui, tourne sous une police où chaque glyphe est
/// un carré plein : il majore tout et ne juge rien.
///
/// **Ce qu'il ne remplace pas** : l'appareil. Il ignore le thème du système, la
/// densité réelle et la police de l'utilisateur.
///
/// Il est **sauté par `flutter test`** : sans police réelle, le texte se rend
/// en rectangles. Pour le jouer :
///
///     cd app && DECKHAND_FONTS=<flutter>/bin/cache/artifacts/material_fonts \
///         flutter test test/apercu_scan_test.dart --update-goldens
///
/// Les images atterrissent dans `test/apercu/`, hors dépôt.
library;

import 'dart:io';

import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apercu_tuiles_test.dart' show chargerRoboto;
import 'src/features/scan/spread_scan_screen_test.dart' show pumpSpreadScan;

CardHit _carte(
  String id,
  String nom, {
  String? vo,
  int owned = 0,
}) => CardHit(
  oracleId: id,
  name: vo ?? nom,
  matchedName: nom,
  matchedLang: 'fr',
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  owned: owned,
  score: 1,
);

void main() {
  setUpAll(chargerRoboto);

  testWidgets('capture la liste qui suit une photo', (tester) async {
    // 360 dp de large : le plus étroit des téléphones Android courants, donc
    // le cas où la ligne a le moins de place pour tout dire.
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 1560);
    addTearDown(tester.view.reset);

    await pumpSpreadScan(
      tester,
      found: [
        _carte('id-1', 'Agent Phil Coulson', vo: 'Agent Phil Coulson'),
        _carte(
          'id-2',
          'Archimage Elminster de Valombre',
          vo: 'Elminster, Archmage Adept',
          owned: 3,
        ),
        _carte('id-3', 'Levée de bouclier', vo: 'Shield Raise', owned: 12),
      ],
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('apercu/scan-liste.png'),
    );
  }, skip: Platform.environment['DECKHAND_FONTS'] == null);
}
