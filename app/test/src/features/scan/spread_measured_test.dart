/// Le filtrage d'étalement, éprouvé sur ce que l'appareil a vraiment lu.
///
/// **Pourquoi ce test double ceux de `spread_names_test.dart`.** Ceux-là
/// travaillent sur des hauteurs choisies à la main, avec un nom deux fois plus
/// grand que ses règles — la carte telle qu'on l'imagine. La réalité mesurée est
/// beaucoup plus serrée : sur une photo d'étalement, un nom ne dépasse le corps
/// de texte que de 20 à 36 %, parce que les cartes ne sont pas toutes à la même
/// distance de l'objectif. Les tests synthétiques passaient donc allègrement
/// avec un seuil qui, sur le terrain, perdait deux cartes sur cinq.
///
/// Ce fichier verrouille le réglage sur les chiffres réels : le seuil doit
/// rester dans le plateau mesuré, où les cinq cartes sortent sans qu'aucune ne
/// soit inventée.
library;

import 'package:deckhand/src/features/scan/domain/spread_names.dart';
import 'package:flutter_test/flutter_test.dart';

import 'measured_spread.dart';

/// Ce que le catalogue retiendrait des lignes proposées.
///
/// La confrontation réelle passe par le réseau ; ici on se contente de savoir
/// si le nom d'une carte posée sur la table a survécu au filtrage, ce qui est
/// la seule chose que ce filtre décide.
Set<String> _cardsAmong(Iterable<String> candidates) =>
    spreadTruth.where(candidates.contains).toSet();

void main() {
  test('les cinq cartes posées survivent au filtrage', () {
    final names = spreadNameCandidates(measuredSpread).map((c) => c.text);

    expect(
      _cardsAmong(names),
      hasLength(spreadTruth.length),
      reason: 'mesuré sur le terrain : à 1,25 le filtre écartait « Agent 13, '
          'Sharon Carter » (1,22 fois la médiane) et « Agent Maria Hill » '
          '(1,21) — deux cartes réelles perdues faute de six centièmes',
    );
  });

  test('le mot-clé imprimé sur la carte reste écarté', () {
    // « Vigilance » est un mot-clé de règles autant qu'un nom de carte : c'est
    // le faux positif qui guette dès que le seuil descend trop bas. Il est lu à
    // 1,08 fois la médiane, ce qui fixe le plancher du plateau.
    final names = spreadNameCandidates(measuredSpread).map((c) => c.text);

    expect(names, isNot(contains('Vigilance')));
  });

  test('le seuil retenu est au centre du plateau, pas sur son bord', () {
    // Un seuil qui ne marche qu'à sa valeur exacte n'est pas un réglage, c'est
    // une coïncidence. On vérifie que le résultat tient de part et d'autre.
    for (final ratio in [1.10, 1.15, 1.20]) {
      final names =
          spreadNameCandidates(measuredSpread, heightRatio: ratio).map((c) => c.text);

      expect(
        _cardsAmong(names),
        hasLength(spreadTruth.length),
        reason: 'le plateau mesuré va de 1,10 à 1,20 ; à $ratio les cinq '
            'cartes doivent encore sortir',
      );
      expect(names, isNot(contains('Vigilance')), reason: 'à $ratio');
    }
  });
}
