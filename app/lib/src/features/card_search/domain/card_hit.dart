/// Résultat de recherche de carte.
///
/// Distingue deux noms, et c'est essentiel à l'usage : `name` est le nom oracle
/// anglais qui fait foi partout (decklists, règles de format), tandis que
/// `matchedName` est le nom qui a effectivement répondu à la saisie — souvent le
/// nom français. Afficher les deux permet à l'utilisateur de reconnaître sa carte
/// physique tout en voyant l'identité sous laquelle elle sera enregistrée.
library;

class CardHit {
  const CardHit({
    required this.oracleId,
    required this.name,
    required this.matchedName,
    required this.matchedLang,
    required this.legalPauper,
    required this.legalModern,
    required this.legalCommander,
    this.typeLine,
    this.manaCost,
    this.priceEur,
    this.owned = 0,
    this.score = 0,
  });

  final String oracleId;

  /// Nom oracle anglais — l'identité canonique de la carte.
  final String name;

  /// Nom ayant répondu à la saisie, dans la langue de `matchedLang`.
  final String matchedName;
  final String matchedLang;

  final String? typeLine;
  final String? manaCost;

  /// Prix de l'impression la moins chère, en euros. Nul si la carte n'est cotée
  /// nulle part.
  final double? priceEur;

  final bool legalPauper;
  final bool legalModern;
  final bool legalCommander;

  /// Exemplaires déjà possédés. Sans cette information, on ne sait pas, en
  /// saisissant, si une carte a déjà été ajoutée — et sur une collection saisie
  /// en plusieurs séances, on ne sait plus où l'on en est dans sa boîte.
  final int owned;

  /// Force de la correspondance, de 0 à 1.
  ///
  /// Sert à distinguer une vraie trouvaille d'un rapprochement fortuit — un mot
  /// isolé d'un texte de règles trouve toujours *quelque chose*, avec un score
  /// faible. Indispensable dès qu'on cherche sans savoir si la ligne examinée
  /// est un nom de carte.
  final double score;

  /// Vrai quand le nom affiché diffère du nom oracle, c'est-à-dire quand la
  /// carte a été trouvée par sa traduction.
  bool get isLocalized => matchedName != name;

  factory CardHit.fromJson(Map<String, dynamic> json) {
    final price = json['price_eur'];
    return CardHit(
      oracleId: json['oracle_id'] as String,
      name: json['name'] as String,
      matchedName: json['matched_name'] as String? ?? json['name'] as String,
      matchedLang: json['matched_lang'] as String? ?? 'en',
      typeLine: json['type_line'] as String?,
      manaCost: json['mana_cost'] as String?,
      priceEur: price == null ? null : (price as num).toDouble(),
      legalPauper: json['legal_pauper'] as bool? ?? false,
      legalModern: json['legal_modern'] as bool? ?? false,
      legalCommander: json['legal_commander'] as bool? ?? false,
      owned: (json['owned'] as num?)?.toInt() ?? 0,
      score: (json['score'] as num?)?.toDouble() ?? 0,
    );
  }
}
