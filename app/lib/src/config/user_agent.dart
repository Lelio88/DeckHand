/// Comment l'application s'annonce aux sources qu'elle interroge.
///
/// **C'est une obligation, pas une politesse** (`CLAUDE.md` §IV.4) : Scryfall
/// demande un `User-Agent` descriptif, et `api/` en envoie un depuis toujours.
/// L'application, elle, n'en envoyait aucun — elle s'en remettait à celui que
/// Dart pose par défaut.
///
/// **Elle fonctionnait par chance, pas par conformité.** Mesuré sur
/// `cards.scryfall.io`, qui sert toutes les illustrations :
///
/// | En-tête envoyé | Réponse |
/// |---|---|
/// | aucun, client générique | **HTTP 400** `rule: generic_user_agent` |
/// | `Dart/3.5 (dart:io)` | HTTP 200 |
/// | un nom d'application et un contact | HTTP 200 |
///
/// Le défaut de Dart passe aujourd'hui le filtre. Le jour où Scryfall le
/// resserre — et c'est son droit, la règle existe déjà —, **toutes** les
/// illustrations tombent d'un coup sur mobile, sans qu'aucun test ne l'ait vu
/// venir : le web continuerait de fonctionner, le navigateur posant le sien.
///
/// **Aucun numéro de version.** Il faudrait le tenir à jour à chaque
/// publication, et une version fausse renseigne moins bien qu'une absence. Ce
/// que la source a besoin de savoir, c'est qui appelle et où écrire.
///
/// L'adresse est le **contact public** des applications, celle des fiches Play
/// et des pages légales — jamais une adresse personnelle.
///
/// **Sur le web, cet en-tête est ignoré** : les navigateurs interdisent de
/// remplacer `User-Agent` depuis du code. Ce n'est pas une perte, le navigateur
/// envoyant déjà le sien, qui n'a rien de générique. Le poser sans condition
/// évite un embranchement par plateforme pour un en-tête sans effet de bord.
library;

/// Ce que l'application met dans `User-Agent` sur ses appels sortants.
const String deckHandUserAgent = 'DeckHand (+heianenterpriseyt@gmail.com)';

/// L'en-tête prêt à joindre à une requête.
const Map<String, String> userAgentHeader = {'User-Agent': deckHandUserAgent};
