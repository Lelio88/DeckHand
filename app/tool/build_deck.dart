/// Éprouve le constructeur de decks sur une vraie collection, hors application.
///
/// **Pourquoi cet outil existe.** Le constructeur est de la logique pure, donc
/// testable — mais les tests le nourrissent de cartes fabriquées, régulières et
/// dociles. Une vraie collection ne l'est pas : elle a des trous, des couleurs
/// déséquilibrées, des cartes qui ne remplissent aucun rôle. C'est elle qui dit
/// si le résultat est jouable ou seulement légal.
///
/// La collection s'exporte depuis la base en JSON (voir l'en-tête du dépôt), ce
/// qui évite d'authentifier un outil de mesure contre Supabase.
///
/// Usage :
///   dart run tool/build_deck.dart `<collection.json>` [format] [général]
library;

import 'dart:convert';
import 'dart:io';

import 'package:deckhand/src/features/builder/domain/buildable_card.dart';
import 'package:deckhand/src/features/decks/domain/deck_suggestion.dart';
import 'package:deckhand/src/features/builder/domain/card_role.dart';
import 'package:deckhand/src/features/builder/domain/deck_blueprint.dart';
import 'package:deckhand/src/features/builder/domain/deck_builder.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage : dart run tool/build_deck.dart <collection.json> [général]',
    );
    exitCode = 64;
    return;
  }

  final raw = jsonDecode(File(args.first).readAsStringSync()) as List<dynamic>;
  final collection = [
    for (final entry in raw.cast<Map<String, dynamic>>())
      BuildableCard(
        oracleId: entry['oracleId'] as String,
        name: entry['name'] as String,
        printedName: entry['fr'] as String?,
        typeLine: entry['typeLine'] as String? ?? '',
        cmc: (entry['cmc'] as num).toDouble(),
        colorIdentity: (entry['colors'] as List<dynamic>)
            .cast<String>()
            .toSet(),
        oracleText: entry['text'] as String? ?? '',
        quantity: (entry['qty'] as num?)?.toInt() ?? 1,
      ),
  ];

  final format = args.length > 1
      ? DeckFormat.values.firstWhere(
          (f) => f.id == args[1],
          orElse: () => DeckFormat.commander,
        )
      : DeckFormat.commander;
  final blueprint = DeckBlueprint.of(format);
  if (blueprint == null) {
    stderr.writeln('Aucun gabarit mesuré pour ce format.');
    exit(64);
  }
  final builder = DeckBuilder(blueprint: blueprint);

  if (!blueprint.needsCommander) {
    final deck = builder.build(collection);
    stdout
      ..writeln('collection : ${collection.length} cartes')
      ..writeln(
        '\n=== ${format.label} — '
        '${builder.dominantColors(collection).join('')} ===',
      )
      ..writeln(
        '${deck.size} cartes — ${deck.spells.length} sorts, '
        '${deck.lands.length} terrains spéciaux, '
        '${deck.basicCount} terrains de base',
      )
      ..writeln('terrains de base : ${deck.basicLands}')
      ..writeln('\nrôles (obtenu / visé) :');
    for (final entry in blueprint.roles.entries) {
      final target = entry.value.countFor(blueprint.size);
      final gap = deck.diagnosis.roleGaps[entry.key] ?? 0;
      stdout.writeln(
        '  ${entry.key.name.padRight(10)} ${target - gap} / $target',
      );
    }
    return;
  }

  final candidates = builder.commanders(collection);
  stdout.writeln('collection : ${collection.length} cartes');
  stdout.writeln('généraux possibles : ${candidates.length}');

  final wanted = args.length > 2 ? args[2].toLowerCase() : null;
  final general = wanted == null
      ? candidates.first
      : candidates.firstWhere(
          (c) => c.displayName.toLowerCase().contains(wanted),
          orElse: () => candidates.first,
        );

  final deck = builder.build(collection, general);

  stdout
    ..writeln(
      '\n=== ${general.displayName} '
      '(${general.colorIdentity.join('')}) ===',
    )
    ..writeln(
      '${deck.size} cartes  —  '
      '${deck.spells.length} sorts, ${deck.lands.length} terrains spéciaux, '
      '${deck.basicCount} terrains de base',
    )
    ..writeln('terrains de base : ${deck.basicLands}');

  stdout.writeln('\nrôles (obtenu / visé) :');
  for (final entry in blueprint.roles.entries) {
    final target = entry.value.countFor(blueprint.size);
    final have = target - (deck.diagnosis.roleGaps[entry.key] ?? 0);
    final gap = deck.diagnosis.roleGaps[entry.key] ?? 0;
    final verdict = gap <= 0
        ? 'atteint'
        : gap <= entry.value.spread
        ? 'dans la marge du corpus'
        : 'manque $gap';
    stdout.writeln(
      '  ${entry.key.name.padRight(10)} $have / $target   $verdict',
    );
  }

  stdout.writeln('\ncourbe de mana (obtenu / visé) :');
  for (final step in blueprint.curve) {
    final have = deck.spells.where((c) => step.contains(c.cmc)).length;
    final range = '  ${step.min}-${step.max}'.padRight(10);
    stdout.writeln('$range$have / ${step.quota.countFor(blueprint.size)}');
  }

  stdout.writeln('\ndix premières cartes retenues :');
  for (final spell in deck.spells.take(10)) {
    final roles = rolesOf(spell).map((r) => r.name).join(', ');
    stdout.writeln(
      '  ${spell.displayName.padRight(38)} '
      '${spell.cmc.toStringAsFixed(0)}  $roles',
    );
  }
}
