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
  /// Produire du mana ou aller chercher un terrain : dans les deux cas, la
  /// carte sert à accélérer.
  ramp,

  /// Détruire, exiler, ou infliger des blessures à une cible.
  removal,

  /// Piocher des cartes.
  draw,

  creature,

  land,
}

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
Set<CardRole> rolesOf(BuildableCard card) {
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
