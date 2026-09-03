/// Aperçu : rend les deux tuiles du profil en images, pour les REGARDER.
///
/// **Ce n'est pas un test de non-régression** — il n'assère rien, il fabrique
/// des captures. Il existe parce qu'une décision d'écran se juge à l'œil et que
/// l'appareil n'est pas toujours au bout d'un câble ; c'est ainsi que le
/// centrage de la jauge et l'égalité de hauteur des deux tuiles ont été
/// vérifiés avant tout branchement.
///
/// **Ce qu'il ne remplace pas** : l'appareil. Il ignore le thème du système, la
/// densité réelle de l'écran et la police de l'utilisateur. Il dit si une mise
/// en page tient, pas si elle est belle sur un téléphone.
///
/// Il est **sauté par `flutter test`** : sans police réelle, le texte se rend
/// en rectangles et la comparaison échouerait sur toute machine. Pour le jouer :
///
///     cd app && DECKHAND_FONTS=<flutter>/bin/cache/artifacts/material_fonts ///         flutter test test/apercu_tuiles_test.dart --update-goldens
///
/// Les images atterrissent dans `test/apercu/`, hors dépôt.
library;

import 'dart:io';

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/account/data/profile_repository.dart';
import 'package:deckhand/src/features/account/presentation/account_screen.dart';
import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/binders/data/binder_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/features/binders/binder_view_test.dart' show FakeBinderRepository;
import 'src/helpers/fakes.dart';

const _totaux = CollectionSummary(
  totalCards: 617,
  distinctCards: 266,
  totalValueEur: 167.83,
  uniqueValueEur: 119.64,
  topCardName: 'Simulacrum Synthesizer',
  topCardEur: 15.49,
  distinctSets: 3,
  bestSetName: 'Marvel Super Heroes',
  bestSetOwned: 234,
  bestSetTotal: 453,
);

/// Charge une vraie police : sans elle, le texte est rendu en rectangles et
/// l'aperçu ne dit plus rien de la lisibilité.
Future<void> chargerRoboto() async {
  final dossier = Platform.environment['DECKHAND_FONTS'];
  if (dossier == null) return;
  for (final (famille, fichier) in const [
    ('Roboto', 'roboto-regular.ttf'),
    ('Roboto', 'roboto-medium.ttf'),
    // Sans elle, chaque icône se rend en carré plein : elles occupent alors la
    // place d'un glyphe quelconque, et l'aperçu ment sur la mise en page qu'il
    // sert justement à juger.
    ('MaterialIcons', 'materialicons-regular.otf'),
  ]) {
    final octets = await File('$dossier/$fichier').readAsBytes();
    final loader = FontLoader(famille)
      ..addFont(Future.value(ByteData.view(octets.buffer)));
    await loader.load();
  }
}

void main() {
  // Hors de `testWidgets` : la lecture d'un fichier est une E/S réelle, et la
  // zone fake-async d'un test ne la résout jamais — le test pend jusqu'au
  // délai de garde.
  setUpAll(chargerRoboto);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('capture les deux tuiles, chiffre par chiffre', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 720);
    addTearDown(tester.view.reset);

    final profile = FakeProfileRepository(declared: const [Game.magic]);
    final collection = FakeCollectionRepository()..totals = _totaux;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileRepositoryProvider.overrideWithValue(profile),
          playedGamesProvider.overrideWith((ref) async => const [Game.magic]),
          collectionRepositoryProvider.overrideWithValue(collection),
          binderRepositoryProvider.overrideWithValue(FakeBinderRepository()),
          sessionProvider.overrideWith(
            (ref) => Stream<Session?>.value(fakeSession()),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF6750A4),
            useMaterial3: true,
          ),
          home: const Scaffold(body: AccountScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 0; i < 5; i++) {
      await expectLater(
        find.byType(Row).first,
        matchesGoldenFile('apercu/tuiles-$i.png'),
      );
      await tester.tap(find.byKey(const Key('tuile-contenu')));
      await tester.tap(find.byKey(const Key('tuile-valeur')));
      await tester.pumpAndSettle();
    }
  }, skip: Platform.environment['DECKHAND_FONTS'] == null);
}
