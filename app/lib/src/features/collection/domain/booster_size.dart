/// Combien de cartes, et combien d'euros, vaut un booster.
///
/// **À quoi cela sert.** Deux indicateurs de la page de profil se lisent en
/// boosters plutôt qu'en cartes : « combien de boosters cela représente » et
/// « ce que j'aurais dépensé si toutes mes cartes venaient de boosters
/// achetés ». Le second est le seul chiffre du projet qui ne se déduit d'aucune
/// donnée : il faut un prix, et aucune source ne le publie carte par carte.
///
/// **Ces valeurs vieillissent, et c'est assumé.** Le nombre de cartes par
/// booster change quand un éditeur remanie ses formats — Magic est passé de 15
/// à 14 en adoptant le Play Booster. Le prix, lui, bouge tous les ans. Les
/// inscrire ici les rend visibles et corrigibles en une ligne ; les déduire
/// d'une source les rendrait justes un jour et faux le lendemain, sans que rien
/// ne le signale.
///
/// **Un jeu absent de cette table n'affiche pas ces indicateurs**, plutôt que
/// d'en afficher d'inventés. C'est le cas de Riftbound et de Wankul, dont le
/// format de booster n'a pas été vérifié.
library;

/// Ce qu'on sait d'un booster : sa taille, et ce qu'il coûte.
class BoosterFacts {
  const BoosterFacts({required this.cards, required this.priceEur});

  /// Cartes par booster, jetons et cartes d'information exclus.
  final int cards;

  /// Prix indicatif à l'unité, en euros. **Périssable** : c'est un prix de
  /// boutique constaté, pas une cote suivie.
  final double priceEur;
}

/// Ce que l'on sait, jeu par jeu. Ce qui n'y est pas ne s'invente pas.
const Map<String, BoosterFacts> boosterFacts = {
  // Play Booster, format en vigueur depuis 2024.
  'magic': BoosterFacts(cards: 14, priceEur: 5.50),
};

/// Ce qu'un booster de ce jeu contient et coûte, ou `null` si on l'ignore.
BoosterFacts? boosterFactsFor(String game) => boosterFacts[game];
