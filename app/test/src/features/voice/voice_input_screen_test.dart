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

  /// Éditions que le sélecteur proposera, pour les cartes qui en ont plusieurs.
  List<CardPrinting> printings = const [],
  Object? printingsError,
}) async {
  final speech = _FakeSpeech();
  final collection = FakeCollectionRepository();
  final cards = FakeCardRepository()..results = catalogue;
  final printingRepo = FakePrintingRepository()
    ..printings = printings
    ..forCardError = printingsError
    ..sole = sole
    ..soleError = soleError;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        speechServiceProvider.overrideWithValue(speech),
        cardRepositoryProvider.overrideWithValue(cards),
        collectionRepositoryProvider.overrideWithValue(collection),
        printingRepositoryProvider.overrideWithValue(printingRepo),
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
    // qu'une : les autres partent sans édition tant que personne ne tranche.
    final fakes = await pumpVoice(tester, catalogue: [_hit('id-1', 'Foudre')]);

    fakes.speech.say('Foudre');
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Ajouter'));
    await tester.pumpAndSettle();

    expect(fakes.collection.added.single.printId, isNull);
  });

  group("l'édition se précise à la main, une fois l'écoute arrêtée", () {
    // **Ce que ce groupe protège.** La dictée était la seule voie d'ajout sans
    // sélecteur d'édition : tout ce que le catalogue ne tranchait pas d'office
    // partait dans la pile à trier, à ranger plus tard. Le geste manquait parce
    // qu'une feuille modale ouverte pendant que le micro écoute laisserait les
    // cartes s'accumuler derrière elle — un argument qui tombe dès qu'on a
    // coupé, c'est-à-dire au moment où l'on relit sa liste avant de l'ajouter.
    const msh = CardPrinting(
      printId: 'print-msh',
      setCode: 'msh',
      setName: 'Marvel',
      lang: 'fr',
      hasNonfoil: true,
    );

    testWidgets('la ligne reste inerte tant que le micro écoute', (
      tester,
    ) async {
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [msh],
      );

      fakes.speech.say('Foudre');
      await tester.pumpAndSettle();

      await tester.tap(find.text("Préciser l'édition"));
      await tester.pumpAndSettle();

      expect(
        find.text("Ne pas préciser l'édition"),
        findsNothing,
        reason:
            'le sélecteur masquerait la liste pendant que les cartes '
            'continuent de s\'y ajouter',
      );
    });

    testWidgets("l'édition choisie accompagne la carte jusqu'au dépôt", (
      tester,
    ) async {
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [msh],
      );

      fakes.speech.say('Foudre');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Arrêter'));
      await tester.pumpAndSettle();

      await tester.tap(find.text("Préciser l'édition"));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Marvel').last);
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(
        fakes.collection.added.single.printId,
        'print-msh',
        reason:
            'une édition affichée mais non transmise vaudrait pire que pas '
            "d'édition : la valorisation paraîtrait précise en restant fausse",
      );
    });

    testWidgets("« ne pas préciser » survit à la reprise de l'écoute", (
      tester,
    ) async {
      // Écarter l'édition laisse la ligne nulle, exactement comme une carte
      // jamais examinée : sans marque, le remplissage d'office la reprendrait
      // à la phrase suivante et défairait le geste.
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Agent d\'Atlas')],
        sole: const {'id-1': mar},
      );

      fakes.speech.say('Agent d\'Atlas');
      await tester.pumpAndSettle();
      expect(find.textContaining('MAR'), findsOneWidget);

      await tester.tap(find.text('Arrêter'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('MAR'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Ne pas préciser l'édition"));
      await tester.pumpAndSettle();
      expect(find.text("Préciser l'édition"), findsOneWidget);

      // La dictée reprend, et une phrase de plus rappelle le remplissage
      // d'office sur toute la liste : c'est là que le geste se défaisait.
      await tester.tap(find.text('Dicter'));
      await tester.pumpAndSettle();
      fakes.speech.say('un agent d\'Atlas de plus');
      await tester.pumpAndSettle();

      expect(
        find.text("Préciser l'édition"),
        findsOneWidget,
        reason:
            'le catalogue ne doit pas rendre une édition que l\'on vient '
            'd\'écarter',
      );

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(fakes.collection.added.single.printId, isNull);
    });
  });

  group("l'édition et la finition se disent", () {
    // **Ce que ce groupe protège.** Dire l'édition évite de la chercher au
    // doigt une fois l'écoute arrêtée — mais une édition dite reste une
    // édition entendue, donc parfois mal entendue. Elle n'est retenue que si
    // rien ne reste à choisir (garde-fou §IV.8), et sinon la ligne dit
    // pourquoi : « Préciser l'édition » seul laisserait croire qu'on n'a rien
    // dit.
    const m21 = CardPrinting(
      printId: 'print-m21',
      setCode: 'm21',
      setName: 'Core Set 2021',
      collectorNumber: '137',
      lang: 'fr',
      hasFoil: true,
    );
    const m21Vitrine = CardPrinting(
      printId: 'print-m21-300',
      setCode: 'm21',
      setName: 'Core Set 2021',
      collectorNumber: '300',
      lang: 'fr',
    );
    const dmu = CardPrinting(
      printId: 'print-dmu',
      setCode: 'dmu',
      setName: 'Dominaria United',
      collectorNumber: '1',
      lang: 'fr',
    );
    const dmr = CardPrinting(
      printId: 'print-dmr',
      setCode: 'dmr',
      setName: 'Dominaria Remastered',
      collectorNumber: '1',
      lang: 'fr',
    );

    testWidgets("l'édition et la finition dites partent avec la carte", (
      tester,
    ) async {
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [m21, m21Vitrine, dmu],
      );

      fakes.speech.say('foudre édition m21 numéro 137 brillante');
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      final added = fakes.collection.added.single;
      expect(added.printId, 'print-m21');
      expect(added.isFoil, isTrue);
    });

    testWidgets("une extension qui laisse plusieurs éditions ouvre le "
        "sélecteur sur elles", (tester) async {
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [m21, dmu, dmr],
      );

      fakes.speech.say('foudre édition dominaria');
      await tester.pumpAndSettle();
      expect(find.textContaining('plusieurs éditions'), findsOneWidget);

      await tester.tap(find.text('Arrêter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Préciser l'édition"));
      await tester.pumpAndSettle();

      expect(find.textContaining('Dominaria Remastered'), findsOneWidget);
      expect(
        find.textContaining('Core Set 2021'),
        findsNothing,
        reason: "ce qui a été dit ne se retape pas : l'extension filtre déjà",
      );

      await tester.tap(find.textContaining('Dominaria United'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(fakes.collection.added.single.printId, 'print-dmu');
    });

    testWidgets("un nom approché, même seul candidat, se confirme au doigt", (
      tester,
    ) async {
      // « dominaria » ne désigne pas Dominaria United : la carte n'existe que
      // là, mais le mot dit pourrait être un mot mal entendu (garde-fou §IV.8).
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [m21, dmu],
      );

      fakes.speech.say('foudre édition dominaria');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Dominaria United ? À confirmer'),
        findsOneWidget,
      );

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(fakes.collection.added.single.printId, isNull);
    });

    testWidgets('une extension introuvable est dite, et rien ne part', (
      tester,
    ) async {
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [m21],
      );

      fakes.speech.say('foudre édition xyz');
      await tester.pumpAndSettle();
      expect(find.textContaining('« xyz » introuvable'), findsOneWidget);

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(fakes.collection.added.single.printId, isNull);
    });

    testWidgets("une brillante que l'édition n'a jamais eue ne retient rien", (
      tester,
    ) async {
      // Lequel des deux mots a été mal entendu ? Rien ne le dit : retenir
      // l'édition sans la finition serait deviner.
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [m21, m21Vitrine],
      );

      fakes.speech.say('foudre édition m21 numéro 300 brillante');
      await tester.pumpAndSettle();
      expect(find.textContaining("n'existe pas en brillante"), findsOneWidget);

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      final added = fakes.collection.added.single;
      expect(added.printId, isNull);
      expect(added.isFoil, isFalse);
    });

    testWidgets('chaque édition dite a sa ligne, et redire la même cumule', (
      tester,
    ) async {
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [m21, dmu],
      );

      fakes.speech.say('foudre édition m21');
      await tester.pumpAndSettle();
      fakes.speech.say('foudre édition dominaria united');
      await tester.pumpAndSettle();
      fakes.speech.say('deux foudre édition m21');
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(
        {for (final a in fakes.collection.added) a.printId: a.quantity},
        {'print-m21': 3, 'print-dmu': 1},
      );
    });

    testWidgets("une édition dite n'est pas remplacée par l'édition unique", (
      tester,
    ) async {
      // La carte n'a qu'une édition, et ce n'est pas celle qu'on a dite :
      // la retenir quand même répondrait à côté de la demande.
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Agent d\'Atlas')],
        sole: const {'id-1': mar},
        printings: const [mar],
      );

      fakes.speech.say('agent d\'atlas édition xyz');
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(fakes.collection.added.single.printId, isNull);
    });

    testWidgets("la brillante dite s'applique à l'édition unique", (
      tester,
    ) async {
      const marBrillante = CardPrinting(
        printId: 'print-mar',
        setCode: 'mar',
        setName: 'Marvel',
        collectorNumber: '43',
        lang: 'fr',
        hasFoil: true,
      );
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Agent d\'Atlas')],
        sole: const {'id-1': marBrillante},
      );

      fakes.speech.say('agent d\'atlas foil');
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      final added = fakes.collection.added.single;
      expect(added.printId, 'print-mar');
      expect(added.isFoil, isTrue);
    });

    testWidgets("la brillante sans édition ne part pas brillante, et le dit", (
      tester,
    ) async {
      // Une carte brillante sans édition entre dans la pile à trier, d'où elle
      // ne se range pas encore : la dictée ne l'y envoie pas.
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printings: const [m21, dmu],
      );

      fakes.speech.say('foudre en foil');
      await tester.pumpAndSettle();
      expect(find.textContaining('Brillante : précisez'), findsOneWidget);

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      final added = fakes.collection.added.single;
      expect(added.printId, isNull);
      expect(added.isFoil, isFalse);
    });

    testWidgets("un catalogue d'éditions injoignable est dit, la carte reste", (
      tester,
    ) async {
      final fakes = await pumpVoice(
        tester,
        catalogue: [_hit('id-1', 'Foudre')],
        printingsError: Exception('catalogue injoignable'),
      );

      fakes.speech.say('foudre édition m21');
      await tester.pumpAndSettle();
      expect(find.textContaining('catalogue injoignable'), findsOneWidget);

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(fakes.collection.added.single.printId, isNull);
    });
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
