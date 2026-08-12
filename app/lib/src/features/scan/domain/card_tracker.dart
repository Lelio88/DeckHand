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
/// **Ces deux valeurs ne sont pas mesurées.** Elles attendent une séquence
/// réelle — un booster passé devant l'objectif, journalisé image par image — et
/// se régleront comme le seuil de l'étalement : en rejouant le journal hors
/// ligne, jamais en reconstruisant l'application à chaque essai. Les valeurs
/// par défaut ci-dessous sont un point de départ explicite, pas un résultat.
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
/// **Provisoire, et à mesurer.** Trop bas, une reconnaissance accidentelle
/// entre au panier ; trop haut, une carte montrée brièvement est manquée. À
/// 30 images par seconde, 5 images valent un sixième de seconde — le temps de
/// poser une carte et de la laisser.
const int defaultMinFrames = 5;

/// Images sans la carte avant d'accepter qu'elle revienne.
///
/// **Provisoire, et à mesurer.** C'est le nombre qui décide si deux exemplaires
/// identiques comptent pour deux. Le sous-estimer invente des cartes ; le
/// surestimer en perd. La première erreur est la plus coûteuse — une carte
/// inventée fausse durablement les suggestions —, donc ce seuil doit pencher
/// vers la prudence.
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
