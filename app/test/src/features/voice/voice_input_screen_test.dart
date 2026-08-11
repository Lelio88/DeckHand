/// Tests de l'écran de dictée.
///
/// **Ce que cet écran a de particulier : il écrit sans qu'on ait rien touché.**
/// L'édition d'une carte à édition unique y est retenue d'office, comme à
/// l'étalement — c'est ce qui empêche la dictée de fabriquer du travail pour
/// plus tard, la collection réelle ayant 274 de ses 278 lignes précisées par
/// ce seul mécanisme. Mais une édition posée sans geste doit être **annoncée**
/// et **exacte** : c'est le garde-fou §IV.8 qui pèse ici.
///
/// Les assertions portent sur ce que le dépôt reçoit, pas sur ce que l'écran
/// affiche — sauf pour l'annonce, dont l'affichage *est* le sujet.
library;

import 'package:deckhand/src/features/card_search/data/card_repository.dart';
import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:deckhand/src/features/voice/data/speech_service.dart';
import 'package:deckhand/src/features/voice/presentation/voice_input_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

/// Moteur de dictée sous contrôle du test.
///
/// `SpeechService` enveloppe le moteur du système, indisponible en test. On en
/// implémente l'interface pour tenir le fil que l'écran écoute, et pousser une
/// phrase quand le test le décide.
class _FakeSpeech implements SpeechService {
  void Function(String text, bool isFinal)? _onResult;
  bool _listening = false;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> start({
    required DictationLanguage language,
    required void Function(String text, bool isFinal) onResult,
    void Function()? onGaveUp,
  }) async {
    _listening = true;
    _onResult = onResult;
  }

  @override
  Future<void> stop() async => _listening = false;

  /// Fait entendre une phrase, comme le moteur la livrerait une fois close.
  void say(String text) => _onResult?.call(text, true);
}

CardHit _hit(String oracleId, String name) => CardHit(
  oracleId: oracleId,
  name: name,
  matchedName: name,
  matchedLang: 'fr',
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  score: 1,
);

/// Monte l'écran, ouvre l'écoute, et rend de quoi conduire le test.
Future<({_FakeSpeech speech, FakeCollectionRepository collection})> pumpVoice(
  WidgetTester tester, {
  required List<CardHit> catalogue,
  Map<String, CardPrinting> sole = const {},
  Object? soleError,
}) async {
  final speech = _FakeSpeech();
  final collection = FakeCollectionRepository();
  final cards = FakeCardRepository()..results = catalogue;
  final printings = FakePrintingRepository()
    ..sole = sole
    ..soleError = soleError;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        speechServiceProvider.overrideWithValue(speech),
        cardRepositoryProvider.overrideWithValue(cards),
        collectionRepositoryProvider.overrideWithValue(collection),
        printingRepositoryProvider.overrideWithValue(printings),
      ],
      child: const MaterialApp(home: VoiceInputScreen()),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text('Dicter'));
  await tester.pumpAndSettle();

  return (speech: speech, collection: collection);
}

void main() {
  const mar = CardPrinting(
    printId: 'print-mar',
    setCode: 'mar',
    setName: 'Marvel',
    collectorNumber: '43',
    lang: 'fr',
    hasNonfoil: true,
  );

  testWidgets('une carte dictée est proposée avant d\'être écrite', (
    tester,
  ) async {
    // Garde-fou §IV.8 : la reconnaissance vocale se trompe davantage encore
    // qu'une photo, rien n'entre en collection sans validation en bloc.
    final fakes = await pumpVoice(
      tester,
      catalogue: [_hit('id-1', 'Agent d\'Atlas')],
    );

    fakes.speech.say('Agent d\'Atlas');
    await tester.pumpAndSettle();

    expect(find.text('Agent d\'Atlas'), findsOneWidget);
    expect(
      fakes.collection.added,
      isEmpty,
      reason: 'rien ne doit atteindre la collection avant « Ajouter »',
    );
  });

  testWidgets('l\'édition unique est retenue sans geste et accompagne la '
      'carte jusqu\'au dépôt', (tester) async {
    // C'est ce qui empêche la dictée d'envoyer tout dans la pile à trier,
    // là où l'étalement précise déjà d'office.
    final fakes = await pumpVoice(
      tester,
      catalogue: [_hit('id-1', 'Agent d\'Atlas')],
      sole: const {'id-1': mar},
    );

    fakes.speech.say('Agent d\'Atlas');
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Ajouter'));
    await tester.pumpAndSettle();

    expect(fakes.collection.added.single.printId, 'print-mar');
    expect(fakes.collection.added.single.isFoil, isFalse);
  });

  testWidgets('l\'édition retenue est annoncée, jamais subie', (tester) async {
    // Elle a été posée sans geste : un coup d'œil doit suffire à la confronter
    // à ce qui est imprimé en bas de la carte.
    final fakes = await pumpVoice(
      tester,
      catalogue: [_hit('id-1', 'Agent d\'Atlas')],
      sole: const {'id-1': mar},
    );

    fakes.speech.say('Agent d\'Atlas');
    await tester.pumpAndSettle();

    expect(find.textContaining('MAR'), findsOneWidget);
  });

  testWidgets('une carte à plusieurs éditions reste à préciser', (
    tester,
  ) async {
    // Le catalogue ne rend une édition unique que pour les cartes qui n'en ont
    // qu'une : les autres partent sans édition, et se rangent depuis la pile.
    final fakes = await pumpVoice(tester, catalogue: [_hit('id-1', 'Foudre')]);

    fakes.speech.say('Foudre');
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Ajouter'));
    await tester.pumpAndSettle();

    expect(fakes.collection.added.single.printId, isNull);
  });

  testWidgets('une panne du catalogue laisse la dictée intacte', (
    tester,
  ) async {
    // Sans édition, la carte part « à trier » — l'état d'avant, jamais une
    // perte. Rien ne justifie d'interrompre une dictée en cours pour cela.
    final fakes = await pumpVoice(
      tester,
      catalogue: [_hit('id-1', 'Agent d\'Atlas')],
      soleError: Exception('catalogue injoignable'),
    );

    fakes.speech.say('Agent d\'Atlas');
    await tester.pumpAndSettle();

    expect(find.text('Agent d\'Atlas'), findsOneWidget);

    await tester.tap(find.textContaining('Ajouter'));
    await tester.pumpAndSettle();

    expect(fakes.collection.added.single.printId, isNull);
  });
}
