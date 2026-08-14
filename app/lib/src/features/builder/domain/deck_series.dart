/// Plusieurs decks jouables en même temps, avec une seule collection.
///
/// **Ce que la série ajoute au constructeur de decks.** [DeckBuilder] répond à
/// « que puis-je jouer ? ». La série répond à « combien de decks puis-je poser
/// sur la table en même temps ? », et c'est une autre question : les decks
/// doivent être **disjoints**. Un exemplaire employé par le premier ne peut pas
/// resservir au second — sinon la réponse ne se vérifie pas, elle s'effondre dès
/// qu'on sort les cartes de la boîte.
///
/// **Le partage est glouton et séquentiel, et il faut le dire.** Le premier deck
/// se sert dans toute la collection, le second dans ce qui reste. Les decks sont
/// donc de qualité décroissante, et la série ne prétend pas répartir
/// équitablement : elle prétend que chacun des decks rendus est complet et
/// conforme au corpus. Un partage équilibré est un problème d'optimisation d'une
/// autre nature, qu'on n'ouvrira pas sans l'avoir mesuré.
///
/// **Elle s'arrête en disant pourquoi**, et c'est la moitié de son utilité.
/// Rendre deux decks quand on en demandait quatre n'apprend rien ; rendre deux
/// decks *et* le troisième tel qu'il aurait été — avec ses six cartes
/// manquantes — permet d'aller acheter les six cartes. Le deck refusé est donc
/// conservé dans [DeckSeries.refused].
///
/// **Le refus a une mesure, pas une opinion.** Un deck est écarté quand il
/// manque de cartes, ou quand un rôle s'écarte de sa cible au-delà de l'écart
/// interquartile que porte [Quota.spread] — c'est-à-dire au-delà de la bande où
/// tient la moitié des decks réels du corpus. Refuser sur un seuil inventé
/// serait un jugement ; refuser sur celui-là est un constat.
///
/// Exemple canonique :
///
///     final serie = const DeckSeriesBuilder().build(collection, limit: 4);
///     for (final deck in serie.decks) { /* jouables tous ensemble */ }
///     switch (serie.stop) {
///       case SeriesStop.limitReached: /* les quatre y sont */
///       case SeriesStop.incomplete:   /* il manque serie.refused!.diagnosis.short cartes */
///       case SeriesStop.offBlueprint: /* constructible mais trop bancal */
///       case SeriesStop.noCommander:  /* plus de général disponible */
///     }
library;

import 'buildable_card.dart';
import 'deck_blueprint.dart';
import 'deck_builder.dart';

/// Pourquoi la série s'est arrêtée.
enum SeriesStop {
  /// Le nombre de decks demandé a été atteint. Il y en a peut-être d'autres.
  limitReached,

  /// La collection ne fournit plus de quoi remplir un deck entier.
  incomplete,

  /// Le deck suivant se remplissait, mais s'écartait du corpus au-delà de ce
  /// que les decks réels s'autorisent.
  offBlueprint,

  /// Plus aucun général disponible, dans un format qui en exige un.
  noCommander,
}

/// Des decks jouables ensemble, et la raison pour laquelle il n'y en a pas plus.
class DeckSeries {
  const DeckSeries({
    required this.decks,
    required this.stop,
    this.refused,
  });

  /// Les decks retenus, du meilleur au moins bon. Tous complets, tous conformes,
  /// et deux à deux disjoints.
  final List<BuiltDeck> decks;

  final SeriesStop stop;

  /// Le deck qui a fait s'arrêter la série, quand il y en a un.
  ///
  /// Il est **conservé plutôt que jeté** : c'est lui qui porte ce qui manquait,
  /// et un utilisateur à qui l'on répond « pas de quatrième deck » sans dire à
  /// combien de cartes il était n'a rien appris.
  final BuiltDeck? refused;

  bool get isEmpty => decks.isEmpty;
}

class DeckSeriesBuilder {
  const DeckSeriesBuilder({this.builder = const DeckBuilder()});

  final DeckBuilder builder;

  DeckBlueprint get blueprint => builder.blueprint;

  /// Construit jusqu'à [limit] decks disjoints avec [collection].
  ///
  /// [first] impose le général du **premier** deck, les suivants étant choisis
  /// par la série. C'est ce que l'écran demande : l'utilisateur a déjà désigné
  /// son général, et lui en substituer un autre au motif qu'il ouvre davantage
  /// serait le contredire sans le dire.
  DeckSeries build(
    List<BuildableCard> collection, {
    int limit = 4,
    BuildableCard? first,
  }) {
    final decks = <BuiltDeck>[];
    final usedCommanders = <String>{};
    var pool = [...collection];

    while (decks.length < limit) {
      BuildableCard? commander;
      var available = pool;

      if (blueprint.needsCommander) {
        final candidates = builder
            .commanders(pool)
            .where((c) => !usedCommanders.contains(c.oracleId))
            .toList();
        if (candidates.isEmpty) {
          return DeckSeries(decks: decks, stop: SeriesStop.noCommander);
        }
        // Le général imposé passe devant, au premier tour seulement.
        commander = decks.isEmpty && first != null ? first : candidates.first;
        // **Les généraux des decks suivants sont mis de côté.** Sans cela, le
        // premier deck mange les créatures légendaires comme n'importe quelle
        // créature, et la série s'arrête au tour suivant faute de général — ce
        // qu'un test a montré avant qu'on y pense. On en réserve autant qu'il
        // reste de decks à faire, et pas davantage : chaque général réservé est
        // une créature de moins pour le deck en cours.
        final reserved = candidates
            .where((c) => c.oracleId != commander!.oracleId)
            .take(limit - decks.length - 1)
            .map((c) => c.oracleId)
            .toSet();
        if (reserved.isNotEmpty) {
          available = pool
              .where((c) => !reserved.contains(c.oracleId))
              .toList();
        }
      }

      final deck = builder.build(available, commander);

      if (!deck.diagnosis.isComplete) {
        return DeckSeries(
          decks: decks,
          stop: SeriesStop.incomplete,
          refused: deck,
        );
      }
      if (!meetsBlueprint(deck)) {
        return DeckSeries(
          decks: decks,
          stop: SeriesStop.offBlueprint,
          refused: deck,
        );
      }

      decks.add(deck);
      if (commander != null) usedCommanders.add(commander.oracleId);
      pool = _withoutConsumed(pool, deck);
    }

    return DeckSeries(decks: decks, stop: SeriesStop.limitReached);
  }

  /// Le deck tient-il dans la bande que le corpus s'autorise ?
  ///
  /// Seul le **manque** se reproche : un deck qui a plus de créatures que la
  /// cible reste cohérent, et le lui refuser reviendrait à exiger une médiane
  /// que la moitié du corpus ne respecte pas non plus.
  bool meetsBlueprint(BuiltDeck deck) {
    for (final entry in blueprint.roles.entries) {
      final gap = deck.diagnosis.roleGaps[entry.key] ?? 0;
      if (gap <= 0) continue;
      final tolerance = (entry.value.spread * blueprint.size / 100).round();
      if (gap > tolerance) return false;
    }
    return true;
  }

  /// [pool] moins ce que [deck] a consommé.
  ///
  /// **Les terrains de base n'y figurent pas**, et c'est voulu : ils ne viennent
  /// pas de la collection. On ne les achète pas, on les prend dans la boîte —
  /// donc ils ne s'épuisent jamais et ne limitent jamais le nombre de decks.
  /// Ce qui s'épuise, ce sont les sorts et les terrains non basiques.
  List<BuildableCard> _withoutConsumed(
    List<BuildableCard> pool,
    BuiltDeck deck,
  ) {
    final taken = <String, int>{};
    void take(BuildableCard card) =>
        taken[card.oracleId] = (taken[card.oracleId] ?? 0) + 1;

    if (deck.commander != null) take(deck.commander!);
    deck.spells.forEach(take);
    deck.lands.forEach(take);
    deck.extra.forEach(take);

    final left = <BuildableCard>[];
    for (final card in pool) {
      final used = taken[card.oracleId] ?? 0;
      if (used == 0) {
        left.add(card);
        continue;
      }
      // Une même ligne de collection porte plusieurs exemplaires ; le deck en a
      // pris `used`, les autres restent disponibles pour les decks suivants.
      final rest = card.quantity - used;
      taken[card.oracleId] = 0;
      if (rest > 0) left.add(card.withQuantity(rest));
    }
    return left;
  }
}
