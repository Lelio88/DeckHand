/// Tests de la vue de construction.
///
/// **Ce que l'écran doit garantir**, au-delà du moteur qui est éprouvé
/// ailleurs : qu'on choisisse son général ou qu'on laisse choisir, que le deck
/// affiché soit celui du général retenu, et surtout que le diagnostic reste
/// visible. Un constructeur qui tairait ses manques ferait passer un outil pour
/// un oracle.
library;

import 'package:deckhand/src/features/auth/data/auth_repository.dart';
import 'package:deckhand/src/features/builder/data/buildable_repository.dart';
import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/builder/presentation/deck_builder_view.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fakes.dart';

BuildableCard card({
  required String name,
  String type = 'Creature — Human',
  double cmc = 3,
  Set<String> colors = const {'B'},
  String text = '',
}) => BuildableCard(
  oracleId: name,
  name: name,
  typeLine: type,
  cmc: cmc,
  colorIdentity: colors,
  oracleText: text,
);

Future<FakeBuildableRepository> pumpBuilder(
  WidgetTester tester, {
  required List<BuildableCard> cards,
}) async {
  final repository = FakeBuildableRepository()..cards = cards;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        buildableRepositoryProvider.overrideWithValue(repository),
        sessionProvider.overrideWith(
          (ref) => Stream<Session?>.value(fakeSession()),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: DeckBuilderView(format: DeckFormat.commander)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  final general = card(
    name: 'Général',
    type: 'Legendary Creature — Human Noble',
  );
  final other = card(
    name: 'Autre général',
    type: 'Legendary Creature — Human Noble',
    colors: {'B', 'R'},
  );

  testWidgets('sans créature légendaire, l\'écran le dit', (tester) async {
    // Un deck Commander se construit autour d'un général : sans lui, il n'y a
    // rien à proposer, et une liste vide n'expliquerait pas pourquoi.
    await pumpBuilder(tester, cards: [card(name: 'Ordinaire')]);

    expect(
      find.textContaining('Aucune créature légendaire'),
      findsOneWidget,
    );
  });

  testWidgets('les généraux possibles sont proposés', (tester) async {
    await pumpBuilder(tester, cards: [general, other, card(name: 'Ordinaire')]);

    expect(find.text('2 généraux possibles'), findsOneWidget);
    expect(find.text('Général'), findsOneWidget);
    expect(find.text('Autre général'), findsWidgets);
  });

  testWidgets('« choisir pour moi » retient celui qui ouvre le plus', (
    tester,
  ) async {
    // Le bicolore donne accès aux deux couleurs, donc à plus de cartes.
    await pumpBuilder(
      tester,
      cards: [
        general,
        other,
        for (var i = 0; i < 5; i++) card(name: 'Rouge $i', colors: {'R'}),
      ],
    );

    await tester.tap(find.textContaining('Choisir pour moi'));
    await tester.pumpAndSettle();

    expect(find.text('Autre général'), findsOneWidget);
    expect(find.textContaining('cartes de votre collection'), findsOneWidget);
  });

  testWidgets('choisir un général construit son deck', (tester) async {
    await pumpBuilder(
      tester,
      cards: [
        general,
        for (var i = 0; i < 40; i++) card(name: 'Carte $i'),
      ],
    );

    await tester.tap(find.text('Général'));
    await tester.pumpAndSettle();

    expect(find.textContaining('cartes de votre collection'), findsOneWidget);
    expect(find.text('Terrains de base'), findsOneWidget);
  });

  testWidgets('le diagnostic reste visible', (tester) async {
    // Une collection sans retrait produit un deck sans retrait : l'écran doit
    // le montrer plutôt que de présenter le résultat comme abouti.
    await pumpBuilder(
      tester,
      cards: [
        general,
        for (var i = 0; i < 40; i++) card(name: 'Carte $i'),
      ],
    );

    await tester.tap(find.text('Général'));
    await tester.pumpAndSettle();

    expect(find.text('Ce que le deck vise'), findsOneWidget);
    expect(find.text('retrait'), findsOneWidget);
    // Retrait et accélération valent tous deux 6 dans le corpus, et aucune
    // n'est ici satisfaite : deux jauges portent donc le même compte.
    expect(find.text('0 / 6'), findsNWidgets(2));
  });

  testWidgets('une collection trop maigre est annoncée comme telle', (
    tester,
  ) async {
    await pumpBuilder(tester, cards: [general, card(name: 'Seule')]);

    await tester.tap(find.text('Général'));
    await tester.pumpAndSettle();

    expect(find.textContaining('il en manque'), findsOneWidget);
    expect(find.textContaining('ne suffit pas'), findsOneWidget);
  });

  testWidgets('on peut revenir au choix du général', (tester) async {
    await pumpBuilder(tester, cards: [general, other]);

    await tester.tap(find.text('Général'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Changer'));
    await tester.pumpAndSettle();

    expect(find.text('2 généraux possibles'), findsOneWidget);
  });
}
