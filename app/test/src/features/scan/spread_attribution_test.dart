import 'package:deckhand/src/features/scan/domain/card_segmentation.dart';
import 'package:deckhand/src/features/scan/domain/spread_attribution.dart';
import 'package:deckhand/src/features/scan/domain/spread_names.dart';
import 'package:flutter_test/flutter_test.dart';

/// Une lecture reconnue, placée en fractions de l'image.
MatchedReading _lu(String identity, double top, double left) =>
    MatchedReading(identity, NameCandidate(identity, top, left: left));

/// Trois cartes debout, côte à côte, bien séparées — la disposition de la photo
/// qui a révélé le défaut : 9 cartes, trois par rangée.
const _rangee = [
  CardBounds(0.10, 0.10, 0.30, 0.38),
  CardBounds(0.40, 0.10, 0.60, 0.38),
  CardBounds(0.70, 0.10, 0.90, 0.38),
];

Set<String> _identites(List<MatchedReading> lectures) =>
    lectures.map((r) => r.identity).toSet();

void main() {
  group('attributeToCards', () {
    test('la ligne de capacités « Vol » ne fait pas une carte', () {
      // Mesuré : « Vol », seul mot-clé de sa ligne, trouvait la carte *Vol*
      // (Flight) avec un score parfait, à 59 % de la hauteur de *Revenant
      // rampant* — en deçà du seuil de citation. Une carte porte un seul nom.
      final lectures = [
        _lu('Revenant rampant', 0.12, 0.12),
        _lu('Vol', 0.265, 0.12),
        _lu('Labourage désordonné', 0.12, 0.42),
        _lu('Gerrard', 0.12, 0.72),
      ];

      final r = attributeToCards(lectures, _rangee);

      expect(_identites(r.kept), {
        'Revenant rampant',
        'Labourage désordonné',
        'Gerrard',
      });
      expect(_identites(r.absorbed), {'Vol'});
    });

    test('le nom cité dans les règles ne compte pas un second exemplaire', () {
      // « : Régénérez le Meneur de Rakdos. » marquait 0,607 et comptait pour
      // un deuxième carton, à 82 % de la carte.
      final lectures = [
        _lu('Meneur', 0.12, 0.12),
        _lu('Meneur', 0.33, 0.13),
        _lu('Druide', 0.12, 0.42),
        _lu('Trou', 0.12, 0.72),
      ];

      final r = attributeToCards(lectures, _rangee);

      expect(r.kept.where((l) => l.identity == 'Meneur').length, 1);
      expect(r.absorbed.single.line.top, 0.33);
    });

    test('une citation au bout opposé est écartée', () {
      // Le comportement du filtre des citations, conservé.
      final lectures = [
        _lu('Dino', 0.12, 0.12),
        _lu('Ka-Zar', 0.36, 0.12),
        _lu('Hyde', 0.12, 0.42),
        _lu('Foudre', 0.12, 0.72),
      ];

      final r = attributeToCards(lectures, _rangee);

      expect(_identites(r.absorbed), {'Ka-Zar'});
    });

    test("une carte citée ici mais posée ailleurs reste une carte", () {
      // Les dinosaures citent Ka-Zar ; si une carte Ka-Zar est sur la table,
      // son propre rectangle la désigne.
      final lectures = [
        _lu('Dino', 0.12, 0.12),
        _lu('Ka-Zar', 0.36, 0.12),
        _lu('Ka-Zar', 0.12, 0.42),
        _lu('Foudre', 0.12, 0.72),
      ];

      final r = attributeToCards(lectures, _rangee);

      expect(_identites(r.kept), contains('Ka-Zar'));
    });

    test('une lecture hors de tout rectangle est gardée telle quelle', () {
      // Cartes jointives soudées en blocs, nom qui déborde sur la voisine : ce
      // que les rectangles ne savent pas situer retombe sur l'ancien
      // comportement, jamais sur pire.
      final lectures = [
        _lu('Revenant', 0.12, 0.12),
        _lu('Labourage', 0.12, 0.42),
        _lu('Gerrard', 0.12, 0.72),
        _lu('Posée à côté', 0.70, 0.40),
      ];

      final r = attributeToCards(lectures, _rangee);

      expect(_identites(r.kept), contains('Posée à côté'));
      expect(r.absorbed, isEmpty);
    });

    test('le nom qui déborde de sa carte ne la vide pas', () {
      // Le nom siège à deux pour cent du bord : il tombe parfois juste hors du
      // rectangle, et ne peut alors ni être élu ni être absorbé.
      final lectures = [
        _lu('Revenant', 0.095, 0.12),
        _lu('Labourage', 0.12, 0.42),
        _lu('Gerrard', 0.12, 0.72),
      ];

      final r = attributeToCards(lectures, _rangee);

      expect(_identites(r.kept), {'Revenant', 'Labourage', 'Gerrard'});
    });

    test('des cartes posées à l\'envers portent leur nom en bas', () {
      // Le sens se lit dans la photo : noms à 93-103 % sur une photo mesurée.
      final lectures = [
        _lu('Revenant', 0.36, 0.12),
        _lu('Vol', 0.20, 0.12),
        _lu('Labourage', 0.36, 0.42),
        _lu('Gerrard', 0.36, 0.72),
      ];

      final r = attributeToCards(lectures, _rangee);

      expect(_identites(r.absorbed), {'Vol'});
      expect(_identites(r.kept), {'Revenant', 'Labourage', 'Gerrard'});
    });

    test("un rectangle couché parmi des cartes debout n'absorbe rien", () {
      // **Deux cartes soudées côte à côte ont le rapport d'une carte couchée.**
      // Le second nom y siège au milieu : l'absorber perdrait une carte réelle.
      // Un rectangle qui contredit l'orientation de la majorité est donc
      // laissé à l'ancien comportement.
      const cartes = [
        ..._rangee,
        CardBounds(0.10, 0.50, 0.50, 0.78), // deux cartes soudées
      ];
      final lectures = [
        _lu('Revenant', 0.12, 0.12),
        _lu('Labourage', 0.12, 0.42),
        _lu('Gerrard', 0.12, 0.72),
        _lu('Gauche', 0.52, 0.12),
        _lu('Droite', 0.52, 0.32),
      ];

      final r = attributeToCards(lectures, cartes);

      expect(_identites(r.kept), containsAll(['Gauche', 'Droite']));
      expect(r.absorbed, isEmpty);
    });

    test('les positions lues sont ramenées à la photo entière', () {
      // ML Kit ne donne pas la taille de l'image : les positions sont des
      // fractions de l'étendue du texte lu. Sur la photo mesurée, 1444 × 1855
      // pour une image de 1600 × 2125 — 13 % d'écart, assez pour sortir une
      // mention de règles de son rectangle et la compter comme une carte.
      final lectures = [
        // En fractions du texte lu ; ×0,873 en hauteur les ramène à l'image.
        _lu('Meneur', 0.14, 0.13),
        _lu('Meneur', 0.40, 0.14), // 0,349 dans l'image : dans la carte
        _lu('Druide', 0.14, 0.45),
        _lu('Trou', 0.14, 0.78),
      ];

      final brut = attributeToCards(lectures, _rangee);
      final ramene = attributeToCards(
        lectures,
        _rangee,
        scaleX: 1444 / 1600,
        scaleY: 1855 / 2125,
      );

      expect(brut.absorbed, isEmpty, reason: 'hors du rectangle sans échelle');
      expect(ramene.absorbed.single.line.top, 0.40);
    });

    test("l'orientation d'une carte se juge en pixels, pas en fractions", () {
      // **Mesuré sur la photo qui a révélé le défaut** (3072 × 4080) : une
      // carte debout y mesure 0,2175 de large pour 0,2116 de haut, en fractions
      // de l'image. Jugée ainsi, elle passe pour couchée, et le nom se cherche
      // le long de la mauvaise dimension. En pixels, 668 × 863 : debout.
      const cartes = [
        CardBounds(0.130, 0.140, 0.3475, 0.3518),
        CardBounds(0.3875, 0.126, 0.6062, 0.333),
        CardBounds(0.6663, 0.121, 0.8788, 0.3208),
      ];
      final lectures = [
        // « Vol » lu avant le nom, à la même abscisse : seule la hauteur
        // départage — et seulement si l'on sait que la carte est debout.
        _lu('Vol', 0.265, 0.16),
        _lu('Revenant', 0.155, 0.16),
        _lu('Labourage', 0.14, 0.42),
        _lu('Gerrard', 0.135, 0.70),
      ];

      final r = attributeToCards(lectures, cartes, imageAspect: 3072 / 4080);

      expect(_identites(r.kept), {'Revenant', 'Labourage', 'Gerrard'});
      expect(_identites(r.absorbed), {'Vol'});
    });

    test('sans rectangle, tout est gardé', () {
      final lectures = [_lu('Foudre', 0.1, 0.1), _lu('Vol', 0.2, 0.1)];

      final r = attributeToCards(lectures, const []);

      expect(r.kept.length, 2);
      expect(r.absorbed, isEmpty);
    });

    test("un rectangle qui ne porte qu'une citation l'écarte", () {
      // Titre illisible, citation lue : le rectangle ne porte rien au bout
      // des noms, et ce qu'il porte au bout opposé n'est pas une carte.
      final lectures = [
        _lu('Revenant', 0.12, 0.12),
        _lu('Labourage', 0.12, 0.42),
        _lu('Multani', 0.37, 0.72),
      ];

      final r = attributeToCards(lectures, _rangee);

      expect(_identites(r.absorbed), {'Multani'});
    });
  });
}
