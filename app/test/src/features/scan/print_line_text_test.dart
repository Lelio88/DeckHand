// La lecture de la ligne basse, éprouvée sur les lignes réellement rendues par
// ML Kit au banc `integration_test/ligne_basse_test.dart` (issue n°50).
import 'package:deckhand/src/features/scan/domain/print_line_text.dart';
import 'package:flutter_test/flutter_test.dart';

PrintLineCandidate _print(String id, String number, int year) =>
    (id: id, collectorNumber: number, year: year);

void main() {
  group('printLineNumbers', () {
    test('numéro et total d\'une carte ancienne', () {
      expect(
        printLineNumbers('TM &© 1993-2002 Wizards of the Coast, Inc. 125/143'),
        {125},
      );
    });

    test('numéro moderne à zéros de tête', () {
      expect(printLineNumbers('U O075'), {75});
      expect(printLineNumbers('C 0043'), {43});
    });

    test('un O collé à un chiffre est un zéro', () {
      expect(printLineNumbers('CO195'), {195});
    });

    test('force et endurance ne sont pas un numéro', () {
      expect(printLineNumbers('4/4'), isEmpty);
      expect(printLineNumbers('2/1'), isEmpty);
    });

    test('ni l\'année ni un nombre nu ne sont un numéro', () {
      expect(printLineNumbers('M &O2026 Wizards of the Coast'), isEmpty);
      expect(printLineNumbers('© 2025 Marvel 5'), isEmpty);
    });
  });

  test('printLineYears lit les années du copyright', () {
    expect(printLineYears('™ & © 1993-2001 Wizards of the Coast'), {
      1993,
      2001,
    });
    expect(printLineYears('M &O2026 Wizards of the Coast'), {2026});
    expect(printLineYears('C0043'), isEmpty);
  });

  group('bottomBand', () {
    test('le sens qui porte le copyright est le bas du carton', () {
      expect(
        bottomBand({
          0: ['Levée de bouclier'],
          2: ['004', 'MSH FI'],
          3: ['C0043', 'TM&O2026 Wizards of the Coast'],
        }),
        3,
      );
    });

    test('aucun repère ou égalité : on ne devine pas le sens', () {
      expect(
        bottomBand({
          0: ['Levée'],
          2: ['Vol'],
        }),
        isNull,
      );
      expect(
        bottomBand({
          0: ['© Marvel'],
          2: ['Wizards'],
        }),
        isNull,
      );
    });
  });

  group('pickByPrintLine', () {
    final hullBreach = [
      _print('pls', '111', 2001),
      _print('hop', '89', 2009),
      _print('cmd', '203', 2011),
      _print('c13', '193', 2013),
    ];

    test('le numéro lu désigne la seule édition', () {
      expect(
        pickByPrintLine([
          'Illus. Brian Snõddy',
          'TM & © 1993-2001 Wizards of the Coast, Inc. 111/143',
        ], hullBreach),
        'pls',
      );
    });

    test('l\'année départage deux éditions au même numéro', () {
      final sameNumber = [
        _print('inv', '247', 2000),
        _print('m20', '247', 2019),
      ];
      expect(
        pickByPrintLine(['© 1993-2000 Wizards 247/350'], sameNumber),
        'inv',
      );
    });

    test('deux candidates restent : rien', () {
      final twins = [_print('a', '12', 2000), _print('b', '12', 2000)];
      expect(pickByPrintLine(['© 2000 Wizards 12/143'], twins), isNull);
    });

    test('deux numéros lus : rien, comme pour deux codes', () {
      expect(pickByPrintLine(['111/143', 'C 0089'], hullBreach), isNull);
    });

    test('aucun numéro lu : rien, même si l\'année seule suffirait', () {
      expect(pickByPrintLine(['© 2009 Wizards'], hullBreach), isNull);
    });

    test('un numéro qu\'aucune édition ne porte : rien', () {
      expect(pickByPrintLine(['© 2001 Wizards 112/143'], hullBreach), isNull);
    });

    test('l\'année lue contredit le numéro : rien', () {
      expect(pickByPrintLine(['© 2019 Wizards 111/143'], hullBreach), isNull);
    });
  });

  group('pickBySetCode', () {
    // Lignes relevées au banc réel : le numéro y manque, le code y est.
    const ligne = ['MSH FR loHAN GRENIER', 'MARVEL', 'IM&C2026 Wizards'];

    test('le code lu désigne la seule édition de cette extension', () {
      expect(
        pickBySetCode(ligne, const [
          (id: 'msh-348', setCode: 'msh'),
          (id: 'pmsh-348', setCode: 'pmsh'),
          (id: 'mar-12', setCode: 'mar'),
        ]),
        'msh-348',
      );
    });

    test('deux éditions dans l\'extension lue : rien', () {
      expect(
        pickBySetCode(ligne, const [
          (id: 'msh-348', setCode: 'msh'),
          (id: 'msh-412', setCode: 'msh'),
        ]),
        isNull,
      );
    });

    test('« MARVEL » ne désigne pas l\'extension MAR', () {
      expect(
        pickBySetCode(const ['MARVEL'], const [(id: 'mar-12', setCode: 'mar')]),
        isNull,
      );
    });
  });
}
