/// Ce que la dictée dit de l'impression tenue en main, et ce qu'on en retient.
///
/// « quatre foudre édition M21 numéro 137 brillante » désigne une carte, puis
/// une édition et une finition. Ce module porte la seconde moitié : la demande
/// telle qu'entendue ([SpokenPrinting]), et sa confrontation aux éditions que
/// le catalogue connaît pour la carte ([resolveSpokenPrinting]). Pur, donc
/// testable sans réseau ; l'aller-retour vit dans `data/`.
///
/// **La règle est celle du garde-fou §IV.8.** Une édition n'est retenue que si
/// elle est désignée exactement — son code, ou son nom entier — et que rien ne
/// reste à choisir : une seule candidate, dans la finition demandée. Un nom
/// seulement approché ne retient rien, même quand une seule édition y répond :
/// un mot mal entendu peut tomber par hasard sur la seule extension qui le
/// contient. La ligne propose alors l'extension trouvée, à confirmer d'un
/// toucher.
///
/// **La comparaison se fait ici, pas au serveur.** `card_printings` cherche une
/// sous-chaîne du nom imprimé, ponctuation comprise ; or la voix n'en rend
/// aucune — « Strixhaven: School of Mages » revient « strixhaven school of
/// mages », « The Brothers' War » revient « the brothers war ». Le serveur
/// reçoit donc un seul mot distinctif ([SpokenPrinting.searchTerms]), qui
/// ramène un sur-ensemble, et le tri fin se fait sur des noms débarrassés de
/// leur ponctuation, de leurs accents et des mots de liaison — « extension de
/// Dominaria » désigne *Dominaria*, « revised » désigne *Revised Edition*.
///
/// Les noms d'extension sont ceux du catalogue, en anglais : Scryfall n'en
/// publie aucune traduction.
library;

import '../../printings/domain/card_printing.dart';

/// L'édition et la finition dites pour une carte — tout, une partie, ou rien.
final class SpokenPrinting {
  const SpokenPrinting({this.set, this.number, this.foil = false});

  /// Rien de dit : ni extension, ni finition.
  static const none = SpokenPrinting();

  /// Extension entendue, nom ou code, en minuscules et telle quelle.
  final String? set;

  /// Numéro de collection. Il n'existe qu'avec une extension : seul, il ne
  /// désigne rien.
  final String? number;

  /// Vrai quand « brillante » ou « foil » a été dit.
  final bool foil;

  bool get isNone => set == null && !foil;

  /// Termes à soumettre au catalogue, dans l'ordre où les essayer — deux au
  /// plus, chacun coûtant un aller-retour.
  ///
  /// **Un code coupé en deux vient d'abord** : « mh 2 » est presque sûrement
  /// MH2, et un code n'a jamais d'espace. Ensuite les mots les plus longs, les
  /// plus distinctifs : « strixhaven » plutôt que « of ». Un mot d'une lettre
  /// ne vaut rien comme recherche de sous-chaîne, un mot de liaison non plus.
  ///
  /// **Les mots se coupent à l'apostrophe**, que le nom imprimé garde :
  /// « urzas » ne figure pas dans « Urza's Saga », « urza » si.
  List<String> get searchTerms {
    final spoken = set;
    if (spoken == null) return const [];
    final said = _keyWords(
      spoken,
      splitApostrophes: true,
    ).where((w) => w.length >= 2).toList();
    // À longueur égale, l'ordre dit départage : le tri seul n'est pas stable.
    final words = [...said]
      ..sort((a, b) {
        final byLength = b.length.compareTo(a.length);
        return byLength != 0 ? byLength : said.indexOf(a) - said.indexOf(b);
      });

    final compact = _compact(spoken);
    final terms = <String>[
      if (compact.length >= _minCodeLength && compact.length <= _maxCodeLength)
        compact,
      ...words,
    ];
    return terms.toSet().take(2).toList(growable: false);
  }

  /// Vrai quand [other] demande la même chose, à la façon de dire près : « m21 »
  /// et « m 21 » désignent la même extension.
  bool sameRequest(SpokenPrinting other) =>
      other.foil == foil &&
      _compact(other.set ?? '') == _compact(set ?? '') &&
      _collectorKey(other.number ?? '') == _collectorKey(number ?? '');

  @override
  bool operator ==(Object other) =>
      other is SpokenPrinting &&
      other.set == set &&
      other.number == number &&
      other.foil == foil;

  @override
  int get hashCode => Object.hash(set, number, foil);

  @override
  String toString() =>
      'SpokenPrinting(set: $set, number: $number, foil: $foil)';
}

/// Les codes d'extension Magic tiennent en trois à cinq caractères ; six laisse
/// passer les codes de promotion (`pmh2`) sans prendre un nom pour un code.
const _maxCodeLength = 6;

/// En deçà, un « code » n'est qu'une lettre entendue : il ne désigne rien.
const _minCodeLength = 2;

/// Ce que la demande devient face aux éditions de la carte.
sealed class PrintingResolution {
  const PrintingResolution();
}

/// Une seule édition répond, désignée exactement : elle est retenue, dans
/// cette finition.
final class PrintingRetained extends PrintingResolution {
  const PrintingRetained(this.printing, {required this.isFoil});

  final CardPrinting printing;
  final bool isFoil;
}

/// Une seule édition répond, mais à un nom approché : elle se confirme au
/// doigt.
final class PrintingApproximate extends PrintingResolution {
  const PrintingApproximate(this.candidate);

  final CardPrinting candidate;
}

/// Plusieurs éditions répondent : l'utilisateur choisit parmi elles.
final class PrintingAmbiguous extends PrintingResolution {
  const PrintingAmbiguous(this.candidates);

  final List<CardPrinting> candidates;
}

/// Aucune édition de la carte ne répond à ce qui a été dit.
final class PrintingNotFound extends PrintingResolution {
  const PrintingNotFound();
}

/// L'édition existe, mais jamais en brillant alors que la brillante est dite.
///
/// Lequel des deux mots a été mal entendu ? Rien ne permet de le dire :
/// retenir l'édition sans sa finition serait deviner.
final class PrintingNotInFoil extends PrintingResolution {
  const PrintingNotInFoil();
}

/// Confronte la demande aux éditions de la carte.
///
/// [candidates] vient du catalogue : les éditions ramenées par un terme de
/// [SpokenPrinting.searchTerms], ou l'édition unique de la carte quand aucune
/// extension n'a été dite. Elles sont filtrées ici, jamais crues sur parole.
PrintingResolution resolveSpokenPrinting(
  SpokenPrinting asked,
  Iterable<CardPrinting> candidates,
) {
  var (pool, isExact) = _inSpokenSet(
    asked.set,
    candidates.toList(growable: false),
  );

  final number = asked.number;
  if (number != null) {
    final wanted = _collectorKey(number);
    pool = pool
        .where((p) => _collectorKey(p.collectorNumber ?? '') == wanted)
        .toList(growable: false);
  }
  if (pool.isEmpty) return const PrintingNotFound();

  // La brillante dite écarte ce qui n'a jamais été imprimé en brillant : si une
  // seule édition de l'extension l'a été, c'est elle qu'on tient.
  if (asked.foil) {
    pool = pool.where((p) => p.hasFoil).toList(growable: false);
    if (pool.isEmpty) return const PrintingNotInFoil();
  }
  if (pool.length > 1) return PrintingAmbiguous(pool);

  final only = pool.single;
  if (!isExact) return PrintingApproximate(only);
  // Non dite, la finition suit ce que l'édition imprime : une édition qui
  // n'existe qu'en brillant l'est d'office, sa jumelle normale n'existant pas.
  return PrintingRetained(
    only,
    isFoil: asked.foil || (!only.hasNonfoil && only.hasFoil),
  );
}

/// Les candidates qui répondent à l'extension dite, et si elles y répondent
/// exactement.
///
/// Le code exact l'emporte, puis le nom exact : « dominaria » est une
/// extension, pas seulement le début de « Dominaria United » et « Dominaria
/// Remastered ». À défaut, un code commencé ou un nom dont chaque mot dit
/// commence un mot : la correspondance est alors approchée.
(List<CardPrinting>, bool) _inSpokenSet(
  String? spoken,
  List<CardPrinting> all,
) {
  if (spoken == null) return (all, true);
  final code = _compact(spoken);
  if (code.length < _minCodeLength) return (const [], false);
  final words = _keyWords(spoken);
  final name = words.join(' ');

  final sameCode = all
      .where((p) => p.setCode.toLowerCase() == code)
      .toList(growable: false);
  if (sameCode.isNotEmpty) return (sameCode, true);

  final sameName = all
      .where((p) => _keyWords(p.setName ?? '').join(' ') == name)
      .toList(growable: false);
  if (sameName.isNotEmpty) return (sameName, true);

  bool startsAWord(String said, List<String> printed) =>
      printed.any((w) => w.startsWith(said));
  final approaching = all
      .where((p) {
        if (p.setCode.toLowerCase().startsWith(code)) return true;
        final printed = _keyWords(p.setName ?? '');
        return words.every((said) => startsAWord(said, printed));
      })
      .toList(growable: false);
  return (approaching, false);
}

/// Un numéro de collection comparable : « 037 » et « 37 » sont le même.
String _collectorKey(String number) {
  final trimmed = number.trim().toLowerCase();
  return trimmed.replaceFirst(RegExp(r'^0+(?=.)'), '');
}

/// Mots qui lient sans désigner : dits devant un nom (« extension de
/// Dominaria »), ou imprimés dedans (« Revised Edition », « Core Set 2021 »).
const _linkWords = {
  'de',
  'du',
  'des',
  'la',
  'le',
  'les',
  'the',
  'of',
  'set',
  'edition',
};

/// Les mots qui désignent une extension, sans les mots de liaison.
List<String> _keyWords(String text, {bool splitApostrophes = false}) =>
    _normalize(text, splitApostrophes: splitApostrophes)
        .split(' ')
        .where((w) => w.isNotEmpty && !_linkWords.contains(w))
        .toList(growable: false);

/// La forme d'un code : les mots qui désignent, collés.
String _compact(String text) => _keyWords(text).join();

/// Un nom tel que la voix le rend : minuscules, sans accent, sans apostrophe,
/// toute autre ponctuation réduite à une espace.
///
/// [splitApostrophes] fait de l'apostrophe une coupure plutôt qu'une soudure :
/// c'est ce que veut une recherche de sous-chaîne dans un nom qui la garde.
String _normalize(String text, {bool splitApostrophes = false}) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final at = _accented.indexOf(char);
    buffer.write(switch (char) {
      'œ' => 'oe',
      'æ' => 'ae',
      _ => at < 0 ? char : _plain[at],
    });
  }
  return buffer
      .toString()
      .replaceAll(RegExp(r"['’]"), splitApostrophes ? ' ' : '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
}

/// Les lettres accentuées du français et de l'anglais, et leur base : la voix
/// en perd une partie, le catalogue en porte quelques-unes.
const _accented = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ';
const _plain = 'aaaaaaceeeeiiiinooooouuuuyy';
