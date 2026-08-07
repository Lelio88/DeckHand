/// Lignes réellement lues sur une photo d'étalement, par l'appareil.
///
/// **Ce ne sont pas des données inventées.** Cinq cartes Marvel étalées sur une
/// table, photographiées à main levée, lues par ML Kit sur l'appareil : chaque
/// ligne porte le texte reconnu et la hauteur de ses caractères, mesurée sur le
/// quadrilatère incliné. Les fautes de lecture sont conservées telles quelles
/// — « Créatwo », « MSH FR MARC AsPINALL » — parce que c'est précisément ce à
/// quoi le filtrage doit résister.
///
/// Cette fixture existe parce que le réglage du seuil de taille s'est révélé
/// beaucoup plus serré qu'on ne le pensait : le plateau où les cinq cartes
/// sortent sans fausse ne va que de 1,10 à 1,20. Un test sur des hauteurs
/// inventées ne l'aurait jamais montré.
library;

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';

/// Les cinq cartes effectivement posées sur la table.
const spreadTruth = [
  "Agent d'Atlas",
  'Agent 13, Sharon Carter',
  'Agent Phil Coulson',
  'Agents du S.H.I.E.L.D.',
  'Agent Maria Hill',
];

/// Les 36 lignes lues, dans l'ordre de haut en bas.
final measuredSpread = <ReadLine>[
  ReadLine("Agent 13, Sharon Carter", 0.2533, 0.0160),
  ReadLine("Agent Maria Hill", 0.2691, 0.0159),
  ReadLine("Agent d'Atlas", 0.2697, 0.0179),
  ReadLine("Créature légendaire : humain et es", 0.4951, 0.0105),
  ReadLine("Créa", 0.4978, 0.0129),
  ReadLine("Créatwo", 0.5098, 0.0104),
  ReadLine("créatu", 0.5219, 0.0105),
  ReadLine("Agents du S.H.I.E.L.D.", 0.5372, 0.0170),
  ReadLine("A", 0.5421, 0.0104),
  ReadLine("der", 0.5585, 0.0109),
  ReadLine("Agent Phil Coulson", 0.5711, 0.0164),
  ReadLine("02", 0.6783, 0.0060),
  ReadLine("ER", 0.6871, 0.0049),
  ReadLine("Créature : humain et espion et héros", 0.7867, 0.0148),
  ReadLine("Créature légendaire : humain et espion et héros", 0.8042, 0.0115),
  ReadLine("A chaque fois qu'une créature que vous", 0.8184, 0.0159),
  ReadLine("contrôlez attaque seule, cette crèature", 0.8348, 0.0148),
  ReadLine("gagne +1/+1 jusqu'à la fin du tour.", 0.8512, 0.0137),
  ReadLine("Vigilance", 0.8594, 0.0142),
  ReadLine("e:Mettez un marqueur +1/+1 sur", 0.8660, 0.0126),
  ReadLine("chaque autre héros que vous contrôlez.", 0.8791, 0.0126),
  ReadLine("Derrière chaque mission solo du", 0.8802, 0.0148),
  ReadLine("S.H.IE. L. D., ily a des dizaines d'agents", 0.8944, 0.0164),
  ReadLine("« La grosse artillerie est en route. Agent 13,", 0.9075, 0.0131),
  ReadLine("de renseignement, de coordinateurs", 0.9108, 0.0153),
  ReadLine("quelle est la situation de votre coté ?»", 0.9245, 0.0131),
  ReadLine("logistique et de renforts.", 0.9261, 0.0153),
  ReadLine("2/4", 0.9409, 0.0142),
  ReadLine("C O0O5", 0.9519, 0.0066),
  ReadLine("2/2", 0.9530, 0.0137),
  ReadLine("MARVEL", 0.9562, 0.0060),
  ReadLine("MSH FR ßoA PNDADO", 0.9601, 0.0077),
  ReadLine("IMN3026 \\Wards of he Coast", 0.9623, 0.0077),
  ReadLine("MARVEI", 0.9721, 0.0071),
  ReadLine("M&2026 Wzasds sd thy Caass", 0.9726, 0.0077),
  ReadLine("MSH FR MARC AsPINALL", 0.9852, 0.0071),
];
