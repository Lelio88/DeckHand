/// Le filtrage d'étalement, éprouvé sur ce que l'appareil a vraiment lu.
///
/// **Pourquoi ces tests doublent ceux de `spread_names_test.dart`.** Ceux-là
/// travaillent sur des hauteurs choisies à la main, avec un nom deux fois plus
/// grand que ses règles — la carte telle qu'on l'imagine. La réalité mesurée est
/// tout autre, et deux photos successives l'ont montré de deux façons :
///
/// * **cinq cartes à plat** : les noms dépassent la médiane de 21 à 36 %, il
///   existe une séparation nette et un seuil peut s'y glisser ;
/// * **dix-neuf cartes en éventail** : les cartes sont à des distances
///   différentes de l'objectif, le nom d'une carte du fond (1,02) passe sous le
///   texte de règles d'une carte du premier plan (1,26), et **plus aucun seuil
///   ne sépare les deux populations**.
///
/// Le seuil retenu, 1,00, est celui qui perd le moins sur le second cas sans
/// rien coûter sur le premier. Ce n'est pas un réglage confortable : c'est le
/// moins mauvais d'un mécanisme dont la limite est structurelle, et que seule
/// une comparaison **locale** — chaque ligne face aux lignes de sa propre carte
/// — lèverait vraiment.
library;

import 'package:deckhand/src/features/scan/domain/spread_names.dart';
import 'package:flutter_test/flutter_test.dart';

import 'measured_fan.dart';
import 'measured_spread.dart';

Set<String> _cardsAmong(List<String> truth, Iterable<String> candidates) =>
    truth.where(candidates.contains).toSet();

void main() {
  group('cinq cartes à plat', () {
    test('les cinq cartes posées survivent au filtrage', () {
      final names = spreadNameCandidates(measuredSpread).map((c) => c.text);

      expect(_cardsAmong(spreadTruth, names), hasLength(spreadTruth.length));
    });
  });

  group('dix-neuf cartes en éventail', () {
    test('le filtre laisse passer la grande majorité des noms', () {
      final names = spreadNameCandidates(measuredFan).map((c) => c.text).toList();
      final found = _cardsAmong(fanTruth, names);

      // **Dix noms passent tels quels, seize après résolution.** Ce test
      // compare des chaînes brutes ; l'appareil lit « Commnandos kree »,
      // « Agent Maria Hil », « Quake, agent du S.H.LE.L.D. », que seule la
      // recherche tolérante du catalogue sait ramener à la bonne carte. Ce qui
      // se vérifie ici est donc le travail du filtre seul, pas le rappel final,
      // mesuré à 84 % contre 42 % au seuil précédent.
      expect(
        found.length,
        greaterThanOrEqualTo(10),
        reason: 'à 1,15 il n\'en restait que huit : le seuil coupait au milieu '
            'de la population des noms, faute de séparation à exploiter',
      );
    });

    test('un nom du fond ne doit pas être écarté au profit des règles', () {
      // Le cas qui a tout révélé : « Renforts de quartier » (1,02 fois la
      // médiane) est un nom, « devenir les héros de demain » (1,26) est du
      // texte de règles. Tout seuil qui garde le second en écartant le premier
      // se trompe de population.
      final names = spreadNameCandidates(measuredFan).map((c) => c.text);

      expect(names, contains('Renforts de quartier'));
    });

    test('remonter le seuil détruit le rappel', () {
      // Contre-épreuve chiffrée : ce test échouerait si quelqu'un remontait le
      // seuil en pensant gagner en précision.
      final strict = spreadNameCandidates(measuredFan, heightRatio: 1.15)
          .map((c) => c.text);

      expect(
        _cardsAmong(fanTruth, strict).length,
        lessThan(12),
        reason: 'la mesure donne huit cartes sur dix-neuf à 1,15 — le seuil '
            'élevé n\'est pas un réglage prudent, c\'est une perte sèche',
      );
    });
  });

  group('longueur de la correspondance', () {
    test('un fragment de nom est écarté', () {
      // Le cas mesuré : une carte à demi recouverte ne livre que « Origine
      // de », qui est un préfixe exact de « Origine de Thor ». Le score
      // l'approuve à 0,94 ; seule la longueur le démasque.
      expect(isPlausibleMatch('Origine de', 'Origine de Thor'), isFalse);
    });

    test('les correspondances justes passent, même imparfaites', () {
      // Relevé sur trois étalements réels : de 0,94 à 1,12. La lecture ajoute
      // parfois des parasites, d'où un texte lu plus long que le nom trouvé.
      expect(isPlausibleMatch('Agent Maria Hil', 'Agent Maria Hill'), isTrue);
      expect(
        isPlausibleMatch('Quake, agent du S.H.LE.L.D.', 'Quake, agent du S.H.I.E.L.D.'),
        isTrue,
      );
      expect(isPlausibleMatch('( Croisade de Murdock', 'Croisade de Murdock'), isTrue);
    });

    test('un nom vide ne vaut jamais correspondance', () {
      expect(isPlausibleMatch('Foudre', ''), isFalse);
    });
  });
}
