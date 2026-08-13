/// Distinguer « nouvelle carte » de « encore la même », au fil d'un flux.
///
/// **Le problème que ce module résout.** Le mode photo voit une carte une fois ;
/// le flux la voit trente fois par seconde. Sans règle temporelle, poser une
/// carte devant l'objectif remplirait le panier de trente exemplaires par
/// seconde, et le journal de diagnostic serait illisible pour la même raison.
///
/// **C'est le cousin temporel de `areSameCard`**, qui sépare deux exemplaires
/// posés côte à côte sur un étalement. Là c'était une distance en pixels ; ici
/// c'est une distance en images. Le principe est le même : deux observations
/// proches désignent le même objet, deux observations séparées désignent deux
/// objets.
///
/// **La règle, en deux nombres.** Une carte est retenue après [minFrames]
/// images consécutives portant son identifiant. Elle ne peut être retenue une
/// seconde fois qu'après [gapFrames] images où elle n'apparaît pas — ce qui
/// distingue « j'ai retiré la carte et j'en ai posé une identique » de « la mise
/// au point a hésité une image ».
///
/// Les deux erreurs qu'ils arbitrent ne coûtent pas le même prix. Un
/// [minFrames] trop bas laisse entrer une reconnaissance accidentelle ; un
/// [gapFrames] trop bas **invente un exemplaire** que l'utilisateur ne possède
/// pas, et fausse ensuite toutes ses suggestions de decks. C'est cette
/// asymétrie qui devra guider leur réglage.
///
/// **Ces deux valeurs sont mesurées** (`dart run tool/stream_bench.dart`, sur
/// des séquences composées portant les quatre événements qui les arbitrent :
/// carte posée, échangée sur place, montrée brièvement, retirée). Onze passages
/// réels, douze réglages balayés :
///
/// | | `gap` 2 | `gap` 4 | `gap` 8 |
/// |---|---|---|---|
/// | `min` 2 | 11/11 | 11/11 | 10/11 |
/// | `min` 3 | **11/11** | **11/11** | 10/11 |
/// | `min` 5 | 7/11 | 7/11 | 7/11 |
/// | `min` 8 | 7/11 | 7/11 | 7/11 |
///
/// **Aucune carte inventée, dans aucun réglage.** C'est le résultat qui compte :
/// l'erreur chère — le même exemplaire compté deux fois — ne s'est produite
/// nulle part, et le réglage n'arbitre donc qu'entre du calcul et des cartes
/// manquées.
///
/// Un `min` de 5 manque les quatre passages brefs ; un `gap` de 8 dépasse la
/// durée d'un retrait et refuse une carte qui revient. D'où **3 et 4**.
///
/// **Ce que la mesure ne peut pas dire.** Le rôle de [minFrames] est de rejeter
/// une reconnaissance *accidentelle*, et des images composées n'en produisent
/// aucune : le banc l'optimise donc sur la seule moitié qu'il sait voir. Le
/// garde-fou contre une carte fausse n'est de toute façon pas ici — c'est la
/// marge de confiance de l'index, chiffrée par `art_collisions`, puis la liste
/// à cocher que l'utilisateur valide (§IV.8).
///
/// Exemple :
/// ```dart
/// final tracker = CardTracker();
/// for (final frame in flux) {
///   final trouvee = tracker.observe(reconnaissance(frame));
///   if (trouvee != null) panier.ajouter(trouvee);
/// }
/// ```
library;

/// Images consécutives portant le même identifiant avant de retenir une carte.
///
/// **Mesuré à 3.** Au-delà, les passages brefs sont manqués — quatre sur onze
/// à 5 images. En deçà, rien ne se gagne sur la séquence du banc, et la marge
/// contre une reconnaissance accidentelle se réduit sans contrepartie. À
/// 30 images par seconde, 3 images valent un dixième de seconde.
const int defaultMinFrames = 3;

/// Images sans la carte avant d'accepter qu'elle revienne.
///
/// **Mesuré à 4**, et confirmé dans le bon sens : aucune carte n'a été inventée
/// à ce réglage ni à aucun autre. C'est pourtant le nombre qui décide si deux
/// exemplaires identiques comptent pour deux, et son erreur chère est de
/// sous-estimer. Au-dessus, il dépasse la durée d'un retrait et refuse une carte
/// qui revient : à 8 images, un passage sur onze est perdu.
const int defaultGapFrames = 4;

/// Suit ce que le flux montre, et n'annonce une carte qu'une fois.
///
/// Objet à état : une instance par session de scan. [reset] la rend à son état
/// initial entre deux boosters.
class CardTracker {
  CardTracker({
    this.minFrames = defaultMinFrames,
    this.gapFrames = defaultGapFrames,
  });

  /// Images consécutives nécessaires pour retenir une carte.
  final int minFrames;

  /// Images sans une carte avant de pouvoir la retenir à nouveau.
  final int gapFrames;

  String? _watching;
  int _streak = 0;
  String? _lastEmitted;
  int _absence = 0;

  /// Identifiant que le flux montre en ce moment, avant toute décision.
  ///
  /// Exposé pour l'écran et le journal : ils ont besoin de dire ce que
  /// l'appareil regarde, pas seulement ce qu'il a fini par retenir.
  String? get watching => _watching;

  /// Nombre d'images consécutives déjà vues sur [watching].
  int get streak => _streak;

  /// Rend l'identifiant **au moment précis** où une carte est retenue, sinon
  /// `null`.
  ///
  /// Appeler cette méthode à chaque image du flux ; l'ajout au panier se fait
  /// sur son résultat non nul, ce qui garantit une entrée par carte physique.
  String? observe(String? oracleId) {
    if (oracleId == null) {
      // **Une image muette n'interrompt pas la série.** Un flou de mise au
      // point ou un reflet fait taire la reconnaissance sans que la carte ait
      // bougé ; remettre le compteur à zéro obligerait à tenir la carte
      // parfaitement immobile.
      _absence++;
      return null;
    }

    if (oracleId != _watching) {
      _watching = oracleId;
      _streak = 1;
    } else {
      _streak++;
    }

    // Toute image portant un identifiant rompt l'absence de *cet* identifiant.
    // Les images muettes intercalées comptent donc pour l'écart, mais une
    // autre carte reconnue entre-temps ne le fait pas — c'est délibéré : elle
    // prouve mieux qu'un blanc que la première a bien été retirée.
    if (oracleId == _lastEmitted && _absence < gapFrames) {
      _streak = 0;
      return null;
    }

    if (_streak < minFrames) return null;

    _streak = 0;
    _absence = 0;
    _lastEmitted = oracleId;
    return oracleId;
  }

  /// Oublie tout. À appeler entre deux lots, sans quoi la première carte du
  /// second compterait comme la suite du premier.
  void reset() {
    _watching = null;
    _streak = 0;
    _lastEmitted = null;
    _absence = 0;
  }
}
