/// Tests du repérage de plusieurs cartes sur une photo.
///
/// L'approche par découpage d'image plafonnait à 57 % de rappel. Celle-ci lit
/// les noms : la difficulté n'est plus de séparer les cartes, mais de distinguer
/// un nom du reste de ce qui traîne sur une photo d'étalement — types, règles,
/// et surtout les cartes partiellement masquées par leurs voisines.
library;

import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/scan/domain/spread_names.dart';
import 'package:flutter_test/flutter_test.dart';

/// Trois cartes étalées, chacune avec son nom, son type et ses règles.
List<ReadLine> spreadOfThree() => [
  ReadLine('Foudre', 0.08, 0.03),
  ReadLine('Éphémère', 0.14, 0.02),
  ReadLine('Foudre inflige 3 blessures à n\'importe quelle cible.', 0.18, 0.04),
  ReadLine('Anneau solaire', 0.38, 0.03),
  ReadLine('Artefact', 0.44, 0.02),
  ReadLine('C 0679', 0.47, 0.02),
  ReadLine('Cherchauloin', 0.68, 0.03),
  ReadLine('Rituel', 0.74, 0.02),
  ReadLine('© 2026 Wizards of the Coast', 0.96, 0.02),
];

void main() {
  test('chaque carte de l\'étalement donne un candidat', () {
    final names = spreadNameCandidates(spreadOfThree()).map((c) => c.text);

    expect(names, containsAll(['Foudre', 'Anneau solaire', 'Cherchauloin']));
  });

  test('les lignes de type ne deviennent pas des cartes', () {
    final names = spreadNameCandidates(spreadOfThree()).map((c) => c.text);

    expect(names, isNot(contains('Éphémère')));
    expect(names, isNot(contains('Artefact')));
    expect(names, isNot(contains('Rituel')));
  });

  test('le texte de règles est écarté', () {
    final names = spreadNameCandidates(spreadOfThree()).map((c) => c.text);

    expect(names.any((n) => n.contains('blessures')), isFalse);
  });

  test('les candidats suivent l\'ordre de lecture', () {
    final tops = spreadNameCandidates(spreadOfThree()).map((c) => c.top);

    expect(
      tops.toList(),
      orderedEquals(tops.toList()..sort()),
      reason: 'l\'utilisateur relit son étalement de haut en bas ; '
          'proposer les cartes dans le désordre l\'obligerait à chercher',
    );
  });

  test('aucune zone n\'est privilégiée, contrairement au scan d\'une carte', () {
    // Sur un étalement, les noms sont répartis dans toute la hauteur — y compris
    // tout en bas, là où le scan d'une carte unique ne regarde jamais.
    final names = spreadNameCandidates([
      ReadLine('Anneau solaire', 0.88, 0.03),
    ]).map((c) => c.text);

    expect(names, ['Anneau solaire']);
  });

  test('une même carte lue deux fois au même endroit ne compte qu\'une fois', () {
    // **Ce test disait autre chose, et c'était le défaut.** Il fusionnait deux
    // lectures identiques *quelle que soit leur position*, ce qui faisait
    // disparaître les exemplaires multiples — quatre dinosaures n'en donnaient
    // qu'un. Seule la proximité justifie la fusion : à cet écart-là, c'est la
    // même carte relue.
    //
    // Il passait d'ailleurs pour une raison qui n'était plus la sienne : la
    // seconde ligne « foudre » est désormais écartée pour sa minuscule, avant
    // même que la question de la fusion se pose.
    final names = spreadNameCandidates(const [
      ReadLine('Foudre', 0.100, 0.03, 0.10, 0.20),
      ReadLine('Foudre', 0.105, 0.03, 0.10, 0.20),
    ]);

    expect(names.length, 1);
  });

  test('le nombre de candidats est plafonné', () {
    // Un nom pour quatre lignes de règles, proportion d'une carte réelle :
    // c'est ce qui fait tomber la médiane sur le corps de texte.
    final many = [
      for (var i = 0; i < 900; i++)
        ReadLine('Carte numéro $i', i / 900, i % 5 == 0 ? 0.03 : 0.01),
    ];

    expect(spreadNameCandidates(many).length, maxSpreadCandidates);
  });

  test('le plafond encaisse une photo de cartes entières', () {
    // **Le plafond a été le vrai goulot pendant tout le développement.** Une
    // photo de dix-sept cartes entières produit 141 lignes lues, dont 85
    // passent le filtre : à 40, les quarante-cinq dernières n'étaient jamais
    // cherchées, et les cartes du bas restaient invisibles. Le relevé mesuré
    // fait passer le rappel de 47 % à 65 % à seuil constant.
    expect(
      maxSpreadCandidates,
      greaterThanOrEqualTo(85),
      reason: "sous ce seuil, une photo de dix-sept cartes perd des rangées "
          "entières — et le symptôme est trompeur : relâcher le filtre de "
          "taille dégrade alors le résultat au lieu de l'améliorer",
    );
  });

  test('le filtre de taille est désactivé, et le reste par défaut', () {
    // **Une conclusion, pas un oubli.** Ce filtre devait empêcher les textes de
    // règles de fabriquer des cartes fantômes. Mesuré sur deux photos réelles,
    // il ne sépare plus rien — le rapport entre la plus grande ligne et la
    // médiane tombe à 1,20 sur des cartes entières — et il coûtait vingt-trois
    // points de rappel. Ce qui écarte vraiment les fausses cartes est le seuil
    // de score, la règle de longueur relative, le nettoyage des parasites et le
    // filtre des lignes de type.
    expect(nameHeightRatio, 0);

    // Toutes les lignes plausibles passent donc, quelle que soit leur taille :
    // c'est le catalogue qui tranche ensuite.
    final names = spreadNameCandidates([
      ReadLine('Anneau solaire', 0.05, 0.030),
      ReadLine('Cherchauloin', 0.40, 0.008),
    ]).map((c) => c.text);

    expect(names, containsAll(['Anneau solaire', 'Cherchauloin']));
  });

  test('le filtre reste actionnable pour la mesure', () {
    // La constante est à zéro, mais le mécanisme demeure : l'outil de balayage
    // le rejoue sur des lignes réellement lues, et une photo future pourrait
    // rouvrir la question.
    final strict = spreadNameCandidates([
      ReadLine('Anneau solaire', 0.05, 0.030),
      ReadLine('menu fretin', 0.40, 0.008),
      ReadLine('autre ligne courte', 0.50, 0.008),
      ReadLine('encore une', 0.60, 0.008),
    ], heightRatio: 1.5).map((c) => c.text);

    expect(strict, isNot(contains('menu fretin')));
  });

  test('sans le filtre de taille, les lignes de règles redeviennent candidates', () {
    // Contre-épreuve du test précédent : il ne prouverait rien si les deux
    // lignes citant une carte étaient écartées pour une autre raison — leur
    // longueur, un mot-clé. En désactivant le seul filtre de taille, elles
    // doivent réapparaître, sans quoi ce n'est pas lui qui les retient.
    final names = spreadNameCandidates([
      ReadLine('Anneau solaire', 0.05, 0.030),
      ReadLine('Ajoutez deux manas incolores', 0.12, 0.012),
      ReadLine('Foudre inflige 3 blessures', 0.16, 0.012),
      ReadLine('Cherchauloin', 0.40, 0.030),
      ReadLine('Cherchez une carte de plaine', 0.47, 0.012),
      ReadLine('Chercheur des profondeurs', 0.51, 0.012),
    ], heightRatio: 0).map((c) => c.text);

    expect(names, contains('Foudre inflige 3 blessures'));
    expect(names, contains('Chercheur des profondeurs'));
  });

  test('une photo sans texte lisible ne propose rien', () {
    expect(spreadNameCandidates(const []), isEmpty);
  });

  group('deux lectures identiques ne sont pas forcement la meme carte', () {
    test('deux exemplaires eloignes donnent deux candidats', () {
      // **Mesure de terrain.** Sur une photo portant quatre exemplaires d'un
      // meme dinosaure, l'appareil lit quatre fois le meme nom. La fusion par
      // texte n'en gardait qu'un, et la quantite restait a 1 : la perte etait
      // silencieuse, l'utilisateur ne voyait pas ce qui manquait.
      final names = spreadNameCandidates(const [
        ReadLine('Savage Land Dinosaur', 0.20, 0.010, 0.10, 0.15),
        ReadLine('Savage Land Dinosaur', 0.60, 0.010, 0.55, 0.15),
      ]);

      expect(names.length, 2);
    });

    test('un nom coupe en deux ne compte que pour une carte', () {
      // Les deux morceaux d'un nom trop long pour sa ligne sont sur des lignes
      // consecutives, soit une a deux hauteurs de texte. Mesure : les
      // exemplaires les plus rapproches etaient a 8,3 hauteurs.
      final names = spreadNameCandidates(const [
        ReadLine('Savage Land Dinosaur', 0.200, 0.010, 0.10, 0.15),
        ReadLine('Savage Land Dinosaur', 0.212, 0.010, 0.10, 0.15),
      ]);

      expect(names.length, 1);
    });

    test('la distance se mesure en hauteurs de texte, pas en fractions', () {
      // **L'unite fait tout.** En fraction d'image, un seuil casserait des
      // qu'on s'eloigne de la table : les memes cartes occupent alors moins de
      // place. La hauteur du texte suit cette echelle.
      const petit = ReadLine('Foudre', 0.200, 0.004, 0.10, 0.05);
      const loin = ReadLine('Foudre', 0.220, 0.004, 0.10, 0.05);

      // 0,02 d'ecart vaut cinq hauteurs quand le texte fait 0,004 : deux cartes.
      expect(spreadNameCandidates(const [petit, loin]).length, 2);

      // Le meme ecart, avec un texte deux fois plus grand, n'en vaut plus que
      // deux et demi : une seule carte, vue de plus pres.
      expect(
        spreadNameCandidates(const [
          ReadLine('Foudre', 0.200, 0.008, 0.10, 0.05),
          ReadLine('Foudre', 0.220, 0.008, 0.10, 0.05),
        ]).length,
        1,
      );
    });

    test("deux exemplaires cote a cote se distinguent par l'abscisse", () {
      // Poses l'un a cote de l'autre, ils sont a la meme hauteur : sans
      // l'abscisse, rien ne les separerait.
      final names = spreadNameCandidates(const [
        ReadLine('Foudre', 0.30, 0.010, 0.10, 0.15),
        ReadLine('Foudre', 0.30, 0.010, 0.40, 0.15),
      ]);

      expect(names.length, 2);
    });

    test('sans hauteur connue, on fusionne comme avant', () {
      // La hauteur du texte est l'unite de mesure : sans elle, aucune distance
      // n'est interpretable. Compter en trop est la seule erreur que
      // l'utilisateur ne peut pas voir venir — a defaut d'information, on reste
      // prudent et on fusionne.
      final names = spreadNameCandidates(const [
        ReadLine('Foudre', 0.10, 0),
        ReadLine('Foudre', 0.80, 0),
      ]);

      expect(names.length, 1);
    });

    test('sans abscisse, la seule distance verticale suffit', () {
      // Les jeux d'essai anciens ne portent pas d'abscisse. Deux lectures
      // separees de vingt-trois hauteurs de texte restent deux cartes : l'axe
      // manquant ne rend pas l'autre muet.
      final names = spreadNameCandidates(const [
        ReadLine('Foudre', 0.10, 0.03),
        ReadLine('Foudre', 0.80, 0.03),
      ]);

      expect(names.length, 2);
    });
  });
}
