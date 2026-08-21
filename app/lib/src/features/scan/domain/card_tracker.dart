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
/// | | `gap` 4 | `gap` 8 | `gap` 15 | `gap` 30 | `gap` 45 |
/// |---|---|---|---|---|---|
/// | `min` 2 | 17/17 | 16/17 | 16/17 | 16/17 | 16/17 |
/// | `min` 3 | **17/17** | 16/17 | 16/17 | **16/17** | 16/17 |
/// | `min` 5 | 11/17 | 11/17 | 6/17 | 6/17 | 6/17 |
/// | `min` 8 | 11/17 | 11/17 | 6/17 | 6/17 | 6/17 |
///
/// **Aucune carte inventée, dans aucun réglage.** Et c'est précisément la
/// limite de ce banc : ses images sont composées, la reconnaissance n'y
/// clignote jamais, si bien qu'il ne peut pas produire l'erreur chère. Une
/// passe réelle l'a produite au premier essai — deux exemplaires pour une carte
/// présentée une fois, neuf sur une autre.
///
/// Un `min` de 5 manque les passages brefs. Le `gap` vient donc du terrain et
/// non d'ici, le banc ne servant qu'à chiffrer ce que l'allongement coûte.
/// D'où **3 et 30**.
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
/// **Le terrain a corrigé le banc, de 4 à 30.** À 4 images — treize centièmes
/// de seconde —, une passe réelle a compté **deux exemplaires** de chacune des
/// deux cartes présentées une fois, et jusqu'à **neuf** sur une autre. La
/// reconnaissance clignote : elle décroche quelques images sur un reflet ou une
/// mise au point, raccroche, et chaque raccrochage passait pour une carte
/// nouvellement posée.
///
/// Le banc ne pouvait pas le voir — ses images sont composées, sans flou de
/// bougé ni protège-carte. Il dit en revanche ce que l'allongement coûte, et
/// c'est peu (17 passages, `min` 3) :
///
/// | `gap` | trouvées | manquées | **inventées** |
/// |---|---|---|---|
/// | 4 | 17 | 0 | 0 |
/// | 8 | 16 | 1 | 0 |
/// | 15 | 16 | 1 | 0 |
/// | **30** | **16** | **1** | **0** |
/// | 45 | 16 | 1 | 0 |
///
/// Le prix est **une passe manquée sur dix-sept**, entièrement payé dès 8 : le
/// plateau qui suit dit que la séquence ne contient qu'un seul retrait assez
/// bref pour en souffrir. Aller à 45 ne coûterait rien de plus au banc, mais 30
/// est une seconde pleine — la durée qu'il faut vraiment pour retirer une carte
/// et en poser une identique, et une durée qui se raconte.
///
/// L'asymétrie tranche le reste : un exemplaire inventé fausse la collection et
/// toutes les suggestions de decks qui en découlent, quand un doublon manqué se
/// rattrape en repassant la carte.
const int defaultGapFrames = 30;

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
      // **Mais une absence qui dure éteint ce qu'on regarde.** [watching] dit
      // ce que le flux montre *en ce moment* ; le laisser sur son dernier
      // identifiant faisait afficher « Carte reconnue… » en vert pendant que le
      // relevé, dans le même écran, annonçait « sans carte 91 % » — deux
      // affirmations contraires au même instant, et un panier vide.
      //
      // Le seuil est [gapFrames], celui qui sert déjà à décider qu'une carte a
      // été retirée : en deçà c'est un flou, au-delà c'est une absence. La
      // série repart alors de zéro, ce qui est le sens même de ce seuil.
      if (_absence >= gapFrames) {
        _watching = null;
        _streak = 0;
      }
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
