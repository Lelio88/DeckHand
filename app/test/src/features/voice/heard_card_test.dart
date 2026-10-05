/// Tests d'une ligne de dictée : ce qu'elle retient de l'édition dite, et ce
/// qu'elle en dit quand elle ne retient rien.
///
/// Ce qui se joue ici et qu'un test d'écran attraperait mal : **l'ordre des
/// réponses**. La recherche d'une édition dite part pendant l'écoute ; on peut
/// couper le micro et choisir au doigt avant qu'elle revienne. Son retour ne
/// doit rien défaire.
library;

import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:deckhand/src/features/printings/presentation/printing_picker.dart';
import 'package:deckhand/src/features/voice/domain/spoken_printing.dart';
import 'package:deckhand/src/features/voice/presentation/heard_card.dart';
import 'package:flutter_test/flutter_test.dart';

const _foudre = CardHit(
  oracleId: 'id-1',
  name: 'Lightning Bolt',
  matchedName: 'Foudre',
  matchedLang: 'fr',
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  score: 1,
);

const _m21 = CardPrinting(
  printId: 'print-m21',
  setCode: 'm21',
  setName: 'Core Set 2021',
  collectorNumber: '137',
  lang: 'fr',
  hasFoil: true,
);

const _dom = CardPrinting(
  printId: 'print-dom',
  setCode: 'dom',
  setName: 'Dominaria',
  collectorNumber: '1',
  lang: 'fr',
);

HeardCard _line(SpokenPrinting asked) =>
    HeardCard(spoken: 'foudre', quantity: 1, match: _foudre, asked: asked);

void main() {
  test("l'édition retenue remplace la note", () {
    final line = _line(const SpokenPrinting(set: 'm21', foil: true))
      ..settle(const PrintingRetained(_m21, isFoil: true));

    expect(line.printing?.printing.printId, 'print-m21');
    expect(line.printing?.isFoil, isTrue);
    expect(line.note, isNull);
  });

  test("ce qui n'est pas retenu est dit avec ce qui a été entendu", () {
    final line = _line(const SpokenPrinting(set: 'm21', number: '300'))
      ..settle(const PrintingNotFound());

    expect(line.printing, isNull);
    expect(line.note, contains('m21 #300'));
  });

  test('plusieurs éditions : la recherche du sélecteur est retenue', () {
    final line = _line(const SpokenPrinting(set: 'dominaria'))
      ..settle(const PrintingAmbiguous([_dom]), pickerQuery: 'dominaria');

    expect(line.pickerQuery, 'dominaria');
    expect(line.note, contains('plusieurs éditions'));
  });

  test("un nom approché nomme l'extension trouvée, à confirmer", () {
    final line = _line(const SpokenPrinting(set: 'dominar'))
      ..settle(const PrintingApproximate(_dom), pickerQuery: 'dom');

    expect(line.printing, isNull, reason: 'garde-fou §IV.8 : rien sans geste');
    expect(line.note, contains('Dominaria'));
    expect(line.pickerQuery, 'dom');
  });

  test('une réponse sans recherche ne retire pas celle du sélecteur', () {
    // Le remplissage des éditions uniques repasse sur la ligne sans connaître
    // la recherche qui a ramené ses candidates.
    final line = _line(const SpokenPrinting(set: 'm21', foil: true))
      ..settle(const PrintingNotInFoil(), pickerQuery: 'm21')
      ..settle(const PrintingNotInFoil());

    expect(line.pickerQuery, 'm21');
  });

  test("la brillante dite sans édition prévient d'emblée", () {
    final line = _line(const SpokenPrinting(foil: true));
    expect(line.note, startsWith('Brillante'));
  });

  test('un choix au doigt efface la note', () {
    final line = _line(const SpokenPrinting(set: 'xyz'))
      ..settle(const PrintingNotFound())
      ..choose(const PrintingChoice(_dom));

    expect(line.printing?.printing.printId, 'print-dom');
    expect(line.note, isNull);
  });

  test("une réponse tardive du catalogue ne défait pas un choix au doigt", () {
    // La recherche de « m21 » est partie pendant l'écoute ; on a coupé et
    // choisi Dominaria avant qu'elle revienne.
    final line = _line(const SpokenPrinting(set: 'm21'))
      ..choose(const PrintingChoice(_dom))
      ..settle(const PrintingRetained(_m21, isFoil: false));

    expect(line.printing?.printing.printId, 'print-dom');
  });

  test('« ne pas préciser » survit aussi à une réponse tardive', () {
    final line = _line(const SpokenPrinting(set: 'm21'))
      ..choose(null)
      ..settle(const PrintingRetained(_m21, isFoil: false));

    expect(line.printing, isNull);
  });
}
