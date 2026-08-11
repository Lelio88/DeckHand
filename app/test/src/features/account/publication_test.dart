/// Tests de la publication d'une collection.
///
/// **Ce qu'ils protègent, c'est une collection qu'on croit privée.** Un
/// interrupteur est un objet dangereux quand il ment : s'il s'affiche sur
/// « publié » sans que le serveur l'ait su, on montre sa collection en croyant
/// l'avoir refermée — et l'inverse, plus grave, laisse ouvert ce qu'on pense
/// avoir fermé. Les assertions portent donc sur **ce que le dépôt a reçu**, pas
/// sur ce que l'écran affiche.
///
/// Le second point est le **défaut** : rien n'est publié tant qu'on n'y touche
/// pas, et l'adresse de partage ne s'affiche que lorsqu'elle mène quelque part.
library;

import 'package:deckhand/src/features/account/presentation/account_screen.dart';
import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/collection/domain/collection_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

Future<FakeCollectionRepository> pumpAccount(
  WidgetTester tester, {
  bool isPublic = false,
}) async {
  final collection = FakeCollectionRepository()
    ..totals = const CollectionSummary(
      totalCards: 451,
      distinctCards: 343,
      totalValueEur: 115.5,
      unspecifiedPrints: 0,
    )
    ..publication_ = Publication(
      collectionId: 'collection-1',
      isPublic: isPublic,
    );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        collectionRepositoryProvider.overrideWithValue(collection),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: AccountScreen())),
    ),
  );
  await tester.pumpAndSettle();
  return collection;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('rien n\'est publié tant qu\'on n\'y touche pas', (tester) async {
    final collection = await pumpAccount(tester);

    expect(find.text('Vous seul voyez votre collection.'), findsOneWidget);
    expect(
      collection.lastPublish,
      isNull,
      reason: 'afficher l\'écran ne publie rien',
    );
  });

  testWidgets('l\'adresse ne s\'affiche que si elle mène quelque part', (
    tester,
  ) async {
    await pumpAccount(tester);
    expect(find.text('collection-1'), findsNothing);

    await pumpAccount(tester, isPublic: true);
    expect(find.text('collection-1'), findsOneWidget);
  });

  testWidgets('la bascule atteint le serveur', (tester) async {
    // Le maillon qui cède en silence : un interrupteur qui bascule à l'écran
    // sans que rien ne parte laisse croire à une collection publiée.
    final collection = await pumpAccount(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(collection.lastPublish?.id, 'collection-1');
    expect(collection.lastPublish?.isPublic, isTrue);
    expect(
      find.textContaining('N\'importe qui peut voir'),
      findsOneWidget,
      reason: 'l\'écran se relit après la bascule, il ne la suppose pas',
    );
  });

  testWidgets('on peut refermer ce qu\'on a ouvert', (tester) async {
    final collection = await pumpAccount(tester, isPublic: true);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(collection.lastPublish?.isPublic, isFalse);
    expect(find.text('Vous seul voyez votre collection.'), findsOneWidget);
  });
}
