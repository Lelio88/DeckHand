/// Les assistants IA qui ont accès à la collection : les voir, et leur retirer
/// l'accès.
///
/// **Un assistant n'est pas une session de l'application.** Il a obtenu son
/// jeton par le serveur OAuth de Supabase, après un « Autoriser » sur la page de
/// consentement (`app/web/oauth-consent.html`) ; ce que GoTrue appelle un
/// *grant*. La liste et le retrait passent par deux appels REST de GoTrue
/// (`/auth/v1/user/oauth/grants`), avec la session de l'application — le client
/// Dart de Supabase ne les expose pas.
///
/// **Retirer un accès ne le coupe pas à la seconde** : l'assistant ne peut plus
/// renouveler son jeton, mais celui qu'il tient reste valable jusqu'à son
/// expiration, une heure au plus (mesuré, `docs/mcp-architecture.md`). L'écran
/// le dit plutôt que de promettre une coupure immédiate.
///
/// **Lecture tolérante** : une entrée sans identifiant de client est écartée —
/// on ne saurait pas la révoquer — et un nom absent devient « Assistant sans
/// nom » plutôt que de faire tomber la liste.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/request_timeout.dart';
import '../../../config/supabase_config.dart';

String _sansBarreFinale(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

/// L'adresse à donner à un assistant : le serveur MCP de DeckHand.
String connectorUrlFor(String supabaseUrl) =>
    '${_sansBarreFinale(supabaseUrl)}/functions/v1/mcp';

/// La commande qui branche DeckHand dans Claude Code, pour tous les dossiers.
String claudeCodeCommandFor(String connectorUrl) =>
    'claude mcp add --transport http --scope user deckhand $connectorUrl';

/// Un assistant autorisé.
class AssistantGrant {
  const AssistantGrant({
    required this.clientId,
    required this.name,
    this.grantedAt,
  });

  final String clientId;
  final String name;
  final DateTime? grantedAt;
}

/// Lit la réponse de `GET /auth/v1/user/oauth/grants`.
List<AssistantGrant> grantsFromJson(Object? json) {
  if (json is! List) return const [];
  final grants = <AssistantGrant>[];
  for (final entry in json) {
    if (entry is! Map) continue;
    final client = entry['client'];
    if (client is! Map) continue;
    final id = client['id'];
    if (id is! String || id.isEmpty) continue;
    final name = client['name'];
    final at = entry['granted_at'];
    grants.add(
      AssistantGrant(
        clientId: id,
        name: name is String && name.trim().isNotEmpty
            ? name.trim()
            : 'Assistant sans nom',
        grantedAt: at is String ? DateTime.tryParse(at) : null,
      ),
    );
  }
  return grants;
}

/// Ce qu'on lève quand GoTrue refuse ou répond de travers.
class AssistantAccessUnavailable implements Exception {
  const AssistantAccessUnavailable();

  @override
  String toString() =>
      'La liste des assistants est indisponible. Réessayez dans un instant.';
}

class AssistantRepository {
  /// [accessToken] rend le jeton de la session de l'application : une fonction
  /// plutôt que le client Supabase, pour qu'un test la remplace sans session.
  AssistantRepository({
    required this._accessToken,
    http.Client? httpClient,
    this._supabaseUrl = SupabaseConfig.url,
    this._publishableKey = SupabaseConfig.publishableKey,
  }) : _http = httpClient ?? http.Client();

  final String? Function() _accessToken;
  final http.Client _http;
  final String _supabaseUrl;
  final String _publishableKey;

  String get connectorUrl => connectorUrlFor(_supabaseUrl);

  Uri get _grants =>
      Uri.parse('${_sansBarreFinale(_supabaseUrl)}/auth/v1/user/oauth/grants');

  Map<String, String> _headers() {
    final token = _accessToken();
    if (token == null) throw const AssistantAccessUnavailable();
    return {'apikey': _publishableKey, 'Authorization': 'Bearer $token'};
  }

  Future<List<AssistantGrant>> grants() async {
    final response = await _http.get(_grants, headers: _headers()).timedOut();
    if (response.statusCode != 200) throw const AssistantAccessUnavailable();
    return grantsFromJson(jsonDecode(utf8.decode(response.bodyBytes)));
  }

  /// Retire l'accès d'un assistant : il ne pourra plus renouveler son jeton.
  Future<void> revoke(String clientId) async {
    final uri = _grants.replace(queryParameters: {'client_id': clientId});
    final response = await _http.delete(uri, headers: _headers()).timedOut();
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw const AssistantAccessUnavailable();
    }
  }
}

final assistantRepositoryProvider = Provider<AssistantRepository>(
  (ref) => AssistantRepository(
    accessToken: () =>
        Supabase.instance.client.auth.currentSession?.accessToken,
  ),
);

/// Les assistants autorisés, relus à chaque ouverture de l'écran.
final assistantGrantsProvider =
    FutureProvider.autoDispose<List<AssistantGrant>>(
      (ref) => ref.watch(assistantRepositoryProvider).grants(),
    );
