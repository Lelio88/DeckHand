/// Tests de l'écran « Assistant IA » et de son dépôt.
///
/// **Ce qu'ils protègent, c'est un accès qu'on croit retiré.** Un bouton
/// « Révoquer » qui s'efface sans que GoTrue ait reçu la demande laisserait un
/// assistant lire la collection d'un utilisateur persuadé du contraire. Les
/// assertions portent donc sur **ce que le serveur a reçu** — méthode, adresse,
/// jeton —, puis sur ce que l'écran en montre.
///
/// Le serveur est un faux en mémoire (`MockClient`) qui tient la liste des
/// accès : le dépôt testé est le vrai.
library;

import 'dart:convert';

import 'package:deckhand/src/common/legal_links.dart';
import 'package:deckhand/src/features/account/data/assistant_repository.dart';
import 'package:deckhand/src/features/account/presentation/assistant_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _supabase = 'https://projet.supabase.co';

/// Un GoTrue en mémoire : la liste des accès, et le journal des requêtes.
class FauxGoTrue {
  FauxGoTrue(this.acces);

  final List<Map<String, Object?>> acces;
  final requetes = <http.Request>[];
  int statutListe = 200;

  late final client = MockClient((requete) async {
    requetes.add(requete);
    if (requete.method == 'GET') {
      return http.Response.bytes(utf8.encode(jsonEncode(acces)), statutListe);
    }
    if (requete.method == 'DELETE') {
      final id = requete.url.queryParameters['client_id'];
      acces.removeWhere((a) => (a['client'] as Map)['id'] == id);
      return http.Response('', 204);
    }
    return http.Response('', 405);
  });

  AssistantRepository depot({String? jeton = 'jeton-app'}) =>
      AssistantRepository(
        accessToken: () => jeton,
        httpClient: client,
        supabaseUrl: _supabase,
        publishableKey: 'cle-publique',
      );
}

Map<String, Object?> acces(String id, String? nom) => {
  'client': {'id': id, 'name': nom},
  'scope': '',
  'granted_at': '2026-10-02T13:18:57Z',
};

void main() {
  group('adresses', () {
    test('le connecteur est la fonction mcp du projet', () {
      expect(connectorUrlFor(_supabase), '$_supabase/functions/v1/mcp');
      expect(connectorUrlFor('$_supabase/'), '$_supabase/functions/v1/mcp');
    });

    test('la commande Claude Code vaut pour tous les dossiers', () {
      expect(
        claudeCodeCommandFor('$_supabase/functions/v1/mcp'),
        'claude mcp add --transport http --scope user deckhand $_supabase/functions/v1/mcp',
      );
    });
  });

  group('lecture des accès', () {
    test('rend nom, identifiant et date', () {
      final [grant] = grantsFromJson([acces('c-1', 'Claude')]);
      expect(grant.clientId, 'c-1');
      expect(grant.name, 'Claude');
      expect(grant.grantedAt, DateTime.utc(2026, 10, 2, 13, 18, 57));
    });

    test('un nom absent ne fait pas tomber la liste', () {
      expect(
        grantsFromJson([acces('c-1', null)]).single.name,
        'Assistant sans nom',
      );
      expect(
        grantsFromJson([acces('c-1', '  ')]).single.name,
        'Assistant sans nom',
      );
    });

    test(
      'une entrée sans identifiant est écartée : on ne saurait pas la révoquer',
      () {
        expect(
          grantsFromJson([
            {
              'client': {'name': 'X'},
            },
            'bruit',
            acces('c-2', 'Y'),
          ]).single.clientId,
          'c-2',
        );
        expect(grantsFromJson({'pas': 'une liste'}), isEmpty);
      },
    );
  });

  group('dépôt', () {
    test('lit les accès avec la session de l\'application', () async {
      final gotrue = FauxGoTrue([acces('c-1', 'Claude')]);
      final grants = await gotrue.depot().grants();
      expect(grants.single.name, 'Claude');
      final requete = gotrue.requetes.single;
      expect(requete.url.toString(), '$_supabase/auth/v1/user/oauth/grants');
      expect(requete.headers['Authorization'], 'Bearer jeton-app');
      expect(requete.headers['apikey'], 'cle-publique');
    });

    test('révoque par identifiant de client', () async {
      final gotrue = FauxGoTrue([acces('c-1', 'Claude')]);
      await gotrue.depot().revoke('c-1');
      final requete = gotrue.requetes.single;
      expect(requete.method, 'DELETE');
      expect(requete.url.queryParameters, {'client_id': 'c-1'});
      expect(gotrue.acces, isEmpty);
    });

    test('sans session, rien ne part', () async {
      final gotrue = FauxGoTrue([]);
      await expectLater(
        gotrue.depot(jeton: null).grants(),
        throwsA(isA<AssistantAccessUnavailable>()),
      );
      expect(gotrue.requetes, isEmpty);
    });

    test('un refus du serveur devient un message lisible', () async {
      final gotrue = FauxGoTrue([])..statutListe = 500;
      await expectLater(
        gotrue.depot().grants(),
        throwsA(isA<AssistantAccessUnavailable>()),
      );
    });
  });

  group('écran', () {
    Future<FauxGoTrue> ouvrir(
      WidgetTester tester,
      List<Map<String, Object?>> lesAcces, {
      List<Uri>? liensOuverts,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.reset);
      final gotrue = FauxGoTrue(lesAcces);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            assistantRepositoryProvider.overrideWithValue(gotrue.depot()),
            externalLinkOpenerProvider.overrideWithValue((uri) async {
              liensOuverts?.add(uri);
              return true;
            }),
          ],
          child: const MaterialApp(home: AssistantScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return gotrue;
    }

    testWidgets('montre l\'adresse du connecteur et la commande', (
      tester,
    ) async {
      await ouvrir(tester, []);
      expect(find.text('$_supabase/functions/v1/mcp'), findsOneWidget);
      expect(
        find.textContaining('claude mcp add --transport http'),
        findsOneWidget,
      );
      expect(
        find.text("Aucun assistant n'a accès à votre collection."),
        findsOneWidget,
      );
    });

    testWidgets('révoquer envoie la demande, puis l\'accès disparaît', (
      tester,
    ) async {
      final gotrue = await ouvrir(tester, [acces('c-1', 'Claude')]);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Autorisé le 02/10/2026'), findsOneWidget);

      await tester.tap(find.text('Révoquer'));
      await tester.pumpAndSettle();

      expect(
        gotrue.requetes
            .where((r) => r.method == 'DELETE')
            .single
            .url
            .queryParameters,
        {'client_id': 'c-1'},
      );
      expect(find.text('Claude'), findsNothing);
      expect(
        find.text("Aucun assistant n'a accès à votre collection."),
        findsOneWidget,
      );
      expect(find.text('Accès retiré à Claude.'), findsOneWidget);
    });

    testWidgets("le mode d'emploi ouvre la page des assistants", (
      tester,
    ) async {
      final liens = <Uri>[];
      await ouvrir(tester, [], liensOuverts: liens);
      await tester.tap(find.text("Mode d'emploi complet"));
      await tester.pumpAndSettle();
      expect(liens, [LegalLinks.assistant]);
    });
  });
}
