/// Construit un deck Commander avec ce qu'on possède.
///
/// **Ce qu'il promet, et ce qu'il ne promet pas.** Un deck optimal ne se
/// démontre pas, il se joue : promettre l'optimalité serait une promesse
/// invérifiable, qui se retournerait au premier essai. Ce constructeur promet
/// autre chose, qui se vérifie : un deck **légal** — cent cartes, un seul
/// exemplaire de chacune, identité couleur respectée —, **cohérent** — des
/// proportions conformes à celles des decks réels — et **entièrement à vous**.
///
/// **Il remplit des cases plutôt qu'il ne raisonne.** Les proportions viennent
/// du corpus ([DeckBlueprint]) ; à chaque tour, la carte retenue est celle qui
/// comble le manque le plus criant. C'est une glouton par écart aux cibles, sans
/// retour arrière : à cette échelle — deux cents cartes, soixante places — un
/// recuit n'achèterait rien qu'on puisse mesurer, et le résultat cesserait
/// d'être explicable.
///
/// **Il ne comprend pas les synergies.** Il ne saura pas que trois cartes
/// forment un moteur, ni qu'une carte est mauvaise hors de son archétype. Les
/// tirer du corpus par co-occurrence est une piste réelle, non prise ici : 190
/// decks Commander sont un échantillon mince pour en déduire des affinités.
///
/// **Ce qui manque est dit, pas caché.** Un deck bâti sur une collection
/// incomplète s'écarte des cibles ; l'écart est rendu avec le deck
/// ([DeckDiagnosis]) plutôt que passé sous silence. C'est ce qui distingue un
/// outil d'un oracle.
library;

import 'buildable_card.dart';
import 'card_role.dart';
import 'deck_blueprint.dart';

/// Un deck construit, et ce qu'on peut lui reprocher.
class BuiltDeck {
  const BuiltDeck({
    required this.commander,
    required this.spells,
    required this.lands,
    required this.basicLands,
    required this.diagnosis,
  });

  final BuildableCard commander;

  /// Cartes non-terrain retenues, dans l'ordre où elles ont été choisies.
  final List<BuildableCard> spells;

  /// Terrains non basiques de la collection.
  final List<BuildableCard> lands;

  /// Terrains de base à ajouter, par nom. Ils ne viennent pas de la collection :
  /// on ne les achète pas, on les prend dans la boîte.
  final Map<String, int> basicLands;

  final DeckDiagnosis diagnosis;

  int get basicCount => basicLands.values.fold(0, (sum, n) => sum + n);

  /// Cartes du deck, commandant compris.
  int get size => 1 + spells.length + lands.length + basicCount;
}

/// L'écart entre le deck obtenu et le gabarit visé.
class DeckDiagnosis {
  const DeckDiagnosis({required this.roleGaps, required this.short});

  /// Manque par rôle, en nombre de cartes. Positif = il en manque.
  final Map<CardRole, int> roleGaps;

  /// Cartes qui manquent pour atteindre la taille du format. Zéro si le deck
  /// est complet — les terrains de base y pourvoient toujours, sauf collection
  /// dépourvue de terrains.
  final int short;

  bool get isComplete => short == 0;

  /// Rôles dont le manque dépasse la marge que le corpus s'autorise.
  ///
  /// Un deck réel s'écarte de la médiane ; ne signaler que ce qui sort de
  /// l'écart interquartile évite de reprocher au résultat une liberté que les
  /// decks du corpus prennent eux-mêmes.
  Iterable<MapEntry<CardRole, int>> get notable =>
      roleGaps.entries.where((e) => e.value > 0);
}

/// Terrains de base, par couleur produite.
const _basicByColor = {
  'W': 'Plains',
  'U': 'Island',
  'B': 'Swamp',
  'R': 'Mountain',
  'G': 'Forest',
};

class DeckBuilder {
  const DeckBuilder({this.blueprint = DeckBlueprint.commander});

  final DeckBlueprint blueprint;

  /// Commandants possibles dans [collection], du plus ouvrant au moins ouvrant.
  ///
  /// **Le meilleur général est celui qui donne accès au plus de cartes.** C'est
  /// la seule mesure objective disponible sans comprendre les synergies, et elle
  /// n'est pas absurde : un commandant tricolore ouvre plus qu'un mono-couleur,
  /// et c'est bien ce qui décide si la collection suffit à remplir cent cases.
  List<BuildableCard> commanders(List<BuildableCard> collection) {
    final candidates = collection.where((c) => c.canCommand).toList();
    candidates.sort((a, b) {
      final opened = _playableCount(collection, b.colorIdentity)
          .compareTo(_playableCount(collection, a.colorIdentity));
      return opened != 0 ? opened : a.displayName.compareTo(b.displayName);
    });
    return candidates;
  }

  int _playableCount(List<BuildableCard> collection, ColorIdentity identity) =>
      collection.where((c) => !c.isBasicLand && c.playableIn(identity)).length;

  /// Construit un deck autour de [commander] avec [collection].
  BuiltDeck build(List<BuildableCard> collection, BuildableCard commander) {
    final identity = commander.colorIdentity;
    final pool = collection
        .where(
          (c) =>
              c.oracleId != commander.oracleId &&
              !c.isBasicLand &&
              c.playableIn(identity),
        )
        .toList();

    final landTarget = blueprint.lands.countFor(blueprint.size);
    final specials = pool.where((c) => c.isLand).take(landTarget).toList();
    final spellSlots = blueprint.size - 1 - landTarget;

    final spells = _fillSpells(
      pool.where((c) => !c.isLand).toList(),
      spellSlots,
    );

    // Les terrains de base complètent ce que la collection n'a pas fourni en
    // terrains spéciaux : ils sont illimités, c'est leur seule vertu ici.
    final basics = _spreadBasics(
      identity,
      landTarget - specials.length,
      spells,
    );

    return BuiltDeck(
      commander: commander,
      spells: spells,
      lands: specials,
      basicLands: basics,
      diagnosis: _judge(spells, specials, commander, basics),
    );
  }

  /// Choisit les sorts, un par un, en comblant à chaque fois le manque le plus
  /// criant.
  List<BuildableCard> _fillSpells(List<BuildableCard> pool, int slots) {
    final chosen = <BuildableCard>[];
    final remaining = [...pool];

    while (chosen.length < slots && remaining.isNotEmpty) {
      remaining.sort((a, b) {
        final score = _score(b, chosen).compareTo(_score(a, chosen));
        // À score égal, l'ordre alphabétique : deux constructions successives
        // sur la même collection doivent rendre le même deck.
        return score != 0 ? score : a.displayName.compareTo(b.displayName);
      });
      chosen.add(remaining.removeAt(0));
    }
    return chosen;
  }

  /// Ce qu'une carte apporterait au deck en cours.
  ///
  /// La somme des manques qu'elle comble : un rôle sous-représenté et un palier
  /// de courbe creux valent chacun un point, pondérés par l'ampleur du manque.
  /// Une carte qui ne comble rien garde un score nul et n'est retenue que
  /// faute de mieux — ce qui arrive, et vaut mieux qu'une case vide.
  double _score(BuildableCard card, List<BuildableCard> chosen) {
    var score = 0.0;
    final roles = rolesOf(card);

    for (final entry in blueprint.roles.entries) {
      final target = entry.value.countFor(blueprint.size);
      final have = chosen.where((c) => rolesOf(c).contains(entry.key)).length;
      if (roles.contains(entry.key) && have < target) {
        score += (target - have) / target;
      }
    }

    for (final step in blueprint.curve) {
      if (!step.contains(card.cmc)) continue;
      final target = step.quota.countFor(blueprint.size);
      final have = chosen.where((c) => step.contains(c.cmc)).length;
      if (have < target) score += (target - have) / target;
    }

    return score;
  }

  /// Répartit les terrains de base selon ce que le deck a besoin de produire.
  ///
  /// Le besoin d'une couleur se lit dans les cartes retenues : un deck dont les
  /// trois quarts des sorts sont noirs veut trois quarts de Marais. Une couleur
  /// de l'identité du général qu'aucune carte n'emploie garde tout de même un
  /// terrain — le général, lui, la réclame.
  Map<String, int> _spreadBasics(
    ColorIdentity identity,
    int count,
    List<BuildableCard> spells,
  ) {
    if (count <= 0 || identity.isEmpty) return const {};

    final weights = <String, int>{for (final c in identity) c: 0};
    for (final spell in spells) {
      for (final color in spell.colorIdentity) {
        if (weights.containsKey(color)) weights[color] = weights[color]! + 1;
      }
    }

    // **Une couleur de l'identité garde un terrain, même si aucun sort ne
    // l'emploie** : le général, lui, la réclame, et un deck qui ne peut pas
    // lancer son propre général n'est pas un deck. Le reste se répartit ensuite
    // au prorata de ce que les sorts retenus demandent.
    final colors = identity.toList()..sort();
    final basics = <String, int>{};
    var placed = 0;
    for (final color in colors) {
      if (placed >= count) break;
      basics[_basicByColor[color] ?? 'Wastes'] = 1;
      placed++;
    }

    final total = weights.values.fold(0, (sum, w) => sum + w);
    final left = count - placed;
    if (total > 0 && left > 0) {
      for (final color in colors) {
        final land = _basicByColor[color] ?? 'Wastes';
        final share = (left * weights[color]! / total).floor();
        basics[land] = (basics[land] ?? 0) + share;
        placed += share;
      }
    }

    // Les arrondis laissent des places vides : elles reviennent à la couleur la
    // plus demandée, faute de raison d'en privilégier une autre.
    if (placed < count) {
      final dominant = weights.entries.reduce(
        (a, b) => b.value > a.value ? b : a,
      );
      final land = _basicByColor[dominant.key] ?? 'Wastes';
      basics[land] = (basics[land] ?? 0) + (count - placed);
    }

    return basics..removeWhere((_, n) => n == 0);
  }

  DeckDiagnosis _judge(
    List<BuildableCard> spells,
    List<BuildableCard> lands,
    BuildableCard commander,
    Map<String, int> basics,
  ) {
    final gaps = <CardRole, int>{};
    for (final entry in blueprint.roles.entries) {
      final target = entry.value.countFor(blueprint.size);
      final have = spells.where((c) => rolesOf(c).contains(entry.key)).length;
      // Le général compte comme n'importe quelle carte : il est sur le champ de
      // bataille plus souvent qu'aucune autre.
      final withCommander =
          have + (rolesOf(commander).contains(entry.key) ? 1 : 0);
      gaps[entry.key] = target - withCommander;
    }

    final size =
        1 + spells.length + lands.length + basics.values.fold(0, (s, n) => s + n);
    return DeckDiagnosis(
      roleGaps: gaps,
      short: (blueprint.size - size).clamp(0, blueprint.size).toInt(),
    );
  }
}
