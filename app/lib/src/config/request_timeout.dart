/// Le délai au-delà duquel une requête est tenue pour perdue.
///
/// **Sans lui, l'écran tourne indéfiniment.** Une requête HTTP suspendue — le
/// réseau qui se ferme sans le dire, un VPN qui bascule, un Wi-Fi qu'on quitte
/// pour les données mobiles — ne reçoit ni réponse ni erreur : la connexion TCP
/// est morte, mais personne ne l'annonce. Le `Future` reste alors en attente
/// pour toujours, et l'indicateur de chargement avec lui. L'utilisateur n'a
/// aucun recours : ni message, ni bouton, ni fin.
///
/// Le diagnostic avait déjà été posé pour l'index d'empreintes, qui porte son
/// propre délai depuis. Il vaut pour **tout** appel réseau, et c'est ici qu'il
/// est écrit une fois pour toutes.
///
/// **Ce n'est pas une limite de performance.** Le serveur répond à toutes les
/// fonctions de l'application en moins d'une seconde, les quatre du démarrage
/// lancées ensemble comprises. Vingt secondes laissent donc vingt fois la marge
/// mesurée sur un réseau lent, tout en rendant une panne visible en vingt
/// secondes plutôt que jamais.
///
/// Usage : `await client.rpc<T>(...).timedOut()`.
library;

import 'dart:async';

import 'package:http/http.dart' show ClientException;

/// Délai accordé à un appel réseau avant de le déclarer perdu.
const Duration requestTimeout = Duration(seconds: 20);

/// Ce qu'on lève quand le délai est dépassé.
///
/// **Un type à nous plutôt que le `TimeoutException` de Dart** : l'interface
/// affiche le message tel quel, et « TimeoutException after 0:00:20.000000 »
/// ne dit rien à qui tient un téléphone. Le texte nomme la cause probable —
/// c'est presque toujours le réseau, jamais le serveur.
class RequestTimedOut implements Exception {
  const RequestTimedOut();

  @override
  String toString() =>
      'Le serveur n\'a pas répondu. Vérifiez votre connexion, puis réessayez.';
}

/// Ce qu'on lève quand le serveur n'a pas même pu être joint.
///
/// **Ne pas répondre et ne pas être joignable sont deux pannes distinctes**, et
/// une seule des deux se guérit en attendant. Un délai dépassé laisse espérer
/// qu'un second essai aboutisse ; un nom de serveur qu'on ne sait pas résoudre
/// dit que la requête n'est jamais partie — inutile d'insister avant d'avoir
/// rétabli quelque chose.
///
/// Le message nomme le VPN parce que c'est la cause la plus fréquente ici : un
/// tunnel actif impose son propre résolveur, et celui-ci peut échouer alors même
/// que le reste du réseau fonctionne. Sans cette mention, l'utilisateur voyait
/// « ClientException with SocketException: Failed host lookup », qui ne dit rien
/// à qui tient un téléphone.
class NetworkUnreachable implements Exception {
  const NetworkUnreachable();

  @override
  String toString() =>
      'Serveur injoignable. Vérifiez votre connexion — un VPN actif peut aussi '
      'en être la cause.';
}

extension TimedOutFuture<T> on Future<T> {
  /// Abandonne au bout de [requestTimeout] plutôt que d'attendre sans fin, et
  /// traduit l'injoignable en message lisible.
  ///
  /// `ClientException` plutôt que `SocketException` : la seconde vient de
  /// `dart:io`, absent du web, et l'importer casserait cette cible. Le client
  /// HTTP de Supabase enveloppe de toute façon la première autour de la
  /// seconde — c'est littéralement ce que l'écran affichait.
  Future<T> timedOut([Duration limit = requestTimeout]) async {
    try {
      return await timeout(
        limit,
        onTimeout: () => throw const RequestTimedOut(),
      );
    } on ClientException {
      throw const NetworkUnreachable();
    }
  }
}
