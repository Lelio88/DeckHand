/// Regarder l'intro plutôt que la deviner — cinq images de la distribution.
///
/// **Une décision d'écran se regarde** (`CLAUDE.md` §V.5). La maquette HTML a
/// servi à juger le mouvement ; ces captures servent à vérifier que le portage
/// Flutter rend la même chose, et surtout que la dernière image **est** l'icône
/// du Play Store.
///
/// Hors dépôt : les images vont dans `test/apercu/`, ignoré par git.
///
///     cd app && DECKHAND_FONTS=<flutter>/bin/cache/artifacts/material_fonts \
///         flutter test test/apercu_intro_test.dart --update-goldens
library;

import 'dart:io';

import 'package:deckhand/src/features/intro/presentation/intro_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> chargerRoboto() async {
  final dossier = Platform.environment['DECKHAND_FONTS'];
  if (dossier == null) return;
  for (final (famille, fichier) in const [
    ('Roboto', 'roboto-regular.ttf'),
    ('Roboto', 'roboto-light.ttf'),
  ]) {
    final chemin = File('$dossier/$fichier');
    if (!chemin.existsSync()) continue;
    final octets = await chemin.readAsBytes();
    await (FontLoader(famille)
          ..addFont(Future.value(ByteData.view(octets.buffer))))
        .load();
  }
}

void main() {
  setUpAll(chargerRoboto);

  testWidgets('les cinq temps de la distribution', (tester) async {
    tester.view.physicalSize = const Size(440, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: IntroScreen(playSound: false))),
    );

    var deja = Duration.zero;
    for (final (nom, instant) in const [
      ('1-premiere-carte', Duration(milliseconds: 480)),
      ('2-deuxieme', Duration(milliseconds: 780)),
      ('3-retournement', Duration(milliseconds: 1200)),
      ('4-eventail', Duration(milliseconds: 1560)),
      ('5-logo', Duration(milliseconds: 2200)),
    ]) {
      await tester.pump(instant - deja);
      deja = instant;
      await expectLater(
        find.byType(IntroScreen),
        matchesGoldenFile('apercu/intro-$nom.png'),
      );
    }
  }, skip: Platform.environment['DECKHAND_FONTS'] == null);
}
