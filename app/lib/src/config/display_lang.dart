/// Langue dans laquelle le nom des cartes s'affiche.
///
/// **Ce n'est pas la langue de l'interface.** L'application parle français ;
/// ceci décide seulement si une carte s'annonce « Traceur nantuko »,
/// « Nantuko Tracer » ou « ナントゥーコの追跡者 ». Les deux réglages sont
/// indépendants — on peut lire une interface française et collectionner des
/// cartes japonaises, ce qui est précisément le cas qui a ouvert ce chantier.
///
/// **La préférence vit en base, pas dans les préférences locales.** Le nom
/// traduit est choisi par cinq fonctions SQL (`my_collection`,
/// `cards_by_oracle_ids`, `deck_suggestions`, `deck_missing_cards`,
/// `my_buildable_cards`) qui lisent `public.my_display_lang()`. Le ranger côté
/// appareil obligerait à passer la langue à chaque appel, donc à changer cinq
/// signatures et à faire suivre PostgREST ; une colonne sur `profiles` suffit,
/// et elle suit le compte d'un appareil à l'autre.
///
/// **La liste n'est pas celle de Scryfall.** Le catalogue porte dix-huit codes
/// de langue, mais sept d'entre eux — phyrexien, latin, grec ancien, hébreu,
/// arabe, sanskrit, quenya — ne comptent qu'une poignée de cartes de série
/// limitée. Les proposer ferait miroiter un affichage qui resterait anglais
/// pour tout le reste de la collection. Ne figurent donc ici que les langues
/// dont la couverture dépasse dix mille cartes, relevées sur
/// `card_search_names`.
library;

import 'dart:ui' show Locale;

/// Langues d'affichage proposées, de la mieux couverte à la moins bien.
///
/// **L'ordre est l'information** : il descend du nombre de catalogues servis,
/// si bien que les premières lignes du menu sont celles qui tiennent leur
/// promesse partout. Trier par alphabet mettrait l'allemand devant l'anglais.
///
/// Le code est celui de `card_search_names.lang` et part tel quel en base ; le
/// changer invaliderait les préférences déjà enregistrées, qui retomberaient
/// silencieusement sur le repli.
enum CardLang {
  english('en', 'Anglais', 'tous les jeux'),
  french('fr', 'Français', 'Magic, Pokémon, Yu-Gi-Oh, Wankul'),
  german('de', 'Allemand', 'Magic, Pokémon, Yu-Gi-Oh'),
  italian('it', 'Italien', 'Magic, Pokémon, Yu-Gi-Oh'),
  portuguese('pt', 'Portugais', 'Magic, Pokémon, Yu-Gi-Oh'),
  spanish('es', 'Espagnol', 'Magic, Pokémon'),
  japanese('ja', 'Japonais', 'Magic'),
  chineseSimplified('zhs', 'Chinois simplifié', 'Magic'),
  chineseTraditional('zht', 'Chinois traditionnel', 'Magic'),
  russian('ru', 'Russe', 'Magic'),
  korean('ko', 'Coréen', 'Magic');

  const CardLang(this.code, this.label, this.coverage);

  final String code;
  final String label;

  /// Les jeux dont le catalogue porte des noms dans cette langue.
  ///
  /// **Dit plutôt que masqué.** L'autre option était de n'offrir que les
  /// langues du jeu affiché ; elle rendait le réglage mouvant — changer de jeu
  /// aurait pu retirer l'option qu'on venait de choisir. La préférence est une
  /// propriété du lecteur, pas du jeu affiché : on montre donc tout, en disant
  /// ce que chaque ligne couvre.
  ///
  /// **Relevé sur `card_search_names` le 2026-09-17**, et non déduit :
  ///
  ///     magic     18 langues     pokemon   6 (en fr de it es pt)
  ///     yugioh     5 langues     wankul    2 (en fr)
  ///     riftbound, onepiece, lorcana, swu : anglais seul
  ///
  /// Une langue absente d'un catalogue n'est pas une panne : le nom oracle
  /// anglais existe pour toute carte, et c'est lui qui s'affiche.
  ///
  /// Cette table est le jumeau d'un fait de base ; l'ajout d'une langue à un
  /// connecteur doit la mettre à jour — voir `CLAUDE.md` §VII.
  final String coverage;

  /// La langue portant ce code, ou `null` s'il n'en existe aucune.
  ///
  /// Rend `null` plutôt que l'anglais : l'appelant qui lit une préférence en
  /// base doit pouvoir distinguer « code inconnu » de « rien de choisi », et
  /// seul lui sait quoi faire de cette différence.
  static CardLang? fromCode(String? code) {
    for (final lang in CardLang.values) {
      if (lang.code == code) return lang;
    }
    return null;
  }

  /// La langue à proposer à quelqu'un dont l'appareil parle [locale].
  ///
  /// **L'anglais est le repli, et c'est délibéré.** Un téléphone en suédois ne
  /// désigne aucune langue du catalogue ; lui afficher des noms anglais est
  /// exact, puisque le nom oracle existe pour toute carte. Retomber sur le
  /// français, l'ancien défaut codé en dur, servirait un utilisateur qui n'a
  /// rien demandé de tel.
  ///
  /// Le chinois est le seul cas où le code de langue ne suffit pas : `zh` seul
  /// ne dit pas s'il faut le simplifié ou le traditionnel. Taïwan, Hong Kong et
  /// Macao emploient le traditionnel, le reste le simplifié — et le script,
  /// quand il est présent, tranche mieux que le pays.
  static CardLang fromLocale(Locale locale) {
    if (locale.languageCode == 'zh') {
      final traditionnel =
          locale.scriptCode == 'Hant' ||
          const {'TW', 'HK', 'MO'}.contains(locale.countryCode);
      return traditionnel
          ? CardLang.chineseTraditional
          : CardLang.chineseSimplified;
    }
    return fromCode(locale.languageCode) ?? CardLang.english;
  }
}
