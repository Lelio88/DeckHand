/// Tests de la lecture du code d'extension parmi le texte d'une carte.
///
/// **Ce qui est mesuré ailleurs, et qui justifie ce fichier.** Le numéro de
/// collection est illisible sur une photo à main levée — sur la fixture réelle
/// `measuredSpread`, il sort « C O0O5 » et « 02 ». Le code d'extension de la
/// même ligne, lui, sort juste : « MSH FR MARC AsPINALL ». Et côté catalogue,
/// le couple (carte, extension) désigne une case unique dans 83,1 % des cas
/// (`api/app/measure/edition_from_set.py`). D'où cette voie : préciser
/// l'édition sans jamais lire le numéro.
///
/// Les cas limites testés ici ne sont pas imaginés : ils viennent tous de la
/// fixture, y compris les fautes de lecture qu'il faut traverser sans broncher.
library;

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/scan/domain/set_code_text.dart';
import 'package:flutter_test/flutter_test.dart';

import 'measured_set_codes.dart';
import 'measured_spread.dart';

void main() {
  group('sur les cartes réellement photographiées', () {
    // Trois cartes scannées une par une, dans le mode où la lecture du code
    // sert. Rejouer la mesure hors ligne évite de reconstruire l'application à
    // chaque changement de règle — et fige ce qui a été obtenu ce jour-là.
    for (final card in measuredSetCodeCards) {
      test('${card.name} : le code est retrouvé', () {
        expect(
          readSetCode(card.lines, measuredCandidates),
          card.expected,
          reason: 'lu sur la carte, donc attendu du code',
        );
      });
    }

    test('aucune ne désigne une extension qu\'elle ne porte pas', () {
      // « MARVEL » et ses lectures fautives (« OMARVEL », « ALARVEL ») sont
      // imprimées sur ces cartes, et `mar` est un code d'extension.
      for (final card in measuredSetCodeCards) {
        expect(
          readSetCode(card.lines, const {'mar'}),
          isNull,
          reason: '${card.name} ne vient pas de MAR',
        );
      }
    });
  });

  group('sur une lecture réelle', () {
    test('le code imprimé est retrouvé parmi les extensions de la carte', () {
      // « MSH FR MARC AsPINALL » — la ligne d'artiste porte le code, en
      // capitales, là où le numéro de la même zone est illisible.
      final found = readSetCode(measuredSpread, const {'msh', 'mkm', 'lci'});

      expect(found, 'msh');
    });

    test('une extension absente de la photo n\'est pas inventée', () {
      final found = readSetCode(measuredSpread, const {'mkm', 'lci'});

      expect(
        found,
        isNull,
        reason:
            'une édition fausse range la carte dans la mauvaise case et '
            'fausse le taux de complétion — pire qu\'une édition absente',
      );
    });
  });

  group('la forme du code', () {
    ReadLine line(String text) => ReadLine(text, 0.96, 0.007);

    test('le code doit être un mot entier', () {
      // « MSHIRE » contient « MSH » sans être un code d'extension.
      expect(readSetCode([line('MSHIRE FR')], const {'msh'}), isNull);
    });

    test('le code collé à sa langue reste lisible', () {
      // Mesuré sur le terrain : sur trois cartes scannées, la ligne
      // « MSH • EN • GRACE ZHU » de Moonstone est sortie « MSHEN GRACE ZH ».
      // La puce séparatrice a disparu, et le code parfaitement lu était perdu.
      expect(readSetCode([line('MSHEN GRACE ZH')], const {'msh'}), 'msh');
    });

    test(
      'un mot qui commence par le code sans langue derrière ne compte pas',
      () {
        // « MARVEL » est imprimé au bas de chaque carte de ces extensions, et
        // `mar` en est une. Accepter un simple préfixe ferait de la mention
        // d'éditeur une désignation d'extension — sur la carte qui l'affiche.
        expect(readSetCode([line('MARVEL')], const {'mar'}), isNull);
        expect(readSetCode([line('OMARVEL')], const {'mar'}), isNull);
      },
    );

    test('les capitales font foi', () {
      // Le code est toujours imprimé en capitales. Sans cette exigence, le mot
      // « one » d'un texte de règles anglais désignerait l'extension ONE.
      expect(
        readSetCode([line('When one creature dies')], const {'one'}),
        isNull,
      );
      expect(readSetCode([line('ONE FR ARTISTE')], const {'one'}), 'one');
    });

    test('un code chiffré est reconnu comme les autres', () {
      expect(readSetCode([line('M21 EN ARTISTE')], const {'m21'}), 'm21');
    });

    test('les séparateurs imprimés ne collent pas au code', () {
      // La ligne réelle porte des puces : « 0412/0853 U • MSH • FR ».
      expect(
        readSetCode([line('0412/0853 U • MSH • FR')], const {'msh'}),
        'msh',
      );
    });

    test('deux extensions lues laissent la carte à préciser', () {
      // Sur un étalement, la ligne d'une carte voisine peut entrer dans le
      // champ. Deviner laquelle est la bonne serait deviner tout court.
      expect(
        readSetCode(
          [line('MSH FR ARTISTE'), line('MKM EN ARTISTE')],
          const {'msh', 'mkm'},
        ),
        isNull,
      );
    });

    test('la même extension lue deux fois reste décidée', () {
      // Le cas de la fixture : le code apparaît sur deux lignes de la même
      // carte. Répéter n'est pas contredire.
      expect(
        readSetCode(
          [line('MSH FR ARTISTE'), line('MSH FR AUTRE')],
          const {'msh'},
        ),
        'msh',
      );
    });

    test('sans candidat, il n\'y a rien à chercher', () {
      expect(readSetCode([line('MSH FR ARTISTE')], const {}), isNull);
    });
  });
}
