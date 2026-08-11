/// Tests du choix du nom parmi les textes lus sur une carte.
///
/// La reconnaissance de texte rend tout ce qu'elle voit — nom, type, règles,
/// illustrateur, copyright, numéro. Se tromper de ligne envoie une recherche sur
/// « Rituel » ou « © 2026 Wizards », qui ne ressemblent à aucune carte : le scan
/// échoue alors sans que rien n'indique pourquoi.
library;

import 'dart:math';

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reproduit la disposition d'une carte réelle, telle que lue de haut en bas.
List<ReadLine> cardLayout({String name = 'Cherchauloin'}) => [
  ReadLine(name, 0.05, 0.04),
  ReadLine('1', 0.05, 0.03), // coût en mana, sur la même ligne que le nom
  ReadLine('Rituel', 0.58, 0.03),
  ReadLine('Cherchez dans votre bibliothèque une carte de plaine…', 0.64, 0.09),
  ReadLine('RIMAS VALEIKIS', 0.93, 0.02),
  ReadLine('© 2026 Wizards of the Coast', 0.96, 0.02),
];

void main() {
  test('le nom est pris en haut de la carte', () {
    final names = cardNameCandidates(cardLayout());

    expect(names.first, 'Cherchauloin');
  });

  test('le texte de règles n\'est jamais proposé', () {
    final names = cardNameCandidates(cardLayout());

    expect(
      names.any((n) => n.contains('bibliothèque')),
      isFalse,
      reason: 'chercher le texte de règles ne peut rien donner',
    );
  });

  test('le copyright et l\'illustrateur sont écartés', () {
    final names = cardNameCandidates(cardLayout());

    expect(names.any((n) => n.contains('Wizards')), isFalse);
    expect(names.any((n) => n.contains('VALEIKIS')), isFalse);
  });

  test('le coût en mana ne passe pas pour un nom', () {
    final names = cardNameCandidates(cardLayout());

    expect(names, isNot(contains('1')));
  });

  test('la force et l\'endurance sont écartées', () {
    final names = cardNameCandidates([
      ReadLine('Big Wheel', 0.04, 0.04),
      ReadLine('4/4', 0.09, 0.03),
    ]);

    expect(names, ['Big Wheel']);
  });

  test('le numéro de collection est écarté', () {
    final names = cardNameCandidates([
      ReadLine('C 0679', 0.03, 0.02),
      ReadLine('MSC★FR', 0.06, 0.02),
      ReadLine('Big Wheel', 0.08, 0.04),
    ]);

    expect(
      names.first,
      'Big Wheel',
      reason: 'le bloc d\'identification en marge précède parfois le nom',
    );
  });

  test(
    'plusieurs candidats sont proposés, pour rattraper une mauvaise lecture',
    () {
      final names = cardNameCandidates([
        ReadLine('Cherchaulom', 0.05, 0.04), // « in » lu « m »
        ReadLine('Cherchauloin', 0.12, 0.04),
      ]);

      expect(names.length, greaterThan(1));
    },
  );

  test('une ligne trop courte est ignorée', () {
    final names = cardNameCandidates([
      ReadLine('X', 0.03, 0.02),
      ReadLine('Foudre', 0.06, 0.04),
    ]);

    expect(names, ['Foudre']);
  });

  test('les doublons de lecture ne sont pas répétés', () {
    final names = cardNameCandidates([
      ReadLine('Foudre', 0.04, 0.04),
      ReadLine('foudre', 0.09, 0.04),
    ]);

    expect(names.length, 1);
  });

  test('une carte sans texte lisible ne propose rien', () {
    expect(cardNameCandidates(const []), isEmpty);
  });

  test('la zone du nom tolère de la table au-dessus de la carte', () {
    // Photo cadrée large : tout est décalé vers le bas.
    final names = cardNameCandidates([
      ReadLine('Foudre', 0.22, 0.04),
      ReadLine('Éphémère', 0.60, 0.03),
    ]);

    expect(
      names.first,
      'Foudre',
      reason:
          'un cadrage approximatif ne doit pas faire manquer le nom — '
          'c\'est précisément ce que la lecture du texte doit rattraper',
    );
  });

  group("la hauteur d'une ligne se mesure sur ses coins", () {
    // Une ligne inclinee de 10 degres, comme toute carte posee a la main.
    // Les coins tournent avec le texte ; la boite englobante, elle, reste
    // droite et gonfle avec la longueur de la ligne.
    List<Point<int>> tilted({required int length, required int height}) {
      const cos = 0.9848, sin = 0.1736;
      Point<int> at(double x, double y) => Point(x.round(), y.round());
      final topRight = at(length * cos, length * sin);
      return [
        const Point(0, 0),
        topRight,
        at(topRight.x - height * sin, topRight.y + height * cos),
        at(-height * sin, height * cos),
      ];
    }

    test('une ligne longue et fine ne passe pas pour du gros texte', () {
      // Boite englobante : 45 pixels de haut. Caracteres : 10.
      expect(
        textHeightFromCorners(tilted(length: 200, height: 10), 45),
        closeTo(10, 1),
      );
    });

    test('un nom court en gros caracteres garde sa taille', () {
      // Boite englobante : 36 pixels, soit MOINS que la ligne de regles
      // ci-dessus alors que ses caracteres sont deux fois plus grands.
      expect(
        textHeightFromCorners(tilted(length: 80, height: 22), 36),
        closeTo(22, 1),
      );
    });

    test('le nom ressort au-dessus du texte de regles, mesure ainsi', () {
      // La regression mesuree sur le terrain : avec la hauteur de boite, la
      // ligne de regles (45) depassait le nom (36) et le filtre gardait la
      // mauvaise. Le rapport doit s'inverser.
      final rules = textHeightFromCorners(tilted(length: 200, height: 10), 45);
      final name = textHeightFromCorners(tilted(length: 80, height: 22), 36);

      expect(name, greaterThan(rules));
    });

    test('sans les quatre coins, on retombe sur la boite', () {
      expect(textHeightFromCorners(const [Point(0, 0)], 17), 17);
    });
  });

  group('les parasites de bordure sont retirés', () {
    test("un crochet en tête ne met plus une ligne de type à l'abri", () {
      // Mesuré : « [Ephémere » a produit une carte fantôme parce que le filtre
      // des lignes de type s'ancre en début de ligne, et que le crochet l'en
      // protégeait.
      expect(looksLikeCardName(cleanNameLine('[Ephémere')), isFalse);
      // La forme anglaise place le type en second : sans « legendary » dans le
      // motif, « Legendary Creature — Kree Soldier » passait pour un nom.
      expect(
        looksLikeCardName(cleanNameLine('(Legendary Creature Kree Soldier')),
        isFalse,
      );
    });

    test('un vrai nom parasité reste reconnaissable', () {
      expect(
        cleanNameLine('(Captain Mar-Vell, Space-Born'),
        'Captain Mar-Vell, Space-Born',
      );
      expect(cleanNameLine('( Croisade de Murdock'), 'Croisade de Murdock');
    });

    test("une parenthèse au milieu d'un nom est préservée", () {
      // Rien ne dit qu'aucune carte n'en porte ; on ne retire qu'aux extrémités.
      expect(cleanNameLine('Nom (variante) suite'), 'Nom (variante) suite');
    });
  });

  group('les lignes de capacités ne sont pas des noms', () {
    test('deux mots-clés sur une ligne la disqualifient', () {
      // Le dernier faux positif mesuré : « Vol, vigilance » trouvait la carte
      // *Vigilance*, qui existe. Ni le score, ni la longueur, ni le filtre des
      // lignes de type ne pouvaient s'en apercevoir.
      expect(looksLikeCardName('Vol, vigilance'), isFalse);
      expect(looksLikeCardName('Flying, trample'), isFalse);
      expect(looksLikeCardName('Vigilance, lien de vie'), isFalse);
    });

    test('un seul mot-clé reste un nom possible', () {
      // **Cinq cartes s'appellent exactement comme un mot-clé** — Flight
      // (« Vol »), Lifelink, Persist, Threaten (« Menace ») et Vigilance. Les
      // écarter les rendrait invisibles au scan d'étalement, alors qu'aucun des
      // 62 959 noms du catalogue ne contient deux mots-clés.
      expect(looksLikeCardName('Vigilance'), isTrue);
      expect(looksLikeCardName('Lien de vie'), isTrue);
      expect(looksLikeCardName('Menace'), isTrue);
    });

    test('un mot-clé enchâssé dans un autre mot ne compte pas', () {
      // « portée » ne doit pas se déclencher sur « Emportée », ni « vol » sur
      // « Volcan » : sans quoi des noms parfaitement légitimes tomberaient.
      expect(listsKeywords('Emportée par le Volcan'), isFalse);
      expect(listsKeywords('Volcan, Emportée'), isFalse);
    });
  });

  group("le texte d'ambiance signe son auteur", () {
    test("une attribution ouverte par un tiret n'est pas un nom", () {
      // **Observé sur le terrain.** En bas d'une carte, un personnage parle, et
      // son nom est exactement celui d'une carte existante. Le score vaut donc
      // 1,00 et aucune règle de longueur ne peut s'en apercevoir : sur deux
      // photos, cette seule cause a fabriqué trois cartes fantômes.
      expect(looksLikeCardName('-Ka-Zar of the Savage Land'), isFalse);
      expect(looksLikeCardName('—Ka-Zar of the Savage Land'), isFalse);
      expect(looksLikeCardName('–Hank Pym, fondateur'), isFalse);
    });

    test('le tiret compte quelle que soit sa forme', () {
      // La reconnaissance rend le trait d'union, le demi-cadratin ou le
      // cadratin selon la police et la netteté ; les trois signent la même
      // chose.
      for (final dash in ['-', '‐', '‒', '–', '—', '―', '−']) {
        expect(
          isFlavourAttribution('${dash}Ka-Zar'),
          isTrue,
          reason: 'le tiret « $dash » ouvre aussi une attribution',
        );
      }
    });

    test("un tiret à l'intérieur du nom ne change rien", () {
      // *Ka-Zar* et *Mar-Vell* portent un trait d'union : seul celui de tête
      // signale une attribution.
      expect(looksLikeCardName('Ka-Zar de la Terre sauvage'), isTrue);
      expect(looksLikeCardName('Captain Mar-Vell, Space-Born'), isTrue);
    });
  });

  group('un nom de carte est capitalisé', () {
    test('une ligne commençant par une minuscule est écartée', () {
      // « down. » et « of turn. », arrachées à un texte de règles anglais,
      // trouvaient les cartes *Down* et *Turn* — qui existent — avec un score
      // parfait. Ni la longueur ni le score ne les distinguent.
      expect(looksLikeCardName('down.'), isFalse);
      expect(looksLikeCardName('of turn.'), isFalse);
      expect(looksLikeCardName('vous contrôlez'), isFalse);
    });

    test('la première lettre décide, pas le premier caractère', () {
      // Un nom peut s'ouvrir sur un chiffre ou une ponctuation ; c'est la
      // première lettre qui porte la casse.
      expect(startsLowercase('13, Sharon Carter'), isFalse);
      expect(startsLowercase('« Agent »'), isFalse);
      expect(startsLowercase('3 chiens'), isTrue);
    });

    test('une ligne sans lettre du tout ne tombe pas sur cette règle', () {
      // Elle sera écartée ailleurs — par le motif de bruit — mais pas ici :
      // une règle doit rejeter pour la raison qu'elle annonce.
      expect(startsLowercase('123 456'), isFalse);
      expect(startsLowercase(''), isFalse);
    });

    test('les vrais noms mesurés passent tous', () {
      // Contre-épreuve : sur trois photos et trente-deux cartes réelles,
      // aucune n'a été lue en commençant par une minuscule. Ces lectures-là
      // sont abîmées, et doivent malgré tout passer.
      for (final name in [
        'Alennifer Walters',
        'Agents du S.H.LE.LD.',
        'Héroine en forrmation',
        'Dinosaure de la Terre sauyage 4',
        'Oiseau Moqueur, agente de talent 3',
      ]) {
        expect(
          looksLikeCardName(name),
          isTrue,
          reason: '« $name » est un nom lu',
        );
      }
    });
  });
}
