/// La langue d'affichage du nom des cartes.
///
/// **Ce que ces tests protègent.** Le nom traduit est choisi par cinq fonctions
/// SQL qui lisent `my_display_lang()` ; côté application, tout se joue au
/// **premier lancement** — un compte qui n'a jamais choisi reçoit la langue de
/// son appareil, et ce geste ne doit se produire qu'une fois. Les deux erreurs
/// qui ne se verraient pas sont symétriques : écrire par-dessus un choix
/// explicite, et ne rien écrire du tout.
///
/// Les assertions portent sur [resolveDisplayLang] plutôt que sur le provider :
/// la règle est là, le provider n'est que du câblage. L'éprouver à travers lui
/// obligerait à simuler un flux de session, donc à mesurer Riverpod.
library;

import 'dart:ui';

import 'package:deckhand/src/config/display_lang.dart';
import 'package:deckhand/src/features/account/data/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fakes.dart';

void main() {
  group('la langue de l\'appareil', () {
    test('un code connu désigne sa langue', () {
      expect(CardLang.fromLocale(const Locale('de')), CardLang.german);
      expect(CardLang.fromLocale(const Locale('ja')), CardLang.japanese);
      expect(CardLang.fromLocale(const Locale('fr', 'BE')), CardLang.french);
    });

    test('un code sans catalogue retombe sur l\'anglais', () {
      // **Et non sur le français**, l'ancien défaut codé en dur : un téléphone
      // en suédois n'a rien demandé de tel, et le nom oracle anglais existe
      // pour toute carte.
      expect(CardLang.fromLocale(const Locale('sv')), CardLang.english);
      expect(CardLang.fromLocale(const Locale('nl')), CardLang.english);
    });

    test('le chinois se départage par l\'écriture, puis par le pays', () {
      // `zh` seul ne dit pas lequel des deux catalogues viser.
      expect(
        CardLang.fromLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ),
        CardLang.chineseTraditional,
      );
      expect(
        CardLang.fromLocale(const Locale('zh', 'TW')),
        CardLang.chineseTraditional,
      );
      expect(
        CardLang.fromLocale(const Locale('zh', 'CN')),
        CardLang.chineseSimplified,
      );
    });

    test('les langues sans couverture réelle ne sont pas proposées', () {
      // Le catalogue porte dix-huit codes, dont sept ne comptent qu'une
      // poignée de cartes de série limitée. Les offrir ferait miroiter un
      // affichage qui resterait anglais partout ailleurs.
      final codes = CardLang.values.map((l) => l.code).toSet();
      expect(codes.contains('la'), isFalse, reason: 'latin');
      expect(codes.contains('ph'), isFalse, reason: 'phyrexien');
      expect(codes.contains('qya'), isFalse, reason: 'quenya');
    });

    test('chaque langue annonce ce qu\'elle couvre', () {
      // **Le menu dit, il ne masque pas.** L'autre option etait de n'offrir que
      // les langues du jeu affiche ; elle rendait le reglage mouvant. On montre
      // tout, a condition que chaque ligne dise sa portee — sans quoi choisir
      // « Japonais » promet un affichage que seul Magic tient.
      for (final lang in CardLang.values) {
        expect(lang.coverage, isNotEmpty, reason: lang.label);
      }
      expect(CardLang.english.coverage, contains('tous'));
      expect(CardLang.japanese.coverage, 'Magic');
    });

    test('les langues vont de la mieux couverte a la moins bien', () {
      // **L'ordre est l'information**, et il est écrit ici plutôt que déduit.
      // Une première version le dérivait du nombre de virgules dans `coverage`
      // et comptait « tous les jeux » pour une seule couverture : un indicateur
      // qui se trompe sur le cas le plus large ne mesure rien.
      //
      // Trier par alphabet mettrait l'allemand devant l'anglais, donc une
      // langue partielle devant la seule qui couvre tout.
      expect(CardLang.values.map((l) => l.code).toList(), [
        'en', // tous les jeux
        'fr', // quatre catalogues
        'de', 'it', 'pt', // trois
        'es', // deux
        'ja', 'zhs', 'zht', 'ru', 'ko', // Magic seul
      ]);
    });

    test('un code inconnu se distingue d\'un choix absent', () {
      // `fromCode` rend `null` plutôt que l'anglais : seul l'appelant sait si
      // « jamais renseigné » doit déclencher une écriture.
      expect(CardLang.fromCode(null), isNull);
      expect(CardLang.fromCode('klingon'), isNull);
      expect(CardLang.fromCode('ja'), CardLang.japanese);
    });
  });

  group('le premier lancement', () {
    const suedois = Locale('sv');
    const japonais = Locale('ja');

    test('sans session, rien n\'est écrit', () async {
      final depot = FakeProfileRepository();

      final rendue = await resolveDisplayLang(
        depot,
        connecte: false,
        appareil: japonais,
      );

      expect(rendue, CardLang.japanese);
      expect(
        depot.langsSaved,
        isEmpty,
        reason: 'un visiteur non connecté n\'a pas de profil à renseigner',
      );
    });

    test('rien en base : la langue de l\'appareil est écrite, une fois',
        () async {
      // Les deux erreurs symétriques que ce test ferme : ne rien écrire, et
      // écrire plusieurs fois. Seul un compte permet de les distinguer.
      final depot = FakeProfileRepository();

      final rendue = await resolveDisplayLang(
        depot,
        connecte: true,
        appareil: japonais,
      );

      expect(rendue, CardLang.japanese);
      expect(depot.langsSaved, [CardLang.japanese]);
    });

    test('un choix déjà enregistré gagne, et rien n\'est réécrit', () async {
      final depot = FakeProfileRepository()..lang = 'ja';

      final rendue = await resolveDisplayLang(
        depot,
        connecte: true,
        appareil: const Locale('fr'),
      );

      expect(rendue, CardLang.japanese);
      expect(depot.langsSaved, isEmpty);
    });

    test('un code illisible en base vaut « rien de choisi »', () async {
      // Préférence écrite par une version plus récente, ou valeur corrompue :
      // la traiter comme un choix figerait l'affichage sur une langue que le
      // serveur ne connaît pas.
      final depot = FakeProfileRepository()..lang = 'klingon';

      final rendue = await resolveDisplayLang(
        depot,
        connecte: true,
        appareil: suedois,
      );

      expect(
        rendue,
        CardLang.english,
        reason: 'le suédois n\'a pas de catalogue',
      );
      expect(depot.langsSaved, [CardLang.english]);
    });

    test('un enregistrement qui échoue laisse l\'affichage juste', () async {
      // Hors ligne au premier lancement : la langue déduite sert quand même
      // cette session. Propager l'erreur priverait tous les écrans de leur nom
      // traduit pour une préférence de confort.
      final depot = FakeProfileRepository()
        ..saveLangError = Exception('hors ligne');

      final rendue = await resolveDisplayLang(
        depot,
        connecte: true,
        appareil: japonais,
      );

      expect(rendue, CardLang.japanese);
      expect(depot.lang, isNull, reason: 'rien n\'a pu être écrit');
    });
  });
}
