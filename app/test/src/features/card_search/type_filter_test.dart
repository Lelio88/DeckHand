/// Tests du filtre de type.
///
/// **Le filtrage vit côté serveur**, et c'est ce qui rend ce composant
/// important : restreindre après coup ne garderait que les terrains des vingt
/// premiers résultats, soit souvent aucun. Ce qui se vérifie ici est donc que le
/// geste produit bien l'ensemble de types que l'écran transmettra au catalogue.
///
/// Il est testé **isolément** pour couvrir ses quatre gestes — cocher,
/// accumuler, décocher, tout effacer — sans rejouer l'écran entier à chaque
/// fois. La chaîne complète, du geste jusqu'à la requête au catalogue, est
/// vérifiée une fois dans `card_search_screen_test.dart` : c'est elle qui
/// prouve que le filtre est branché, ce que des tests isolés ne peuvent pas
/// dire.
library;

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/card_search/domain/card_type.dart';
import 'package:deckhand/src/features/card_search/presentation/card_search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _types = [
  CardType('Creature', 'Créature'),
  CardType('Instant', 'Éphémère'),
];

Future<Set<String>?> pumpFilter(
  WidgetTester tester, {
  Set<String> selected = const {},
  required String tap,
}) async {
  Set<String>? received;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: TypeFilter(
            types: _types,
            selected: selected,
            onChanged: (v) => received = v,
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.byType(TypeFilter));
  await tester.pumpAndSettle();
  await tester.tap(find.text(tap).last);
  await tester.pumpAndSettle();
  return received;
}

void main() {
  test('chaque jeu propose des types cherchables', () {
    // Un jeu sans type n'afficherait qu'un menu vide, et le filtre — la coupe la
    // plus économique offerte à la saisie — disparaîtrait sans un mot.
    for (final game in Game.values) {
      expect(
        cardTypesFor(game),
        isNotEmpty,
        reason: 'le jeu « ${game.id} » ne propose aucun type',
      );
    }
  });

  test('un type Yu-Gi-Oh ne se confond pas avec une famille de monstres', () {
    // **Le filtre est un `ILIKE` sur la ligne de type entière.** « Spell »
    // attraperait les quelque sept cents monstres *Spellcaster* en plus des
    // magies ; le vocabulaire officiel dit « Spell Card », et c'est lui qui est
    // déclaré. Le même piège vise « Trap ».
    final kinds = cardTypesFor(Game.yugioh).map((t) => t.kind);
    expect(kinds, contains('Spell Card'));
    expect(kinds, contains('Trap Card'));
    expect(kinds, isNot(contains('Spell')));
  });

  testWidgets('cocher un type le transmet', (tester) async {
    expect(await pumpFilter(tester, tap: 'Créature'), {'Creature'});
  });

  testWidgets('plusieurs types s\'accumulent', (tester) async {
    // On cherche parfois « créature ou artefact » : le filtre n'est pas un
    // choix exclusif.
    expect(await pumpFilter(tester, selected: {'Creature'}, tap: 'Éphémère'), {
      'Creature',
      'Instant',
    });
  });

  testWidgets('re-cocher un type le retire', (tester) async {
    expect(
      await pumpFilter(tester, selected: {'Creature'}, tap: 'Créature'),
      isEmpty,
    );
  });

  testWidgets('« Tous types » efface la sélection', (tester) async {
    expect(
      await pumpFilter(
        tester,
        selected: {'Creature', 'Instant'},
        tap: 'Tous types',
      ),
      isEmpty,
    );
  });

  testWidgets('l\'étiquette compte au-delà du premier type', (tester) async {
    // La place à gauche du champ ne permet pas d'énumérer : le premier type
    // nomme, les suivants se comptent.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: TypeFilter(
              types: _types,
              selected: {'Creature', 'Instant'},
              onChanged: _ignore,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Créature +1'), findsOneWidget);
  });
}

void _ignore(Set<String> _) {}
