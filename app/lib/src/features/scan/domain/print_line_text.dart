/// L'édition lue sur la **ligne basse** d'une carte : année du copyright et
/// numéro de collection.
///
/// **Pourquoi cette lecture (issue n°50).** Avant M15 (2014), aucune carte
/// n'imprime son code d'extension — [readSetCode] n'y peut rien. Le carton
/// porte encore l'année du copyright (« ©1993-2001 ») et, depuis Exodus,
/// « numéro/total » (« 111/143 »). Mesuré au catalogue
/// (`api/app/measure/edition_from_print_line.py`) : lus sans faute, année et
/// numéro départagent environ six éditions sur dix d'avant M15.
///
/// **Ce qui la rend lisible : la bande découpée, pas la photo entière.** Lue
/// sur la photo, la ligne basse ne sortait presque jamais. Les 10 % du bas du
/// carton, redressés et donnés seuls à ML Kit, donnent le bon numéro sur
/// 24 photos de carte seule sur 44, **sans aucune lecture fausse**, à 1600 px
/// comme en pleine résolution (`integration_test/ligne_basse_test.dart`).
///
/// **Les règles viennent de la mesure, chacune pour un piège rencontré** :
///
/// * la force et l'endurance (« 4/4 ») sont imprimées dans la même bande, sous
///   la même forme « n/total » — un total de moins de vingt n'en est pas un ;
/// * ML Kit rend souvent « C 0195 » en « CO195 » — un O collé à un chiffre est
///   un zéro ;
/// * deux numéros lus, on ne tranche pas, comme [readSetCode] devant deux
///   codes : **une édition fausse est pire qu'une édition absente** ;
/// * l'année du copyright n'est pas toujours celle de la sortie — une extension
///   de janvier porte souvent l'année d'avant : un an d'écart est admis.
///
/// Logique séparée du lecteur de texte, comme `set_code_text.dart` : elle
/// s'éprouve sur des lignes figées, sans appareil ni service natif.
///
/// ```dart
/// final id = pickByPrintLine(bandLines, [
///   for (final p in printings)
///     (id: p.printId, collectorNumber: p.collectorNumber, year: p.releasedAt?.year),
/// ]);
/// ```
library;

import 'art_box.dart';

/// La bande lue, en proportions du carton debout : les 10 % du bas, là où
/// vivent copyright, numéro et total. Celle que le banc a mesurée.
const ArtBox printLineBand = (left: 0.0, top: 0.90, right: 1.0, bottom: 1.0);

/// Une édition candidate, réduite à ce que la ligne basse peut confirmer.
typedef PrintLineCandidate = ({String id, String? collectorNumber, int? year});

final _withTotal = RegExp(r'(?<!\d)(\d{1,4})\s*/\s*(\d{1,4})(?!\d)');
final _zeroPadded = RegExp(r'(?<!\d)0(\d{2,3})(?!\d)');
final _year = RegExp(r'(?<!\d)(19[89]\d|20[0-3]\d)(?!\d)');
final _oAsZero = RegExp(r'(?<=\d)[Oo]|[Oo](?=\d)');

/// Ce qui ne s'imprime qu'au bas du carton : copyright, illustrateur, éditeur.
final _bottomMark = RegExp(
  r'wizard|illus|©|marvel|inc\.',
  caseSensitive: false,
);

/// Sous ce total, un « n/total » est la force et l'endurance : aucune extension
/// numérotée sur ce modèle n'a moins de vingt cartes, aucune créature imprimée
/// n'a vingt d'endurance.
const _minTotal = 20;

/// Un an d'écart admis entre l'année du copyright et la sortie de l'extension.
const _yearTolerance = 1;

/// Les numéros de collection lisibles **comme tels** dans une ligne : sous la
/// forme « 247/350 » ou à zéros de tête (« 0348 »). Un nombre nu ne compte pas.
Set<int> printLineNumbers(String text) {
  final clean = text.replaceAll(_oAsZero, '0');
  return {
    for (final m in _withTotal.allMatches(clean))
      if (int.parse(m.group(2)!) >= _minTotal &&
          int.parse(m.group(1)!) <= int.parse(m.group(2)!))
        int.parse(m.group(1)!),
    for (final m in _zeroPadded.allMatches(clean)) int.parse(m.group(1)!),
  };
}

/// Les années lues dans une ligne (« 1993-2001 » en donne deux).
Set<int> printLineYears(String text) => {
  for (final m in _year.allMatches(text)) int.parse(m.group(1)!),
};

/// Le quart de tour dont la bande lue est bien le bas du carton, ou `null`.
///
/// La carte peut être couchée ou à l'envers sur la photo, et une bande lue
/// dans le mauvais sens rend le bord du carton, où « 0043 » sort en « 004 ».
/// Seul le sens qui porte une marque de bas de carte (copyright, illustrateur)
/// est retenu ; aucune marque, ou deux sens à égalité, et l'on ne devine pas.
int? bottomBand(Map<int, List<String>> linesByTurn) {
  int? best;
  var bestMarks = 0;
  var tie = false;
  for (final MapEntry(key: turn, value: lines) in linesByTurn.entries) {
    final marks = lines.where(_bottomMark.hasMatch).length;
    if (marks > bestMarks) {
      best = turn;
      bestMarks = marks;
      tie = false;
    } else if (marks == bestMarks && marks > 0) {
      tie = true;
    }
  }
  return tie ? null : best;
}

/// L'édition que la ligne basse désigne seule parmi [candidates], ou `null`.
///
/// Il faut **un seul** numéro lu ; l'année, si elle est lue, doit s'accorder à
/// un an près. Aucun numéro, deux numéros, aucune candidate ou plusieurs :
/// `null`, et la carte reste « édition non précisée », l'état de plein droit.
String? pickByPrintLine(
  List<String> bandLines,
  List<PrintLineCandidate> candidates,
) {
  final numbers = {for (final line in bandLines) ...printLineNumbers(line)};
  if (numbers.length != 1) return null;
  final number = numbers.single;
  final years = {for (final line in bandLines) ...printLineYears(line)};

  final left = [
    for (final c in candidates)
      if (int.tryParse(c.collectorNumber ?? '') == number &&
          (years.isEmpty ||
              (c.year != null &&
                  years.any((y) => (y - c.year!).abs() <= _yearTolerance))))
        c.id,
  ];
  return left.length == 1 ? left.single : null;
}
