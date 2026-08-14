/// À quoi sert une carte dans un deck.
///
/// **Reconnu au texte, faute de mieux.** Aucun catalogue ne dit qu'une carte
/// « sert de retrait » ; son texte oracle, lui, dit « Destroy target ». Les
/// motifs ci-dessous sont ceux qu'emploient les outils communautaires, et ils
/// sont volontairement grossiers : ils ratent les tournures inhabituelles et
/// comptent une carte dans plusieurs rôles quand elle en remplit plusieurs.
///
/// **C'est suffisant pour ce qu'on en fait.** Le constructeur ne cherche pas à
/// comprendre un deck, il cherche à ne pas en produire un sans retrait ni
/// pioche. Un ordre de grandeur juste vaut mieux qu'une classification fine
/// dont la moitié des cas serait fausse — et le corpus mesuré donne des cibles
/// exprimées avec la même grossièreté, ce qui rend les deux comparables.
///
/// **Les rôles se recouvrent, et c'est voulu.** Une créature qui produit du
/// mana est à la fois créature et rampe ; l'exclure de l'un des deux comptes
/// fausserait celui-là. Les quotas du constructeur tiennent compte de ce
/// recouvrement, puisqu'ils ont été mesurés de la même façon
/// (`api/app/measure/deck_anatomy.py`).
library;

import 'buildable_card.dart';

enum CardRole {
  // --- Magic -----------------------------------------------------------
  /// Produire du mana ou aller chercher un terrain : dans les deux cas, la
  /// carte sert à accélérer.
  ramp,

  /// Détruire, exiler, ou infliger des blessures à une cible.
  removal,

  /// Piocher des cartes.
  draw,

  creature,

  land,

  // --- Yu-Gi-Oh --------------------------------------------------------
  /// **Les axes de ce jeu ne sont pas ceux de Magic**, et les lui emprunter
  /// rendrait des zéros partout : aucune de ses 13 866 cartes ne porte
  /// « Creature » ni « Land ». Ses trois familles partitionnent le deck
  /// principal — un monstre n'est ni une magie ni un piège —, là où les rôles
  /// Magic se recouvrent.
  monster,

  spell,

  trap,

  /// Magie rapide : jouable pendant le tour adverse, la seule magie qui réponde.
  quickSpell,

  /// Piège continu : reste en jeu au lieu de se résoudre puis partir.
  continuousTrap,

  // --- Pokémon ---------------------------------------------------------
  /// **Ce jeu ne dose que trois choses**, et elles partitionnent le deck : des
  /// Pokémon, des cartes Dresseur, des Énergies. Ni terrain, ni courbe de coût —
  /// mesuré sur 17 295 decks Standard, `cmc` y porte les points de vie, dont
  /// aucun découpage ne décrit une contrainte de construction.
  pokemon,

  trainer,

  energy,

  /// Un Supporter par tour : la carte la plus contrainte du jeu, donc celle
  /// qu'un deck dose le plus étroitement (écart interquartile de 3,3 points).
  supporter,

  /// Objet : jouable sans limite de nombre dans le tour.
  item,

  /// Stade : un seul en jeu, et il remplace celui de l'adversaire.
  stadium,
}

/// Les rôles que ce jeu sait reconnaître, dans l'ordre où on les affiche.
///
/// Sert au diagnostic et à l'écran : montrer un quota de créatures sur un deck
/// Yu-Gi-Oh dirait « il en manque 21 » d'une carte qui n'existe pas.
Set<CardRole> rolesFor(String game) => switch (game) {
  'yugioh' => const {
    CardRole.monster,
    CardRole.spell,
    CardRole.trap,
    CardRole.quickSpell,
    CardRole.continuousTrap,
  },
  'pokemon' => const {
    CardRole.pokemon,
    CardRole.trainer,
    CardRole.energy,
    CardRole.supporter,
    CardRole.item,
    CardRole.stadium,
  },
  _ => const {
    CardRole.creature,
    CardRole.draw,
    CardRole.ramp,
    CardRole.removal,
    CardRole.land,
  },
};

/// Motifs de reconnaissance, en anglais comme le texte oracle du catalogue.
///
/// Le français n'est pas une option : `cards.oracle_text` porte le texte de
/// référence, qui n'est traduit nulle part dans la base.
final _ramp = RegExp(
  r'add \{|search your library for a[^.]*land',
  caseSensitive: false,
);
final _removal = RegExp(
  r'destroy target|exile target|deals \d+ damage to target',
  caseSensitive: false,
);
final _draw = RegExp(r'draw (a|\w+) card', caseSensitive: false);

/// Rôles remplis par [card]. Une carte peut en tenir plusieurs, ou aucun.
///
/// **La lecture dépend du jeu**, parce que les axes en dépendent. Lire une
/// carte Yu-Gi-Oh avec les motifs de Magic ne renverrait rien du tout : son
/// texte ne dit pas « Destroy target » mais « destroy that target », son type ne
/// dit pas « Creature » mais « Monster ». Un ensemble vide se lirait comme une
/// carte sans rôle, non comme une lecture inadaptée.
Set<CardRole> rolesOf(BuildableCard card) =>
    switch (card.game) {
      'yugioh' => _yugiohRoles(card),
      'pokemon' => _pokemonRoles(card),
      _ => _magicRoles(card),
    };

/// **Le type imprimé suffit, comme chez Yu-Gi-Oh.** « Pokemon — Basic Water »,
/// « Trainer — Supporter » : la source publie la famille et sa sous-famille, et
/// aucune ne se devine dans un texte.
///
/// Les trois familles principales partitionnent le deck ; les sous-familles
/// Dresseur s'y ajoutent au lieu de le découper, un Supporter restant un
/// Dresseur. C'est le même recouvrement volontaire que chez Magic, où une
/// créature qui produit du mana compte dans les deux.
Set<CardRole> _pokemonRoles(BuildableCard card) {
  final type = card.typeLine;
  final roles = <CardRole>{};
  if (type.startsWith('Pokemon')) roles.add(CardRole.pokemon);
  if (type.startsWith('Energy')) roles.add(CardRole.energy);
  if (type.startsWith('Trainer')) {
    roles.add(CardRole.trainer);
    if (type.contains('Supporter')) roles.add(CardRole.supporter);
    if (type.contains('Item')) roles.add(CardRole.item);
    if (type.contains('Stadium')) roles.add(CardRole.stadium);
  }
  return roles;
}

Set<CardRole> _magicRoles(BuildableCard card) {
  final roles = <CardRole>{};
  if (card.isLand) roles.add(CardRole.land);
  if (card.isCreature) roles.add(CardRole.creature);

  final text = card.oracleText;
  if (text.isEmpty) return roles;

  // Un terrain produit du mana par définition ; le compter comme rampe
  // gonflerait ce quota de trente-huit cartes et le rendrait ininterprétable.
  if (!card.isLand && _ramp.hasMatch(text)) roles.add(CardRole.ramp);
  if (_removal.hasMatch(text)) roles.add(CardRole.removal);
  if (_draw.hasMatch(text)) roles.add(CardRole.draw);

  return roles;
}

/// **Le type suffit, et c'est une chance.** Là où Magic doit deviner un rôle
/// dans le texte oracle — méthode grossière assumée —, Yu-Gi-Oh l'imprime :
/// « Quick-Play Spell », « Continuous Trap ». Les trois familles principales
/// sont exclusives, ce que le corpus confirme, et les deux sous-familles sont
/// des raffinements que la mesure a trouvés assez réguliers pour être dosés.
Set<CardRole> _yugiohRoles(BuildableCard card) {
  final type = card.typeLine;
  final roles = <CardRole>{};
  // Une carte d'Extra Deck est un monstre, mais elle ne compte pas dans les
  // quotas du deck principal : elle occupe une autre zone, et l'y compter
  // fausserait la part des monstres de moitié.
  if (type.contains('Monster') && !card.isExtraDeck) roles.add(CardRole.monster);
  if (type.contains('Spell Card')) roles.add(CardRole.spell);
  if (type.contains('Trap Card')) roles.add(CardRole.trap);
  if (type.contains('Quick-Play Spell')) roles.add(CardRole.quickSpell);
  if (type.contains('Continuous Trap')) roles.add(CardRole.continuousTrap);
  return roles;
}
