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

  test('une même carte lue deux fois ne compte qu\'une fois', () {
    final names = spreadNameCandidates([
      ReadLine('Foudre', 0.10, 0.03),
      ReadLine('foudre', 0.50, 0.03),
    ]);

    expect(names.length, 1);
  });

  test('le nombre de candidats est plafonné', () {
    // Un nom pour quatre lignes de règles, proportion d'une carte réelle :
    // c'est ce qui fait tomber la médiane sur le corps de texte.
    final many = [
      for (var i = 0; i < 300; i++)
        ReadLine('Carte numéro $i', i / 300, i % 5 == 0 ? 0.03 : 0.01),
    ];

    expect(spreadNameCandidates(many).length, maxSpreadCandidates);
  });

  test("le texte de règles est écarté par sa taille, même s'il cite une carte", () {
    // Le défaut mesuré sur le terrain : six cartes étalées, huit proposées,
    // les fausses venant de noms cités dans les textes de règles.
    final names = spreadNameCandidates([
      ReadLine('Anneau solaire', 0.05, 0.030),
      ReadLine('Ajoutez deux manas incolores', 0.12, 0.012),
      ReadLine('Foudre inflige 3 blessures', 0.16, 0.012),
      ReadLine('Cherchauloin', 0.40, 0.030),
      ReadLine('Cherchez une carte de plaine', 0.47, 0.012),
      ReadLine('Chercheur des profondeurs', 0.51, 0.012),
    ]).map((c) => c.text);

    expect(names, ['Anneau solaire', 'Cherchauloin']);
  });

  test('une photo sans texte lisible ne propose rien', () {
    expect(spreadNameCandidates(const []), isEmpty);
  });
}
