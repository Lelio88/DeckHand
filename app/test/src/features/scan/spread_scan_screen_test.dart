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
///
/// **Il contient plus que ce que la photo a lu**, faute de quoi corriger une
/// ligne serait intestable : la correction consiste precisement a designer une
/// carte que la reconnaissance n'a pas proposee.
class _FakeCatalogue implements CardRepository {
  _FakeCatalogue(this.cards);

  final List<CardHit> cards;

  @override
  Future<List<CardHit>> search(
    String query, {
    int limit = 20,
    Game game = Game.magic,
    Iterable<String> types = const [],
  }) async {
    searched.add(query);
    return cards
        .where(
          (c) => c.matchedName.toLowerCase().contains(query.toLowerCase()),
        )
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<List<CardHit>> byOracleIds(
    List<String> oracleIds, {
    List<String> prints = const [],
  }) async => cards;

  /// Noms cherches via la feuille de correction, dans l'ordre.
  final List<String> searched = [];

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
          if (card.matchedName.toLowerCase() == name.toLowerCase()) name: card,
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
    String game = 'magic',
  }) async => CapturedPhoto(bytes: Uint8List(0), path: 'etalement.jpg');
}

CardHit _hit(
  String oracleId,
  String name, {
  String lang = 'fr',
  int owned = 0,
}) => CardHit(
  oracleId: oracleId,
  name: name,
  matchedName: name,
  matchedLang: lang,
  legalPauper: true,
  legalModern: true,
  legalCommander: true,
  owned: owned,
  score: 1,
);

/// Monte l'écran, déclenche un scan, et rend les doublures pour inspection.
Future<
  ({
    FakeCollectionRepository collection,
    FakePrintingRepository printings,
    _FakeCatalogue catalogue,
  })
>
pumpSpreadScan(
  WidgetTester tester, {
  required List<CardHit> found,
  /// Cartes presentes au catalogue sans avoir ete lues sur la photo — celles
  /// qu'une correction ou un ajout a la main peut aller chercher.
  List<CardHit> alsoInCatalogue = const [],
  Map<String, CardPrinting> sole = const {},
  Object? soleError,
}) async {
  final collection = FakeCollectionRepository();
  final printings = FakePrintingRepository()
    ..printings = const [
      CardPrinting(
        printId: 'print-msh',
        setCode: 'msh',
        setName: 'Marvel',
        lang: 'fr',
      ),
    ]
    ..sole = sole
    ..soleError = soleError;
  final cards = _FakeCatalogue([...found, ...alsoInCatalogue]);
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
        // La feuille de correction cherche par ce dépôt-là, et non par le
        // service de scan : sans la doublure, elle tombe sur le vrai client
        // Supabase, jamais initialisé sous `flutter test`.
        cardRepositoryProvider.overrideWithValue(cards),
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

  return (collection: collection, printings: printings, catalogue: cards);
}

/// Ouvre la feuille de recherche depuis la ligne nommee [from], y cherche
/// [query], et retient la carte [pick]. Sans [from], c'est un ajout a la main.
///
/// Le champ est pre-rempli par le nom lu : on le remplace, comme le ferait
/// quelqu'un qui vient de constater que la lecture est fausse.
Future<void> _pickCard(
  WidgetTester tester, {
  String? from,
  required String query,
  required String pick,
}) async {
  await tester.tap(
    from == null ? find.text('Saisir une carte oubliée') : find.text(from),
  );
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).last, query);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();

  await tester.tap(find.text(pick).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('les cartes repérées sont proposées', (tester) async {
    await pumpSpreadScan(
      tester,
      found: [
        _hit('id-1', 'Agent Phil Coulson'),
        _hit('id-2', "Agent d'Atlas"),
      ],
    );

    expect(find.text('Agent Phil Coulson'), findsOneWidget);
    expect(find.text("Agent d'Atlas"), findsOneWidget);
  });

  testWidgets('maintenir une carte demande son illustration, pas une autre', (
    tester,
  ) async {
    final fakes = await pumpSpreadScan(
      tester,
      found: [
        _hit('id-1', 'Agent Phil Coulson'),
        _hit('id-2', "Agent d'Atlas"),
      ],
    );

    await tester.longPress(find.text("Agent d'Atlas"));
    await tester.pump();

    expect(
      fakes.printings.lastOracleId,
      'id-2',
      reason:
          "l'aperçu doit porter sur la carte maintenue ; se tromper de "
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
      found: [
        _hit('id-1', 'Agent Phil Coulson'),
        _hit('id-2', "Agent d'Atlas"),
      ],
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
      reason:
          'une carte décochée qui serait tout de même écrite fausserait '
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
      reason:
          "une édition affichée mais non transmise vaudrait pire que pas "
          "d'édition : la valorisation paraîtrait précise en restant fausse",
    );
  });

  group("l'édition unique se précise toute seule", () {
    // **Ce que ce groupe protège.** Quatre cartes du catalogue sur dix n'ont
    // qu'une édition. Faire ouvrir pour elles une liste d'un seul élément, vingt
    // fois de suite, était le geste le plus coûteux de l'écran — et le plus
    // vide, puisqu'aucune information n'en sortait que la carte ne portait déjà.
    const soleMar = CardPrinting(
      printId: 'print-mar-43',
      setCode: 'mar',
      setName: 'Marvel Universe',
      collectorNumber: '43',
      lang: 'en',
      hasNonfoil: true,
      hasFoil: true,
    );

    testWidgets('elle est retenue sans aucun geste', (tester) async {
      final fakes = await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Ne bougez pas !')],
        sole: const {'id-1': soleMar},
      );

      // Extension **et** numéro : c'est ce que porte le bas de la carte, donc
      // le seul moyen de vérifier d'un coup d'œil une édition qu'on n'a pas
      // choisie soi-même.
      expect(find.text('MAR #43'), findsOneWidget);

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(fakes.collection.quantities.keys.single.$2, 'print-mar-43');
    });

    testWidgets('la carte à plusieurs éditions reste à préciser', (
      tester,
    ) async {
      final fakes = await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Ne bougez pas !')],
      );

      expect(
        find.text("Préciser l'édition"),
        findsOneWidget,
        reason:
            'sans réponse unique, choisir à la place de l\'utilisateur '
            'reviendrait à inventer une édition',
      );

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();
      expect(fakes.collection.quantities.keys.single.$2, isNull);
    });

    testWidgets('la finition se règle sans ouvrir le sélecteur', (
      tester,
    ) async {
      final fakes = await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Ne bougez pas !')],
        sole: const {'id-1': soleMar},
      );

      await tester.tap(find.text('Brillant'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(
        fakes.collection.added.single.isFoil,
        isTrue,
        reason:
            'un brillant enregistré comme normal sous-évalue la collection '
            'du simple au triple',
      );
    });

    testWidgets("une édition qui n'existe qu'en brillante l'est d'office", (
      tester,
    ) async {
      final fakes = await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Ne bougez pas !')],
        sole: const {
          'id-1': CardPrinting(
            printId: 'print-bundle',
            setCode: 'mar',
            collectorNumber: '43',
            lang: 'en',
            hasNonfoil: false,
            hasFoil: true,
          ),
        },
      );

      await tester.tap(find.textContaining('Ajouter'));
      await tester.pumpAndSettle();

      expect(
        fakes.collection.added.single.isFoil,
        isTrue,
        reason:
            'enregistrer sa jumelle normale reviendrait à inventer un '
            'exemplaire qui n\'a jamais été imprimé',
      );
    });

    testWidgets('une panne du catalogue laisse la liste intacte', (
      tester,
    ) async {
      // Le préremplissage est un confort ; son échec doit rendre l'écran tel
      // qu'il était avant, jamais effacer un scan qui a réussi.
      await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Ne bougez pas !'), _hit('id-2', "Agent d'Atlas")],
        soleError: Exception('catalogue injoignable'),
      );

      expect(find.text('Ne bougez pas !'), findsOneWidget);
      expect(find.text("Agent d'Atlas"), findsOneWidget);
      expect(find.text("Préciser l'édition"), findsNWidgets(2));
    });

    testWidgets('les cartes sont demandées en un seul lot', (tester) async {
      final fakes = await pumpSpreadScan(
        tester,
        found: [
          _hit('id-1', 'Ne bougez pas !'),
          _hit('id-2', "Agent d'Atlas"),
          _hit('id-3', 'Renforts de quartier'),
        ],
      );

      expect(
        fakes.printings.soleAsked,
        ['id-1', 'id-2', 'id-3'],
        reason:
            'une requête par carte coûtait 77 s sur dix-sept cartes ; la '
            'leçon vaut ici comme pour la recherche par lot',
      );
    });
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

  testWidgets('la ligne tient sur un écran étroit, nom long et pastille', (
    tester,
  ) async {
    // **Le défaut le plus récurrent du projet, et celui qu'aucune analyse ne
    // voit.** Une largeur ne se déduit pas du code : le sélecteur de mode
    // débordait de 6,2 px, la légende du calque de 49, et les deux ont été
    // trouvés à l'oeil. Un débordement leve une exception sous `flutter test`,
    // donc un simple montage suffit à le tenir — à condition de choisir le pire
    // cas : un téléphone étroit, un nom long, et la pastille qui prend la place.
    //
    // **360 et non 320**, parce que la police des tests rend chaque glyphe
    // comme un carré plein de la hauteur du texte : « Déjà 12 » y réclame
    // 80,5 px quand une vraie police en prend la moitié. Viser 320 sous cette
    // police reviendrait à concevoir pour une largeur qui n'existe pas, et
    // l'aperçu a montré ce que ça coûte — un nom amputé à « Archi… » avec la
    // moitié de la ligne vide à côté. 360 est la plus étroite des largeurs
    // Android courantes.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpSpreadScan(
      tester,
      found: [
        _hit(
          'id-1',
          'Archimage Elminster de Valombre le Prolixe',
          owned: 12,
        ),
      ],
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Déjà 12'), findsOneWidget);
  });

  group('ce qui est déjà en collection', () {
    // **La question qu'on se pose carte en main.** Une collection se saisit en
    // plusieurs séances : sans ce chiffre, rien ne distingue la carte qui
    // complète un jeu de quatre de celle qui en ouvre un, et l'on ressaisit ce
    // qu'on possède déjà.
    testWidgets('une carte déjà possédée le dit', (tester) async {
      await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Agent Phil Coulson', owned: 3)],
      );

      expect(find.text('Déjà 3'), findsOneWidget);
    });

    testWidgets("une carte qu'on ne possède pas ne dit rien", (tester) async {
      // « Déjà 0 » serait du bruit sur dix-sept lignes, et le mot « Déjà »
      // désigne un stock : il n'a rien à dire quand il n'y en a pas.
      await pumpSpreadScan(tester, found: [_hit('id-1', 'Agent Phil Coulson')]);

      expect(find.textContaining('Déjà'), findsNothing);
    });
  });

  group('corriger une ligne mal reconnue', () {
    // **Ce que décocher ne remplaçait pas.** Une carte mal lue est sur la
    // table : la décocher la perd, et elle devait alors être ressaisie
    // ailleurs — donc, le plus souvent, oubliée.
    testWidgets('la carte retenue remplace celle qui avait été lue', (
      tester,
    ) async {
      final fakes = await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Agent Phil Coulson')],
        alsoInCatalogue: [_hit('id-2', 'Ancêtre Vénérable')],
      );

      await _pickCard(
        tester,
        from: 'Agent Phil Coulson',
        query: 'Ancêtre',
        pick: 'Ancêtre Vénérable',
      );
      await tester.tap(find.textContaining('Ajouter ('));
      await tester.pumpAndSettle();

      expect(
        fakes.collection.quantities.keys.map((k) => k.$1),
        ['id-2'],
        reason:
            "une correction qui n'atteindrait pas le dépôt aurait l'air juste "
            "à l'écran et enregistrerait la carte lue de travers",
      );
    });

    testWidgets("l'édition de la carte remplacée ne la suit pas", (
      tester,
    ) async {
      final fakes = await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Agent Phil Coulson')],
        alsoInCatalogue: [_hit('id-2', 'Ancêtre Vénérable')],
      );

      // On précise l'édition, puis on s'aperçoit que la carte est fausse.
      await tester.tap(find.text("Préciser l'édition"));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Marvel').last);
      await tester.pumpAndSettle();

      await _pickCard(
        tester,
        from: 'Agent Phil Coulson',
        query: 'Ancêtre',
        pick: 'Ancêtre Vénérable',
      );
      await tester.tap(find.textContaining('Ajouter ('));
      await tester.pumpAndSettle();

      expect(
        fakes.collection.quantities.keys.single.$2,
        isNull,
        reason:
            "garder l'extension de la carte précédente enregistrerait un "
            "tirage qui n'existe pas, et la valorisation paraîtrait précise "
            "en restant fausse",
      );
    });

    testWidgets('la quantité ajustée survit au remplacement', (tester) async {
      // La quantité compte des cartons posés sur la table ; corriger un nom ne
      // les fait pas disparaître.
      final fakes = await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Agent Phil Coulson')],
        alsoInCatalogue: [_hit('id-2', 'Ancêtre Vénérable')],
      );

      await tester.tap(find.byTooltip('Un de plus'));
      await tester.pumpAndSettle();
      await _pickCard(
        tester,
        from: 'Agent Phil Coulson',
        query: 'Ancêtre',
        pick: 'Ancêtre Vénérable',
      );
      await tester.tap(find.textContaining('Ajouter ('));
      await tester.pumpAndSettle();

      expect(fakes.collection.quantities[('id-2', null)], 2);
    });

    testWidgets('refermer la feuille sans choisir ne change rien', (
      tester,
    ) async {
      await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Agent Phil Coulson')],
        alsoInCatalogue: [_hit('id-2', 'Ancêtre Vénérable')],
      );

      await tester.tap(find.text('Agent Phil Coulson'));
      await tester.pumpAndSettle();
      // Hors de la feuille : on renonce.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      expect(find.text('Agent Phil Coulson'), findsOneWidget);
    });
  });

  group('ajouter une carte que la photo a manquée', () {
    testWidgets('elle atteint la collection', (tester) async {
      final fakes = await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Agent Phil Coulson')],
        alsoInCatalogue: [_hit('id-2', 'Ancêtre Vénérable')],
      );

      await _pickCard(tester, query: 'Ancêtre', pick: 'Ancêtre Vénérable');
      await tester.tap(find.textContaining('Ajouter ('));
      await tester.pumpAndSettle();

      expect(
        fakes.collection.quantities.keys.map((k) => k.$1).toList()..sort(),
        ['id-1', 'id-2'],
      );
    });

    testWidgets('elle ne gonfle pas le nombre trouvé sur la photo', (
      tester,
    ) async {
      // **Le compteur est le témoin de ce que la reconnaissance a vu.** Y
      // fondre une carte ajoutée à la main effacerait l'écart entre la table
      // et la photo, qui est exactement ce qu'il sert à montrer.
      await pumpSpreadScan(
        tester,
        found: [_hit('id-1', 'Agent Phil Coulson')],
        alsoInCatalogue: [_hit('id-2', 'Ancêtre Vénérable')],
      );

      await _pickCard(tester, query: 'Ancêtre', pick: 'Ancêtre Vénérable');

      expect(
        find.textContaining('1 carte trouvée sur la photo'),
        findsOneWidget,
      );
      expect(find.textContaining('+1 à la main'), findsOneWidget);
      expect(
        find.textContaining('Ajouter (2)'),
        findsOneWidget,
        reason:
            'le bouton décompte la sélection, lui, et doit donc inclure ce '
            "qu'on vient d'ajouter",
      );
    });
  });
}
