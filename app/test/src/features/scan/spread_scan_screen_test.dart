/// Tests de l'écran d'étalement.
///
/// **Ce que cet écran a de particulier : il valide en bloc.** Une photo propose
/// dix cartes d'un coup, et l'utilisateur coche. Une erreur y passe donc plus
/// facilement qu'ailleurs, et une carte saisie à tort fausse ensuite toutes les
/// suggestions de decks — c'est le garde-fou §IV.8 qui pèse le plus lourd ici.
///
/// Les assertions portent sur **ce que le dépôt reçoit**, pas sur ce que
/// l'écran affiche. Une case décochée qui resterait cochée à l'écriture, ou une
/// quantité perdue en chemin, ne se verraient pas autrement : l'interface aurait
/// l'air juste dans les deux cas.
library;

import 'dart:typed_data';

import 'package:deckhand/src/config/selected_game.dart';
import 'package:deckhand/src/features/card_search/data/card_repository.dart';
import 'package:deckhand/src/features/card_search/domain/card_hit.dart';
import 'package:deckhand/src/features/collection/data/collection_repository.dart';
import 'package:deckhand/src/features/printings/data/printing_repository.dart';
import 'package:deckhand/src/features/printings/domain/card_printing.dart';
import 'package:deckhand/src/features/scan/application/scan_service.dart';
import 'package:deckhand/src/features/scan/data/photo_source.dart';
import 'package:deckhand/src/features/scan/domain/art_hash_index.dart';
import 'package:deckhand/src/features/scan/domain/card_name_text.dart';
import 'package:deckhand/src/features/scan/presentation/spread_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import '../../helpers/fakes.dart';

/// Catalogue qui repond au nom demande.
///
/// Le faux catalogue partage rend la meme carte quelle que soit la recherche,
/// ce qui suffit a un scan d'une seule carte mais confond toutes les lignes
/// d'un etalement en une : chaque nom lu retrouverait la meme carte.
class _FakeCatalogue implements CardRepository {
  _FakeCatalogue(this.cards);

  final List<CardHit> cards;

  @override
  Future<List<CardHit>> search(
    String query, {
    int limit = 20,
    Game game = Game.magic,
  }) async => cards
      .where((c) => c.matchedName.toLowerCase() == query.toLowerCase())
      .take(limit)
      .toList(growable: false);

  @override
  Future<List<CardHit>> byOracleIds(List<String> oracleIds) async => cards;

  /// Panne a simuler, pour verifier que l'ecran la montre au lieu de rendre
  /// une liste vide indiscernable d'un etalement illisible.
  Object? searchError;

  @override
  Future<Map<String, CardHit>> searchMany(
    List<String> names, {
    Game game = Game.magic,
  }) async {
    if (searchError != null) throw searchError!;
    return {
      for (final name in names)
        for (final card in cards)
          if (card.matchedName.toLowerCase() == name.toLowerCase())
            name: card,
    };
  }
}

/// Photo toujours disponible : la prise de vue n'est pas le sujet ici.
class _FakePhotoSource implements PhotoSource {
  @override
  Future<CapturedPhoto?> capture({
    required ImageSource source,
    required Color toolbarColor,
    required Color toolbarWidgetColor,
    BuildContext? webContext,
    bool crop = false,
  }) async => CapturedPhoto(bytes: Uint8List(0), path: 'etalement.jpg');
}

CardHit _hit(String oracleId, String name, {String lang = 'fr'}) => CardHit(
  oracleId: oracleId,
  name: name,
  matchedName: name,
  matchedLang: lang,
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  score: 1,
);

/// Monte l'écran, déclenche un scan, et rend les doublures pour inspection.
Future<({FakeCollectionRepository collection, FakePrintingRepository printings})>
pumpSpreadScan(WidgetTester tester, {required List<CardHit> found}) async {
  final collection = FakeCollectionRepository();
  final printings = FakePrintingRepository()
    ..printings = const [
      CardPrinting(printId: 'print-msh', setCode: 'msh', setName: 'Marvel', lang: 'fr'),
    ];
  final cards = _FakeCatalogue(found);
  // Une ligne par carte, assez grande pour passer le filtre de taille : ce
  // n'est pas lui qu'on éprouve ici.
  final reader = FakeCardTextReader()
    ..lines = [
      for (var i = 0; i < found.length; i++)
        ReadLine(found[i].matchedName, i / 10, 0.05),
    ];

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        photoSourceProvider.overrideWithValue(_FakePhotoSource()),
        collectionRepositoryProvider.overrideWithValue(collection),
        printingRepositoryProvider.overrideWithValue(printings),
        scanServiceProvider.overrideWith(
          (ref) async =>
              ScanService(ArtHashIndex.fromEntries(const []), reader, cards),
        ),
      ],
      child: const MaterialApp(home: SpreadScanScreen()),
    ),
  );

  await tester.tap(find.text('Photographier'));
  await tester.pumpAndSettle();

  return (collection: collection, printings: printings);
}

void main() {
  testWidgets('les cartes repérées sont proposées', (tester) async {
    await pumpSpreadScan(
      tester,
      found: [_hit('id-1', 'Agent Phil Coulson'), _hit('id-2', "Agent d'Atlas")],
    );

    expect(find.text('Agent Phil Coulson'), findsOneWidget);
    expect(find.text("Agent d'Atlas"), findsOneWidget);
  });

  testWidgets('maintenir une carte demande son illustration, pas une autre', (
    tester,
  ) async {
    final fakes = await pumpSpreadScan(
      tester,
      found: [_hit('id-1', 'Agent Phil Coulson'), _hit('id-2', "Agent d'Atlas")],
    );

    await tester.longPress(find.text("Agent d'Atlas"));
    await tester.pump();

    expect(
      fakes.printings.lastOracleId,
      'id-2',
      reason: "l'aperçu doit porter sur la carte maintenue ; se tromper de "
          'carte afficherait une illustration plausible et donc indétectable',
    );
    expect(
      fakes.printings.lastLang,
      'fr',
      reason: 'la langue trouvée évite de rapatrier les deux versions',
    );
  });

  testWidgets('seules les cartes cochées atteignent la collection', (
    tester,
  ) async {
    final fakes = await pumpSpreadScan(
      tester,
      found: [_hit('id-1', 'Agent Phil Coulson'), _hit('id-2', "Agent d'Atlas")],
    );

    // On décoche la première : c'est le geste de correction que l'écran existe
    // pour offrir, et le seul rempart contre une lecture erronée.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Ajouter'));
    await tester.pumpAndSettle();

    expect(
      fakes.collection.quantities.keys.map((k) => k.$1),
      ['id-2'],
      reason: 'une carte décochée qui serait tout de même écrite fausserait '
          'durablement les suggestions de decks',
    );
  });

  testWidgets('la quantité ajustée est celle qui est écrite', (tester) async {
    final fakes = await pumpSpreadScan(
      tester,
      found: [_hit('id-1', 'Agent Phil Coulson')],
    );

    await tester.tap(find.byTooltip('Un de plus'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Ajouter'));
    await tester.pumpAndSettle();

    expect(fakes.collection.quantities[('id-1', null)], 2);
  });

  testWidgets("l'édition choisie accompagne la carte jusqu'au dépôt", (
    tester,
  ) async {
    final fakes = await pumpSpreadScan(
      tester,
      found: [_hit('id-1', 'Agent Phil Coulson')],
    );

    // L'édition se choisit d'un geste, faute de pouvoir la deviner : la
    // géométrie d'une carte n'est reconstructible qu'à ±13 %, et au-delà de 5 %
    // une carte sur trois recevrait la mauvaise.
    await tester.tap(find.text("Préciser l'édition"));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Marvel').last);
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Ajouter'));
    await tester.pumpAndSettle();

    expect(
      fakes.collection.quantities.keys.single.$2,
      'print-msh',
      reason: "une édition affichée mais non transmise vaudrait pire que pas "
          "d'édition : la valorisation paraîtrait précise en restant fausse",
    );
  });

  group('le décompte des cartes trouvées', () {
    testWidgets('le nombre trouvé est annoncé après le scan', (tester) async {
      // **Ce que ce nombre sert à comparer.** L'utilisateur sait combien de
      // cartes il a posées sur la table ; l'écart lui dit s'il doit chercher
      // une carte manquante ou seulement vérifier des noms. Sans lui, une
      // carte ratée ne se remarque qu'en recomptant la liste — donc jamais.
      await pumpSpreadScan(
        tester,
        found: [
          _hit('id-1', 'Agent Phil Coulson'),
          _hit('id-2', "Agent d'Atlas"),
          _hit('id-3', 'Renforts de quartier'),
        ],
      );

      expect(find.text('3 cartes trouvées sur la photo'), findsOneWidget);
    });

    testWidgets('décocher une carte ne change pas le nombre trouvé', (
      tester,
    ) async {
      // Le décompte répond à « la photo a-t-elle tout vu ? », le bouton à
      // « qu'est-ce que je m'apprête à enregistrer ? ». Les confondre rendrait
      // le premier inutilisable dès la première case décochée — or c'est
      // précisément après avoir corrigé que l'on veut savoir s'il manque une
      // carte.
      await pumpSpreadScan(
        tester,
        found: [
          _hit('id-1', 'Agent Phil Coulson'),
          _hit('id-2', "Agent d'Atlas"),
        ],
      );

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      expect(find.text('2 cartes trouvées sur la photo'), findsOneWidget);
      expect(find.textContaining('Ajouter (1)'), findsOneWidget);
    });

    testWidgets("les doublons comptent pour ce qu'ils sont", (tester) async {
      // **Le défaut que ce test verrouille.** L'écran annonçait le nombre de
      // *lignes* : quinze cartes dont six doublons n'en faisaient que neuf, et
      // l'utilisateur croyait à six cartes perdues. C'est le nombre
      // d'exemplaires qui se compare à ce qu'il a posé sur la table.
      await pumpSpreadScan(
        tester,
        found: [
          _hit('id-1', 'Agent Phil Coulson'),
          _hit('id-2', "Agent d'Atlas"),
        ],
      );

      // Un exemplaire de plus sur la première carte : trois cartes posées.
      await tester.tap(find.byTooltip('Un de plus').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('3 cartes trouvées'), findsOneWidget);
      expect(find.textContaining('2 différentes'), findsOneWidget);
    });

    testWidgets("sans doublon, le second nombre ne s'affiche pas", (
      tester,
    ) async {
      // Répéter « 2 cartes trouvées, 2 différentes » n'apprend rien et encombre.
      await pumpSpreadScan(
        tester,
        found: [
          _hit('id-1', 'Agent Phil Coulson'),
          _hit('id-2', "Agent d'Atlas"),
        ],
      );

      expect(find.textContaining('2 cartes trouvées'), findsOneWidget);
      expect(find.textContaining('différentes'), findsNothing);
    });

    testWidgets('une seule carte se dit au singulier', (tester) async {
      await pumpSpreadScan(tester, found: [_hit('id-1', 'Agent Phil Coulson')]);

      expect(find.text('1 carte trouvée sur la photo'), findsOneWidget);
    });

    testWidgets('avant tout scan, la consigne de cadrage tient la place', (
      tester,
    ) async {
      // Le compteur remplace la consigne, il ne s'y ajoute pas : afficher
      // « 0 carte trouvée » avant même d'avoir photographié annoncerait un
      // échec là où il n'y a encore rien eu.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            photoSourceProvider.overrideWithValue(_FakePhotoSource()),
            collectionRepositoryProvider.overrideWithValue(
              FakeCollectionRepository(),
            ),
            printingRepositoryProvider.overrideWithValue(
              FakePrintingRepository(),
            ),
            scanServiceProvider.overrideWith(
              (ref) async => ScanService(
                ArtHashIndex.fromEntries(const []),
                FakeCardTextReader(),
                _FakeCatalogue(const []),
              ),
            ),
          ],
          child: const MaterialApp(home: SpreadScanScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Photographiez vos cartes'), findsOneWidget);
      expect(find.textContaining('trouvée'), findsNothing);
    });
  });
}
