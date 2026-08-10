/// Les lignes réellement lues sur trois cartes photographiées une par une.
///
/// **Pourquoi figer ces trois-là.** Le seul enregistrement dont on disposait
/// venait d'une photo d'étalement, où les cartes sont vues de loin ; ces
/// trois-ci viennent du mode « Scanner une carte », c'est-à-dire des conditions
/// réelles de la lecture du code d'extension. Elles ont été capturées par le
/// journal de mesure (`--dart-define=DECKHAND_DIAG=true`, relevé par
/// `adb logcat`), et le verdict de chacune est celui que l'application a
/// réellement rendu ce jour-là.
///
/// **Ce qu'elles ont montré.** Deux codes lus sur trois. L'échec n'était ni un
/// défaut de netteté ni un mauvais cadrage : sur Moonstone, la reconnaissance a
/// rendu `MSHEN` d'un seul tenant, la puce séparant le code de la langue ayant
/// disparu. Le code était parfaitement lisible et pourtant perdu. C'est ce cas
/// qui a motivé la décomposition `code + langue`.
///
/// Les fautes de lecture sont conservées telles quelles — « OMARVEL »,
/// « ALARVEL », « IM& O2026 Wizards of the Cast » — parce que c'est ce à quoi
/// la règle doit résister. « MARVEL » compte double : le mot est imprimé au bas
/// de ces cartes, et `mar` est un code d'extension du catalogue.
library;

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';

/// Une carte photographiée, et ce que l'appareil en a lu.
class MeasuredCard {
  const MeasuredCard(this.name, this.expected, this.lines);

  /// Nom de la carte, pour situer l'échec quand un test tombe.
  final String name;

  /// Code d'extension imprimé sur la carte, vérifié à la main.
  final String expected;

  final List<ReadLine> lines;
}

/// Extension de ces trois cartes, telle que le catalogue l'écrit.
const measuredCandidates = {'msh'};

final measuredSetCodeCards = <MeasuredCard>[
  MeasuredCard('Klaw, Sonic Subjugator', 'msh', [
    ReadLine('Klaw, Sonic Subjugator', 0.195, 0.0316),
    ReadLine('Legendary Creature Human Rogue Villain M', 0.634, 0.0253),
    ReadLine('Sonic Attack When Klaw enters, target', 0.689, 0.0246),
    ReadLine('player reveals a number of cards from', 0.714, 0.0240),
    ReadLine('their hand equal to one plus the number', 0.742, 0.0259),
    ReadLine('of creature cards in your graveyard. You', 0.771, 0.0259),
    ReadLine('choose one of them. That player discards', 0.799, 0.0253),
    ReadLine('that card,', 0.834, 0.0227),
    ReadLine('2', 0.196, 0.0285),
    ReadLine('Listen to the sound of death. Hear the sound', 0.879, 0.0278),
    ReadLine('of your own cells exploding"', 0.913, 0.0291),
    ReadLine('U0103', 0.969, 0.0120),
    ReadLine('MSH EN ANDREIA UGRAI', 0.979, 0.0158),
    ReadLine('OMARVEL', 0.959, 0.0120),
    ReadLine('2/2', 0.925, 0.0316),
    ReadLine('IM& O2026 Wizards of the Cast', 0.970, 0.0145),
  ]),

  // Le cas qui a fait changer la règle : « MSH EN » collé en « MSHEN ».
  MeasuredCard('Moonstone, Harsh Mistress', 'msh', [
    ReadLine('Moonstone, Harsh Mistress', 0.181, 0.0291),
    ReadLine('Legendary Creature Human Doctor Villain M', 0.632, 0.0245),
    ReadLine('Flying', 0.699, 0.0291),
    ReadLine('Whenever you discard a card, you may', 0.729, 0.0274),
    ReadLine('exile that card from your graveyard. If', 0.760, 0.0280),
    ReadLine('you do, until the end of your next turn,', 0.791, 0.0262),
    ReadLine('you may play that card.', 0.822, 0.0280),
    ReadLine('"Let me show you the dark side of the', 0.878, 0.0280),
    ReadLine('moon.', 0.925, 0.0204),
    ReadLine('UO107', 0.970, 0.0111),
    ReadLine('34', 0.181, 0.0291),
    ReadLine('39', 0.920, 0.0105),
    ReadLine('MSHEN GRACE ZH', 0.983, 0.0151),
    ReadLine('ALARVEL', 0.962, 0.0111),
    ReadLine('2/4', 0.926, 0.0303),
    ReadLine('2026 Wns he Cast', 0.970, 0.0140),
  ]),

  MeasuredCard('Red Room Recruit', 'msh', [
    ReadLine('Red Room Recruit', 0.205, 0.0312),
    ReadLine('Creature- Human Spy Villain', 0.639, 0.0277),
    ReadLine('When this creature enters, it', 0.702, 0.0231),
    ReadLine('connives. (Draw a card, then discard a', 0.731, 0.0277),
    ReadLine('card. If you discarded a nonland card, put a', 0.759, 0.0271),
    ReadLine('+1/+1 counter on this creature.)', 0.789, 0.0237),
    ReadLine("The Red Room doesn't grade on a curve.", 0.843, 0.0277),
    ReadLine('Only the deadliest make it out."', 0.874, 0.0266),
    ReadLine('-Black Widoy, Natasha Romanoff', 0.902, 0.0289),
    ReadLine('CO110', 0.962, 0.0116),
    ReadLine('M', 0.652, 0.0214),
    ReadLine('MSH EN BoRIA PINDADO', 0.977, 0.0150),
    ReadLine('1/2', 0.940, 0.0271),
    ReadLine('MARVEL', 0.969, 0.0144),
    ReadLine('IM&C2026 Wzards of the Coast', 0.986, 0.0144),
  ]),
];
