/// Les pages légales publiées, et le moyen de les ouvrir.
///
/// **Elles vivent sur le web, pas dans l'application.** Une copie embarquée
/// divergerait de la version en ligne au premier changement, alors que Google
/// Play et la loi renvoient à une seule adresse. L'application résume et
/// renvoie vers elles.
///
/// Servies par GitHub Pages depuis `app/web/` (`.github/workflows/pages.yml`).
/// Changer de domaine, c'est changer [webBase] — et `shareBaseUrl` en dépend.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Le site public de DeckHand : pages légales et classeurs partagés.
const String webBase = 'https://deckhand.heianenterprise.com';

abstract final class LegalLinks {
  static final Uri home = Uri.parse('$webBase/accueil.html');
  static final Uri privacy = Uri.parse('$webBase/privacy.html');
  static final Uri terms = Uri.parse('$webBase/cgu.html');
  static final Uri legalNotice = Uri.parse('$webBase/mentions-legales.html');
  static final Uri accountDeletion = Uri.parse(
    '$webBase/suppression-compte.html',
  );
  static final Uri assistant = Uri.parse('$webBase/assistant.html');
}

/// Ouvre une adresse hors de l'application ; rend faux si rien n'a pu l'ouvrir.
///
/// Un provider plutôt qu'un appel direct à `url_launcher` : les tests le
/// remplacent et vérifient l'adresse demandée sans ouvrir de navigateur.
final externalLinkOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);
