/// Tests de l'overlay OBS (#14).
///
/// **Ce que l'overlay doit garantir** tient en trois phrases, et chacune est un
/// piège évité : il ne montre rien au démarrage, il montre chaque carte une
/// fois — même deux exemplaires successifs de la même —, et il **se tait quand
/// le réseau tombe** plutôt que d'écrire une erreur en plein direct.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/binders/domain/recent_addition.dart';
import 'package:deckhand/src/features/binders/domain/spotlight_card.dart';
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

SpotlightCard designation({
  required int id,
  String name = 'Demandée',
  String? by = 'alice',
}) => SpotlightCard(
  requestId: id,
  name: name,
  requestedBy: by,
  setCode: 'msh',
  collectorNumber: '61',
  copies: 1,
);

/// Un dépôt qui rend ce qu'on lui dit, et qui sait échouer sur commande.
class OverlayRepo extends FakeCollectionRepository {
  List<RecentAddition> rows = const [];
  Object? failure;
  int calls = 0;

  /// **Une panne par source.** Le calque doit survivre à la chute de l'une sans
  /// perdre l'autre ; une seule variable d'échec ne permettrait pas de le
  /// vérifier.
  SpotlightCard? asked;
  Object? spotlightFailure;

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

  @override
  Future<SpotlightCard?> spotlight(
    String handle, {
    Game game = Game.magic,
  }) async {
    final boom = spotlightFailure;
    if (boom != null) throw boom;
    return asked;
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

  group('la désignation', () {
    testWidgets('rien au démarrage, même si une carte est déjà désignée', (
      tester,
    ) async {
      // Un calque rouvert en cours de direct ne rejoue pas la demande d'avant
      // la coupure : la première réponse ne fait qu'établir la référence.
      final repo = OverlayRepo()..asked = designation(id: 1, name: 'Ancienne');
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Ancienne'), findsNothing);
    });

    testWidgets('la carte demandée apparaît, au nom du demandeur', (
      tester,
    ) async {
      final repo = OverlayRepo();
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.asked = designation(id: 7, name: 'Ka-Zar', by: 'alice');
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.text('Ka-Zar'), findsOneWidget);
      // Sans le nom du demandeur, une désignation se confondrait avec un scan
      // et perdrait ce qui en fait une interaction.
      expect(find.textContaining('alice'), findsOneWidget);
      expect(find.textContaining('case comblée'), findsNothing);
    });

    testWidgets("un demandeur inconnu ne s'invente pas un nom", (
      tester,
    ) async {
      final repo = OverlayRepo();
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.asked = designation(id: 7, by: null);
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.textContaining('demandée dans le chat'), findsOneWidget);
    });

    testWidgets('deux demandes de la même carte comptent pour deux', (
      tester,
    ) async {
      // Le jumeau du piège de `movementId` : comparer les noms avalerait la
      // seconde demande, qui est pourtant un événement distinct.
      final repo = OverlayRepo();
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.asked = designation(id: 7, name: 'Ka-Zar', by: 'alice');
      await tester.pump(overlayPollInterval);
      await tester.pump();
      await tester.pump(overlayLinger);
      await tester.pump();
      expect(find.text('Ka-Zar'), findsNothing);

      repo.asked = designation(id: 8, name: 'Ka-Zar', by: 'bob');
      await tester.pump(overlayPollInterval);
      await tester.pump();
      expect(find.text('Ka-Zar'), findsOneWidget);
      expect(find.textContaining('bob'), findsOneWidget);
    });

    testWidgets('le scan prime sur la demande', (tester) async {
      // Une carte scannée est physiquement devant l'objectif ; une désignation
      // n'est qu'une curiosité. La cacher derrière le chat ferait un calque qui
      // masque ce qu'on est en train de filmer.
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.rows = [addition(id: 2, name: 'Scannée')];
      repo.asked = designation(id: 7, name: 'Demandée');
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.text('Scannée'), findsOneWidget);
      expect(find.text('Demandée'), findsNothing);
    });

    testWidgets('une demande évincée remonte une fois le scan effacé', (
      tester,
    ) async {
      // **Le test qui justifie de ne marquer une demande vue qu'à l'affichage.**
      // Sans cela, la demande d'un spectateur disparaîtrait sans trace parce
      // qu'un carton est passé au mauvais moment — et il n'y a pas de file pour
      // la rattraper.
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.rows = [addition(id: 2, name: 'Scannée')];
      await tester.pump(overlayPollInterval);
      await tester.pump();
      expect(find.text('Scannée'), findsOneWidget);

      repo.asked = designation(id: 7, name: 'Demandée');
      // Pas à pas plutôt qu'en un bond : chaque interrogation est asynchrone,
      // et un seul grand `pump` n'en résoudrait pas la totalité.
      for (var i = 0; i < 9; i++) {
        await tester.pump(overlayPollInterval);
        await tester.pump();
      }

      expect(find.text('Scannée'), findsNothing);
      expect(find.text('Demandée'), findsOneWidget);
    });

    testWidgets('un scan reprend la main sur une demande affichée', (
      tester,
    ) async {
      final repo = OverlayRepo()..rows = [addition(id: 1)];
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.asked = designation(id: 7, name: 'Demandée');
      await tester.pump(overlayPollInterval);
      await tester.pump();
      expect(find.text('Demandée'), findsOneWidget);

      repo.rows = [addition(id: 2, name: 'Scannée')];
      await tester.pump(overlayPollInterval);
      await tester.pump();
      expect(find.text('Scannée'), findsOneWidget);
      expect(find.text('Demandée'), findsNothing);
    });

    testWidgets("la chute d'une source n'emporte pas l'autre", (
      tester,
    ) async {
      final repo = OverlayRepo()
        ..rows = [addition(id: 1)]
        ..spotlightFailure = Exception('désignation indisponible');
      await pumpOverlay(tester, repo);
      await tester.pump(const Duration(milliseconds: 100));

      repo.rows = [addition(id: 2, name: 'Scannée')];
      await tester.pump(overlayPollInterval);
      await tester.pump();

      expect(find.text('Scannée'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
