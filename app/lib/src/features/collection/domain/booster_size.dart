/// Ce qu'un booster contient, et ce qu'il coûte par défaut.
///
/// **Deux natures de nombre, et une seule vit ici pour de bon.**
///
/// La **taille** d'un booster est un fait publié par l'éditeur : elle figure sur
/// l'emballage, ne change qu'à un remaniement de format — Magic est passé de 15
/// à 14 en adoptant le Play Booster — et vaut pour tout le monde. Elle est donc
/// inscrite ici, et elle y reste.
///
/// Le **prix**, lui, n'existe pas au singulier. Relevé le 24 août 2026, même
/// produit, même jour :
///
/// | Produit | Enseigne A | Enseigne B |
/// |---|---|---|
/// | Pokémon Méga-Évolution FR | 4,99 € (Micromania) | 9,90 € (Play-in) |
/// | Magic Play Booster | 5,29 € (par display) | 7,40 € (à l'unité) |
///
/// Près du double d'écart. Un prix inscrit dans le code serait donc faux pour à
/// peu près tout le monde, et faux **sans le dire**. Celui qui figure ici n'est
/// qu'un **repère** — un relevé daté chez un détaillant nommé — et l'utilisateur
/// peut lui substituer le sien, qui est le seul juste puisque l'indicateur
/// répond à « combien **j'aurais** dépensé ». Voir `profiles.booster_prices`.
///
/// **Un jeu absent de cette table n'affiche pas ces indicateurs**, plutôt que
/// d'en afficher d'inventés. Les huit y figurent aujourd'hui ; un neuvième jeu
/// devra y être ajouté à la main, et son absence est une omission visible, pas
/// une valeur par défaut silencieuse.
library;

/// Ce que l'on sait d'un booster : sa taille, et un prix de repère.
class BoosterFacts {
  const BoosterFacts({
    required this.cards,
    required this.referencePriceEur,
    required this.source,
  });

  /// Cartes par booster, telles que l'éditeur les annonce sur l'emballage.
  ///
  /// Jetons, cartes-code et cartes d'information comprises quand l'éditeur les
  /// compte — c'est son décompte qui fait foi, pas le nôtre, sans quoi le
  /// nombre cesserait d'être vérifiable sur une boîte.
  final int cards;

  /// Prix de repère, en euros. **Périssable et non contractuel** : un relevé
  /// chez un détaillant à une date, que l'utilisateur est censé remplacer.
  final double referencePriceEur;

  /// Où le prix a été relevé, et quand. Sans cela, le nombre ci-dessus
  /// redeviendrait dans six mois une valeur dont personne ne sait d'où elle
  /// sort — ce qu'il était.
  final String source;
}

/// Ce que l'on sait, jeu par jeu.
///
/// Les prix viennent tous de Philibert le 24 août 2026, sauf Wankul (boutique
/// de l'éditeur) et Pokémon (voir la note). **Un seul détaillant à une seule
/// date** : mélanger les enseignes donnerait une moyenne que rien ne permet de
/// re-vérifier.
const Map<String, BoosterFacts> boosterFacts = {
  // Play Booster, format en vigueur depuis 2024 (ex-Draft Booster à 15).
  'magic': BoosterFacts(
    cards: 14,
    referencePriceEur: 6.90,
    source: 'Philibert, 2026-08-24',
  ),
  // 7 communes, 3 peu communes, 2 rares+ brillantes, 1 brillante, 1 jeton.
  'riftbound': BoosterFacts(
    cards: 14,
    referencePriceEur: 5.95,
    source: 'Philibert, 2026-08-24',
  ),
  // Le format à 9 cartes est celui des extensions principales ; quelques
  // séries dérivées descendent à 5 ou 7, et sont ignorées ici.
  'yugioh': BoosterFacts(
    cards: 9,
    referencePriceEur: 4.50,
    source: 'Philibert, 2026-08-24',
  ),
  // **Le prix le plus instable des huit** : 4,99 € chez Micromania et 9,90 €
  // chez Play-in le même jour, pour la même extension. Le repère retenu est le
  // bas de la fourchette, celui d'une extension installée ; une sortie récente
  // coûte couramment le double.
  'pokemon': BoosterFacts(
    cards: 10,
    referencePriceEur: 4.99,
    source: 'Micromania, 2026-08-24',
  ),
  // Boutique de l'éditeur — source primaire, la seule des huit.
  'wankul': BoosterFacts(
    cards: 10,
    referencePriceEur: 5.50,
    source: 'wankul.fr, 2026-08-24',
  ),
  // 9 communes, 3 peu communes, 1 rare+, 1 leader, 1 base, 1 brillante.
  'swu': BoosterFacts(
    cards: 16,
    referencePriceEur: 4.99,
    source: 'Philibert, 2026-08-24',
  ),
  // Les boosters japonais font 6 à 9 cartes ; c'est le format français qui est
  // retenu, puisque c'est celui que le catalogue ingéré décrit.
  'onepiece': BoosterFacts(
    cards: 12,
    referencePriceEur: 5.95,
    source: 'Philibert, 2026-08-24',
  ),
  'lorcana': BoosterFacts(
    cards: 12,
    referencePriceEur: 5.90,
    source: 'Philibert, 2026-08-24',
  ),
};

/// Ce qu'un booster de ce jeu contient et coûte, ou `null` si on l'ignore.
BoosterFacts? boosterFactsFor(String game) => boosterFacts[game];

/// Le prix à retenir pour ce jeu : celui de l'utilisateur s'il en a donné un,
/// le repère sinon.
///
/// **Zéro est une réponse, pas une absence.** Quelqu'un qui n'achète jamais de
/// boosters l'inscrit à zéro, et l'indicateur affiche alors zéro euro plutôt
/// que de lui prêter des dépenses qu'il n'a pas faites. C'est pourquoi le repli
/// se fait sur `null` et non sur une valeur fausse.
double? boosterPriceFor(String game, Map<String, double> mine) {
  final chosen = mine[game];
  if (chosen != null) return chosen;
  return boosterFacts[game]?.referencePriceEur;
}

/// Lit un prix saisi à la main, ou `null` si la saisie ne dit rien d'exploitable.
///
/// **La virgule est la façon française d'écrire un prix**, et un clavier
/// numérique de téléphone n'offre souvent qu'elle : refuser « 6,90 » au motif
/// que Dart attend un point ferait échouer la saisie la plus naturelle.
///
/// Une chaîne vide rend `null`, et l'appelant le lit comme « je retire ma
/// déclaration » — d'où la nécessité de distinguer ce cas d'un zéro, qui est
/// une réponse. Un nombre négatif est refusé : il produirait une dépense
/// négative, c'est-à-dire un indicateur qui ment sur son signe.
double? parseBoosterPrice(String raw) {
  final cleaned = raw.trim().replaceAll(',', '.').replaceAll(' ', '');
  if (cleaned.isEmpty) return null;
  final value = double.tryParse(cleaned);
  if (value == null || value.isNaN || value < 0) return null;
  return value;
}
