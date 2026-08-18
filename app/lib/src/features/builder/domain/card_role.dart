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

  // --- Star Wars Unlimited ---------------------------------------------
  /// **Trois familles qui partitionnent le deck principal**, et le type les
  /// imprime — comme chez Yu-Gi-Oh et Pokémon, rien n'est deviné dans un texte.
  /// Mesuré sur 220 listes : 81,0 % d'unités, 12,0 % d'événements, 5,0 %
  /// d'améliorations.
  ///
  /// Le leader et la base n'y figurent pas : ils sont à **un exemplaire chacun
  /// dans 220 listes sur 220**, ce qui est une règle et non une proportion à
  /// doser. Le leader occupe `commander_oracle_id`, comme la Légende de
  /// Riftbound.
  unit,

  event,

  upgrade,

  /// One Piece — les trois familles du deck principal.
  ///
  /// `event` est partagé avec SWU : les deux jeux nomment ainsi une carte à
  /// effet unique que l'on joue puis défausse, et rien ne justifie deux membres
  /// pour la même notion. `character` et `stage` sont propres à One Piece.
  ///
  /// Le leader n'en est pas un : il occupe `commander_oracle_id`, comme celui
  /// de SWU et la Légende de Riftbound. On ne dose pas une carte dont il y a
  /// exactement un exemplaire.
  character,

  stage,

  /// Disney Lorcana — les familles propres à ce jeu.
  ///
  /// `character` et `item` sont **partagés avec d'autres jeux**, et ne sont donc
  /// pas redéclarés ici : One Piece nomme aussi « Character » sa famille
  /// principale, et Pokémon appelle « Objet » ce que Lorcana nomme « Item ».
  /// Deux membres pour la même notion feraient deux quotas là où le jeu en dose
  /// un.
  ///
  /// `song` est une **sous-famille** d'`action`, comme le Supporter est une
  /// sous-famille du Dresseur chez Pokémon : la ligne de type d'une Chanson vaut
  /// « Action Song », et elle compte dans les deux. Ce recouvrement est
  /// volontaire — le partitionnement l'est chez SWU et One Piece, pas ici.
  action,

  song,

  location,
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
  'swu' => const {CardRole.unit, CardRole.event, CardRole.upgrade},
  'onepiece' => const {CardRole.character, CardRole.event, CardRole.stage},
  // Wankul n'a que deux familles, et son règlement les dose toutes les deux :
  // dix terrains et quarante personnages, exactement. `character` et `land`
  // sont partagés avec d'autres jeux — un Terrain Wankul joue le rôle d'un
  // terrain de Magic, on ne le joue pas, on le pose.
  'wankul' => const {CardRole.character, CardRole.land},
  'lorcana' => const {
    CardRole.character,
    CardRole.action,
    CardRole.item,
    CardRole.song,
    CardRole.location,
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
      'swu' => _swuRoles(card),
      'onepiece' => _onepieceRoles(card),
      'wankul' => _wankulRoles(card),
      'lorcana' => _lorcanaRoles(card),
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

/// **Le type imprimé suffit, une troisième fois.** La ligne de type SWU
/// commence par le type publié par la source — « Unit — REBEL TROOPER »,
/// « Event », « Upgrade » — et c'est ce même vocabulaire qui décide de la
/// fenêtre d'illustration.
///
/// Les trois familles **partitionnent** le deck principal, contrairement aux
/// rôles Magic qui se recouvrent : une carte est une unité, un événement ou une
/// amélioration, jamais deux à la fois. Le leader et la base ne sont pas dosés
/// — un exemplaire chacun dans 220 listes sur 220 est une règle, pas une
/// proportion.
Set<CardRole> _swuRoles(BuildableCard card) {
  final type = card.typeLine;
  if (type.startsWith('Unit')) return const {CardRole.unit};
  if (type.startsWith('Event')) return const {CardRole.event};
  if (type.startsWith('Upgrade')) return const {CardRole.upgrade};
  return const {};
}

/// **Le type imprimé suffit**, comme chez SWU, Yu-Gi-Oh et Pokémon.
///
/// Le catalogue publie « Character — Straw Hat Crew », « Event », « Stage » :
/// la famille est le premier mot, la sous-famille est l'équipage — qui décore
/// la carte sans rien imposer à la construction, et n'est donc pas un rôle.
///
/// Les trois familles **partitionnent** le deck principal : une carte est un
/// personnage, un événement ou un décor, jamais deux à la fois. Le leader est
/// absent de ce dosage, comme celui de SWU.
Set<CardRole> _onepieceRoles(BuildableCard card) {
  final type = card.typeLine;
  if (type.startsWith('Character')) return const {CardRole.character};
  if (type.startsWith('Event')) return const {CardRole.event};
  if (type.startsWith('Stage')) return const {CardRole.stage};
  return const {};
}

/// **Deux familles, et le type imprimé les sépare** — `Personnage` (812 cartes)
/// et `Terrain` (146).
///
/// C'est la seule information dont le règlement ait besoin : il impose dix
/// terrains et quarante personnages. La contrainte « cinq scoreurs au maximum »
/// n'est pas vérifiable — la source ne publie pas quelles cartes sont des
/// scoreurs —, mais c'est un **maximum** et non un minimum : l'ignorer ne
/// produit aucun deck illégal.
Set<CardRole> _wankulRoles(BuildableCard card) {
  final type = card.typeLine;
  if (type.startsWith('Terrain')) return const {CardRole.land};
  if (type.startsWith('Personnage')) return const {CardRole.character};
  return const {};
}

/// **Le type imprimé suffit**, comme chez les quatre autres jeux non-Magic.
///
/// La particularité tient à la Chanson : sa ligne de type vaut « Action Song »,
/// et elle compte **dans les deux** familles. C'est le même recouvrement
/// volontaire que chez Magic, où une créature qui produit du mana est créature
/// *et* rampe — et l'inverse du partitionnement strict de SWU et One Piece.
///
/// Le lister comme famille propre découperait les Actions en deux et ferait
/// annoncer un manque d'Actions à qui joue des Chansons.
Set<CardRole> _lorcanaRoles(BuildableCard card) {
  final type = card.typeLine;
  if (type.startsWith('Character')) return const {CardRole.character};
  if (type.startsWith('Item')) return const {CardRole.item};
  if (type.startsWith('Location')) return const {CardRole.location};
  if (type.startsWith('Action')) {
    return type.contains('Song')
        ? const {CardRole.action, CardRole.song}
        : const {CardRole.action};
  }
  return const {};
}
