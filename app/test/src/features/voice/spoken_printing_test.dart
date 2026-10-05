/// Tests de la résolution d'une édition dictée.
///
/// La règle est celle du garde-fou §IV.8 : une édition n'est retenue que si
/// rien ne reste à choisir. Le reste des cas tient à l'écart entre ce que dit
/// un moteur vocal — ni ponctuation, ni apostrophes, des codes coupés en deux —
/// et ce qu'imprime le catalogue.
library;

import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:deckhand/src/features/voice/domain/spoken_printing.dart';
import 'package:flutter_test/flutter_test.dart';

CardPrinting _print(
  String id,
  String setCode,
  String setName,
  String number, {
  bool nonfoil = true,
  bool foil = true,
}) => CardPrinting(
  printId: id,
  setCode: setCode,
  setName: setName,
  collectorNumber: number,
  lang: 'en',
  hasNonfoil: nonfoil,
  hasFoil: foil,
);

final _m21 = _print('m21-137', 'm21', 'Core Set 2021', '137');
final _m21Vitrine = _print(
  'm21-300',
  'm21',
  'Core Set 2021',
  '300',
  foil: false,
);
final _dom = _print('dom-1', 'dom', 'Dominaria', '1');
final _dmu = _print('dmu-1', 'dmu', 'Dominaria United', '1');
final _dmr = _print('dmr-1', 'dmr', 'Dominaria Remastered', '1');
final _mh2 = _print('mh2-1', 'mh2', 'Modern Horizons 2', '1');
final _mh1 = _print('mh1-1', 'mh1', 'Modern Horizons', '1');
final _stx = _print('stx-1', 'stx', 'Strixhaven: School of Mages', '1');
final _bro = _print('bro-1', 'bro', "The Brothers' War", '1');
final _mid = _print('mid-1', 'mid', 'Innistrad: Midnight Hunt', '1');
final _vow = _print('vow-1', 'vow', 'Innistrad: Crimson Vow', '1');
final _revised = _print('3ed-1', '3ed', 'Revised Edition', '1');
final _usg = _print('usg-1', 'usg', "Urza's Saga", '1');

PrintingResolution _resolve(SpokenPrinting asked, List<CardPrinting> all) =>
    resolveSpokenPrinting(asked, all);

void main() {
  group('une extension désigne', () {
    test('par son code', () {
      final r = _resolve(const SpokenPrinting(set: 'm21'), [_m21, _dom]);
      expect(r, isA<PrintingRetained>());
      expect((r as PrintingRetained).printing.printId, 'm21-137');
    });

    test('par son nom', () {
      final r = _resolve(const SpokenPrinting(set: 'core set 2021'), [
        _m21,
        _dom,
      ]);
      expect((r as PrintingRetained).printing.printId, 'm21-137');
    });

    test('malgré la ponctuation que la voix ne rend pas', () {
      // Le deux-points et l'apostrophe n'existent pas à l'oral.
      final stx = _resolve(
        const SpokenPrinting(set: 'strixhaven school of mages'),
        [_stx, _dom],
      );
      expect((stx as PrintingRetained).printing.printId, 'stx-1');

      final bro = _resolve(const SpokenPrinting(set: 'the brothers war'), [
        _bro,
        _dom,
      ]);
      expect((bro as PrintingRetained).printing.printId, 'bro-1');
    });

    test('par un code que la voix a coupé en deux', () {
      // « MH2 » revient souvent « mh 2 » : un code n'a pas d'espace.
      final r = _resolve(const SpokenPrinting(set: 'mh 2'), [_mh1, _mh2]);
      expect((r as PrintingRetained).printing.printId, 'mh2-1');
    });

    test('le nom exact l\'emporte sur ceux qui le contiennent', () {
      // « Dominaria » est une extension, pas seulement le début de trois.
      final r = _resolve(const SpokenPrinting(set: 'dominaria'), [
        _dom,
        _dmu,
        _dmr,
      ]);
      expect((r as PrintingRetained).printing.printId, 'dom-1');
    });
  });

  group('les mots de liaison ne comptent pas', () {
    // « extension de Dominaria », « édition du set Core Set 2021 » : la
    // tournure française la plus naturelle porte des mots qu'aucun nom
    // d'extension n'a à cet endroit.
    test('devant le nom', () {
      final r = _resolve(const SpokenPrinting(set: 'de dominaria'), [
        _dom,
        _dmu,
      ]);
      expect((r as PrintingRetained).printing.printId, 'dom-1');
    });

    test('dans le nom imprimé', () {
      // « Revised Edition » se dit « revised » ; « Core Set 2021 », « core
      // 2021 ».
      final revised = _resolve(const SpokenPrinting(set: 'revised'), [
        _revised,
        _dom,
      ]);
      expect((revised as PrintingRetained).printing.printId, '3ed-1');

      final core = _resolve(const SpokenPrinting(set: 'core 2021'), [
        _m21,
        _dom,
      ]);
      expect((core as PrintingRetained).printing.printId, 'm21-137');
    });
  });

  group('un nom approché se confirme, même seul', () {
    // Garde-fou §IV.8 : seul un code ou un nom exact désigne. Un nom dont on
    // n'a dit qu'une partie peut être un mot mal entendu qui tombe, par
    // hasard, sur la seule édition qui le contient.
    test('une partie du nom', () {
      final r = _resolve(const SpokenPrinting(set: 'midnight hunt'), [
        _mid,
        _dom,
      ]);
      expect(r, isA<PrintingApproximate>());
      expect((r as PrintingApproximate).candidate.printId, 'mid-1');
    });

    test("le nom d'une autre extension que la carte n'a pas", () {
      // La carte n'existe que dans Dominaria United : « dominaria » ne la
      // désigne pas pour autant.
      final r = _resolve(const SpokenPrinting(set: 'dominaria'), [_dmu]);
      expect(r, isA<PrintingApproximate>());
    });

    test('le début d\'un code', () {
      final r = _resolve(const SpokenPrinting(set: 'mh'), [_mh2, _dom]);
      expect(r, isA<PrintingApproximate>());
    });

    test('un code d\'une lettre ne désigne rien', () {
      final r = _resolve(const SpokenPrinting(set: 'm'), [_m21, _dom]);
      expect(r, isA<PrintingNotFound>());
    });
  });

  group('rien n\'est retenu quand il reste à choisir', () {
    test('un nom partagé par plusieurs extensions', () {
      final r = _resolve(const SpokenPrinting(set: 'innistrad'), [
        _mid,
        _vow,
        _dom,
      ]);
      expect(r, isA<PrintingAmbiguous>());
      expect(
        (r as PrintingAmbiguous).candidates.map((p) => p.printId),
        unorderedEquals(['mid-1', 'vow-1']),
      );
    });

    test('plusieurs éditions dans la même extension', () {
      final r = _resolve(const SpokenPrinting(set: 'm21'), [_m21, _m21Vitrine]);
      expect(r, isA<PrintingAmbiguous>());
    });

    test('le numéro départage', () {
      final r = _resolve(const SpokenPrinting(set: 'm21', number: '300'), [
        _m21,
        _m21Vitrine,
      ]);
      expect((r as PrintingRetained).printing.printId, 'm21-300');
    });

    test('une extension inconnue de la carte', () {
      final r = _resolve(const SpokenPrinting(set: 'xyz'), [_m21, _dom]);
      expect(r, isA<PrintingNotFound>());
    });

    test('un numéro absent de l\'extension', () {
      final r = _resolve(const SpokenPrinting(set: 'm21', number: '999'), [
        _m21,
        _m21Vitrine,
      ]);
      expect(r, isA<PrintingNotFound>());
    });
  });

  group('la finition', () {
    test('demandée et imprimée, elle accompagne l\'édition', () {
      final r = _resolve(const SpokenPrinting(set: 'dom', foil: true), [_dom]);
      expect((r as PrintingRetained).isFoil, isTrue);
    });

    test('demandée et jamais imprimée, l\'édition n\'est pas retenue', () {
      // Lequel des deux mots a été mal entendu ? Rien ne permet de le dire :
      // retenir l'édition sans la finition serait deviner.
      final r = _resolve(
        const SpokenPrinting(set: 'm21', number: '300', foil: true),
        [_m21, _m21Vitrine],
      );
      expect(r, isA<PrintingNotInFoil>());
    });

    test('demandée, elle écarte les éditions jamais imprimées en brillant', () {
      // Une seule édition de l'extension existe en brillant : c'est elle.
      final r = _resolve(const SpokenPrinting(set: 'm21', foil: true), [
        _m21,
        _m21Vitrine,
      ]);
      expect((r as PrintingRetained).printing.printId, 'm21-137');
    });

    test('non dite, elle suit ce que l\'édition imprime', () {
      final seulementBrillante = _print(
        'p-1',
        'p30',
        'Promo',
        '1',
        nonfoil: false,
      );
      final r = _resolve(const SpokenPrinting(set: 'p30'), [
        seulementBrillante,
      ]);
      expect(
        (r as PrintingRetained).isFoil,
        isTrue,
        reason: 'enregistrer sa jumelle normale inventerait un exemplaire',
      );
    });
  });

  group('sans extension dite', () {
    // L'écran passe alors l'édition unique de la carte, quand elle en a une.
    test('l\'édition unique est retenue', () {
      final r = _resolve(SpokenPrinting.none, [_dom]);
      expect((r as PrintingRetained).printing.printId, 'dom-1');
      expect(r.isFoil, isFalse);
    });

    test('la finition dite s\'y applique', () {
      expect(
        _resolve(const SpokenPrinting(foil: true), [_dom]),
        isA<PrintingRetained>().having((r) => r.isFoil, 'isFoil', isTrue),
      );
      expect(
        _resolve(const SpokenPrinting(foil: true), [_m21Vitrine]),
        isA<PrintingNotInFoil>(),
      );
    });
  });

  group('la recherche envoyée au catalogue', () {
    test('commence par le mot le plus long', () {
      // Le catalogue cherche une sous-chaîne du nom imprimé, ponctuation
      // comprise : la phrase entière n'y figure pas, son mot le plus distinctif
      // si.
      expect(
        const SpokenPrinting(set: 'strixhaven school of mages').searchTerms,
        ['strixhaven', 'school'],
      );
    });

    test('se réduit au code quand il n\'y a qu\'un mot', () {
      expect(const SpokenPrinting(set: 'm21').searchTerms, ['m21']);
    });

    test('recolle un code coupé en deux', () {
      expect(const SpokenPrinting(set: 'mh 2').searchTerms, ['mh2', 'mh']);
    });

    test('est vide sans extension', () {
      expect(const SpokenPrinting(foil: true).searchTerms, isEmpty);
    });

    test('ignore les mots de liaison', () {
      expect(const SpokenPrinting(set: 'de m21').searchTerms, ['m21']);
      expect(const SpokenPrinting(set: 'the brothers war').searchTerms, [
        'brothers',
        'war',
      ]);
    });

    test("coupe à l'apostrophe, que le nom imprimé garde", () {
      // « urzas » ne figure pas dans « Urza's Saga » ; « urza », si.
      expect(const SpokenPrinting(set: "urza's saga").searchTerms, [
        'urza',
        'saga',
      ]);
      final r = _resolve(const SpokenPrinting(set: "urza's saga"), [_usg]);
      expect(r, isA<PrintingRetained>());
    });

    test("n'envoie pas un code d'une lettre", () {
      expect(const SpokenPrinting(set: 'm').searchTerms, isEmpty);
    });
  });

  group('deux demandes identiques', () {
    test("le sont malgré l'espace que la voix glisse dans un code", () {
      expect(
        const SpokenPrinting(
          set: 'm21',
        ).sameRequest(const SpokenPrinting(set: 'm 21')),
        isTrue,
      );
    });

    test('ne le sont plus si la finition diffère', () {
      expect(
        const SpokenPrinting(
          set: 'm21',
        ).sameRequest(const SpokenPrinting(set: 'm21', foil: true)),
        isFalse,
      );
    });
  });
}
