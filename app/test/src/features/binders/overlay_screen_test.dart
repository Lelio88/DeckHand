/// Tests de l'overlay OBS (#14).
///
/// **Ce que l'overlay doit garantir** tient en trois phrases, et chacune est un
/// piège évité : il ne montre rien au démarrage, il montre chaque carte une
/// fois — même deux exemplaires successifs de la même —, et il **se tait quand
/// le réseau tombe** plutôt que d'écrire une erreur en plein direct.
library;

import 'package:deckhand/src/features/binders/domain/recent_addition.dart';
import 'package:deckhand/src/features/binders/presentation/overlay_screen.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

RecentAddition addition({
  required int id,
  String name = 'Carte',
  int copiesBefore = 0,
  String? setCode = 'msh',
  double? price = 1.5,
}) => RecentAddition(
  movementId: id,
  name: name,
  setCode: setCode,
  collectorNumber: '12',
  priceEur: price,
  copiesBefore: copiesBefore,
);

/// Un dépôt qui rend ce qu'on lui dit, et qui sait échouer sur commande.
class OverlayRepo extends FakeCollectionRepository {
  List<RecentAddition> rows = const [];
  Object? failure;
  int calls = 0;

  @override
  Future<List<RecentAddition>> recentAdditions(
    String handle, {
    int limit = 1,
  }) async {
    calls++;
    final boom = failure;
    if (boom != null) throw boom;
    return rows;
  }
}

Future<OverlayRepo> pumpOverlay(WidgetTester tester, OverlayRepo repo) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [collectionRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: OverlayScreen(handle: 'essai')),
    ),
  );
  await tester.pump();
  return repo;
}

void main() {
  group('l\'adresse', () {
    test('se lit dans la requête', () {
      expect(overlayFromUrl(Uri.parse('https://x/?o=moi')), 'moi');
    });

    test('se lit aussi derrière le fragment', () {
      // Flutter sert ses routes tantôt derrière un `#`, tantôt non.
      expect(overlayFromUrl(Uri.parse('https://x/#/?o=moi')), 'moi');
    });

    test('ne se confond pas avec celle du classeur', () {
      // Les deux pages n'ont ni le même public ni la même forme : `?c=`
      // ouvrirait un calque transparent à qui voulait consulter un classeur.
      expect(overlayFromUrl(Uri.parse('https://x/?c=moi')), isNull);
    });

    test('une adresse vide ne vaut pas une adresse', () {
      expect(overlayFromUrl(Uri.parse('https://x/?o=')), isNull);
    });
  });

  group('ce qui s\'affiche', () {
    testWidgets('rien au démarrage, même si le journal a du contenu', (
      tester,
    ) async {
      // La dernière carte du journal peut dater de la veille : l'afficher au
      // lancement d'OBS ferait croire qu'on vient de l'ouvrir.
      final repo = OverlayRepo()..rows = [addition(id: 1, name: 'Ancienne')];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Ancienne'), findsNothing);
    });

    testWidgets('la carte suivante apparaît', (tester) async {
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.rows = [addition(id: 2, name: 'Nouvelle')];
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.text('Nouvelle'), findsOneWidget);
      expect(find.textContaining('case comblée'), findsOneWidget);
    });

    testWidgets('un doublon se dit comme tel', (tester) async {
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.rows = [addition(id: 2, name: 'Revue', copiesBefore: 2)];
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.textContaining('doublon'), findsOneWidget);
      expect(find.textContaining('3'), findsWidgets);
    });

    testWidgets('deux exemplaires successifs comptent pour deux', (
      tester,
    ) async {
      // **Le piège que l'identifiant de mouvement existe pour éviter.**
      // Comparer les noms avalerait le second exemplaire, qui est pourtant un
      // événement distinct — et le plus intéressant des deux, puisqu'il fait
      // le doublon.
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.rows = [addition(id: 2, name: 'Même carte')];
      await tester.pump(overlayPollInterval);
      await tester.pump();
      expect(find.textContaining('case comblée'), findsOneWidget);

      repo.rows = [addition(id: 3, name: 'Même carte', copiesBefore: 1)];
      await tester.pump(overlayPollInterval);
      await tester.pump();
      expect(find.textContaining('doublon'), findsOneWidget);
    });

    testWidgets('la carte s\'efface après son délai', (tester) async {
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.rows = [addition(id: 2, name: 'Passagère')];
      await tester.pump(overlayPollInterval);
      await tester.pump();
      expect(find.text('Passagère'), findsOneWidget);

      // Garder la dernière carte indéfiniment finirait par mentir sur ce qui
      // se passe à l'écran.
      await tester.pump(overlayLinger + overlayPollInterval);
      await tester.pump();
      expect(find.text('Passagère'), findsNothing);
    });
  });

  group('la coupure réseau', () {
    testWidgets('n\'écrit aucune erreur à l\'écran', (tester) async {
      final repo = OverlayRepo()..failure = Exception('réseau coupé');
      await pumpOverlay(tester, repo);
      await tester.pump(overlayPollInterval);
      await tester.pump();

      // Un message d'erreur en plein direct est pire que rien.
      expect(find.textContaining('réseau'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('laisse la dernière carte en place', (tester) async {
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.rows = [addition(id: 2, name: 'Tenace')];
      await tester.pump(overlayPollInterval);
      await tester.pump();
      expect(find.text('Tenace'), findsOneWidget);

      repo.failure = Exception('réseau coupé');
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.text('Tenace'), findsOneWidget);
    });

    testWidgets('la carte revient quand le réseau revient', (tester) async {
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.failure = Exception('réseau coupé');
      await tester.pump(overlayPollInterval);
      await tester.pump();

      repo
        ..failure = null
        ..rows = [addition(id: 2, name: 'Retour')];
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.text('Retour'), findsOneWidget);
    });
  });

  group('l\'attribution', () {
    testWidgets('est visible sur le calque', (tester) async {
      // Garde-fou §IV.2 : un calque est vu par plus d'inconnus qu'un écran
      // « à propos ».
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));
      repo.rows = [addition(id: 2)];
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.text('Données : Scryfall'), findsOneWidget);
    });
  });
}
