/// Accès aux éditions d'une carte.
///
/// La liste arrive **par pages, et reste cherchable** : certaines cartes dépassent
/// le millier d'impressions, et tout rapatrier d'un coup serait aussi lent
/// qu'inutilisable. Le serveur remonte les éditions déjà possédées en tête, puis
/// les plus récentes ; l'application charge la suite quand on la demande, par
/// [printingsPageSize] éditions.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/request_timeout.dart';
import '../domain/card_printing.dart';
import '../domain/printing_era.dart';

class PrintingRepository {
  const PrintingRepository(this._client);

  final SupabaseClient _client;

  /// Éditions d'une carte, une ligne par édition, [lang] servie en priorité.
  ///
  /// La langue est une **préférence, pas un filtre**. Elle supprime un doublon
  /// systématique — chaque édition figurait deux fois, en français et en
  /// anglais, alors qu'on tient la carte trouvée par son nom français — mais
  /// elle ne fait jamais disparaître une édition. Scryfall ne catalogue pas
  /// toutes les impressions dans toutes les langues : exclure les autres
  /// langues cachait à un joueur l'édition qu'il avait en main.
  ///
  /// [era] restreint à une tranche d'années de sortie — un repli pour l'édition
  /// dont on connaît l'époque mais pas le nom exact d'extension, le cas des
  /// terrains de base et autres cartes mille fois réimprimées : sans lui,
  /// l'ordre par sortie la plus récente place les plus anciennes derrière des
  /// pages entières de réimpressions.
  ///
  /// [offset] saute les éditions des pages déjà chargées. [foil] filtre la
  /// finition côté serveur, `null` rendant tout : filtrée après la coupe, une
  /// page ne compterait plus ce qu'elle promet, et la pagination se perdrait.
  Future<List<CardPrinting>> forCard(
    String oracleId, {
    String? query,
    int limit = printingsPageSize,
    int offset = 0,
    String? lang,
    PrintingEra era = PrintingEra.all,
    bool? foil,
  }) async {
    final rows = await _client
        .rpc<List<dynamic>>(
          'card_printings',
          params: {
            'p_oracle_id': oracleId,
            'p_query': (query ?? '').trim().isEmpty ? null : query!.trim(),
            'p_limit': limit,
            'p_lang': lang,
            'p_from_year': era.fromYear,
            'p_to_year': era.toYear,
            'p_offset': offset,
            'p_finish': switch (foil) {
              null => null,
              true => 'foil',
              false => 'nonfoil',
            },
          },
        )
        .timedOut();
    return rows
        .cast<Map<String, dynamic>>()
        .map(CardPrinting.fromJson)
        .toList(growable: false);
  }

  /// Pour chaque carte du lot n'ayant qu'une seule édition, cette édition.
  ///
  /// Les cartes qui en comptent plusieurs sont absentes du résultat : il n'y a
  /// rien à choisir à leur place. Quatre cartes du catalogue sur dix n'ont
  /// qu'une édition — autant de gestes qu'il est inutile de demander.
  ///
  /// **En un seul aller-retour**, comme la recherche par lot : une requête par
  /// carte coûterait ici les mêmes secondes qu'elle coûtait au scan.
  Future<Map<String, CardPrinting>> soleEditions(
    Iterable<String> oracleIds, {
    String? lang,
  }) async {
    final ids = oracleIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};

    final rows = await _client
        .rpc<List<dynamic>>(
          'sole_editions',
          params: {'p_oracle_ids': ids, 'p_lang': lang},
        )
        .timedOut();
    return {
      for (final row in rows.cast<Map<String, dynamic>>())
        row['oracle_id'] as String: CardPrinting.fromJson(row),
    };
  }
}

final printingRepositoryProvider = Provider<PrintingRepository>(
  (ref) => PrintingRepository(Supabase.instance.client),
);

/// Nombre d'éditions par page.
///
/// Soixante couvre en une page toutes les cartes Magic sauf dix-neuf — les cinq
/// terrains de base, près de 900 éditions chacun, puis Sol Ring (135) et
/// quelques autres. Le temps serveur ne dépend pas de ce nombre (mesuré :
/// 0,7 s pour la Forêt à 60 comme à 200 lignes), seul le volume rapatrié.
const int printingsPageSize = 60;

/// Une page d'éditions : la carte, ses filtres, et le rang de la page.
typedef PrintingsPage = ({
  String oracleId,
  String query,
  String? lang,
  PrintingEra era,
  bool? foil,
  int page,
});

/// Une page d'éditions d'une carte.
///
/// `family` sur la page entière : deux cartes distinctes ne partagent pas de
/// résultat, changer un filtre relance la requête, et les pages déjà chargées
/// restent en cache pendant qu'arrive la suivante.
final printingsProvider =
    FutureProvider.family<List<CardPrinting>, PrintingsPage>(
      (ref, args) => ref
          .watch(printingRepositoryProvider)
          .forCard(
            args.oracleId,
            query: args.query,
            lang: args.lang,
            era: args.era,
            foil: args.foil,
            offset: args.page * printingsPageSize,
          ),
    );
