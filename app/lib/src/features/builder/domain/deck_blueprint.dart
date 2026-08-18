/// Les proportions d'un deck, lues dans le corpus plutôt qu'inventées.
///
/// **Aucun de ces nombres n'est une opinion.** Ils viennent de
/// `api/app/measure/deck_anatomy.py`, qui a mesuré les 1 028 decks du corpus par
/// format. La sagesse populaire dit « trente-sept terrains » en Commander ; les
/// decks réels en comptent trente-huit.
///
/// **Les trois formats ne se valent pas, et la mesure le dit.** Les 190 précons
/// Commander se ressemblent — écart interquartile de deux points sur les
/// terrains, de trois à sept sur les rôles : ils sortent du même atelier, et
/// leur médiane décrit un deck qui existe. Les 725 decks Pauper et les 113
/// Modern, eux, s'étalent de 25 à 40 % de créatures et de 23 à 43 % de sorts :
/// ce sont des **archétypes distincts** — aggro, contrôle, combo — dont la
/// médiane décrit un deck qui n'existe nulle part.
///
/// Leurs gabarits sont donc fournis, puisqu'un deck moyen reste jouable et vaut
/// mieux qu'un tas de cartes, mais [reliability] dit ce qu'il faut en penser et
/// l'interface le répète à l'utilisateur. Les couvrir vraiment demanderait de
/// regrouper les decks par famille avant de moyenner — un travail de
/// classification, pas un réglage.
///
/// Les écarts interquartiles accompagnent chaque cible : ils disent combien de
/// liberté le corpus laisse, et servent à ne pas reprocher au résultat un écart
/// que les decks réels s'autorisent eux-mêmes.
library;

import '../../decks/domain/deck_suggestion.dart';
import 'card_role.dart';

/// Ce que vaut un gabarit, mesuré par la dispersion du corpus dont il sort.
enum BlueprintReliability {
  /// Les decks du format se ressemblent : la médiane décrit un deck réel.
  tight,

  /// Le format mêle des archétypes incompatibles : la médiane décrit un deck
  /// moyen, jouable mais qui ne ressemble à aucun deck du corpus.
  averaged,

  /// **Le gabarit ne vient pas d'un corpus : il vient des règles du jeu.**
  ///
  /// Les deux valeurs précédentes décrivent toutes deux une mesure — un corpus
  /// serré, ou un corpus qui mêle des archétypes. Celle-ci décrit autre chose :
  /// un format dont personne ne publie les listes, mais dont l'éditeur publie
  /// les contraintes de construction.
  ///
  /// Un tel gabarit a un écart interquartile **nul**, et ce n'est pas un défaut
  /// de mesure : « dix terrains » n'a pas de variance, c'est une règle. Il est
  /// en un sens plus sûr qu'une médiane — celle-ci décrit ce que les gens
  /// jouent, une règle décrit ce qui est légal.
  ///
  /// Ce que l'écran doit en dire diffère donc des deux autres : non pas « la
  /// moitié des decks réels tient dans cette bande », mais « le règlement
  /// l'impose ».
  regulatory,
}

/// Une cible, avec la marge que le corpus tolère.
class Quota {
  const Quota(this.share, this.spread);

  /// Médiane mesurée sur le corpus, en pourcentage du deck.
  final double share;

  /// Écart interquartile : la moitié des decks réels tient dans cette bande.
  final double spread;

  int countFor(int size) => (share * size / 100).round();
}

/// Palier de coût de mana, et la part du deck qui lui revient.
class CurveStep {
  const CurveStep(this.min, this.max, this.quota);

  final int min;
  final int max;
  final Quota quota;

  bool contains(double cmc) => cmc >= min && cmc <= max;
}

class DeckBlueprint {
  const DeckBlueprint({
    required this.size,
    required this.maxCopies,
    required this.needsCommander,
    required this.lands,
    required this.roles,
    required this.curve,
    required this.reliability,
    this.extraSize,
    this.usesColorIdentity = true,
    this.curveLabel = 'coût',
  });

  /// Cartes du deck, commandant compris quand il y en a un.
  final int size;

  /// Exemplaires autorisés d'une même carte, hors terrains de base.
  final int maxCopies;

  final bool needsCommander;

  /// Terrains, toutes sortes confondues. **Nul dans les jeux qui n'en ont
  /// pas** : Yu-Gi-Oh n'a aucune carte de ce type, et lui donner un quota de
  /// zéro se lirait comme un manque plutôt que comme une absence de notion.
  final Quota? lands;

  /// Taille de la seconde zone — l'**Extra Deck** de Yu-Gi-Oh —, ou `null` pour
  /// un jeu qui n'en a qu'une.
  ///
  /// Ce n'est pas une part du deck mais une zone à part, plafonnée par les
  /// règles et remplie de cartes qui ne peuvent pas figurer dans la première.
  final int? extraSize;

  /// Le pool est-il restreint par l'identité de couleur ?
  ///
  /// **Faux ne veut pas dire « pas de couleurs », mais « pas cette règle ».**
  /// Les cartes Yu-Gi-Oh portent un Attribut dans le même champ, et l'attribut
  /// n'interdit aucun mélange : filtrer dessus écarterait 32 % du catalogue au
  /// nom d'une contrainte que le jeu n'a pas.
  final bool usesColorIdentity;

  /// Ce que mesure la courbe, pour l'affichage. Magic y met un coût de mana,
  /// Yu-Gi-Oh un Niveau — le champ est le même, la grandeur non.
  final String curveLabel;

  /// Rôles à doser. Ils se recouvrent : une créature qui produit du mana compte
  /// dans les deux, exactement comme dans la mesure d'où viennent ces cibles.
  final Map<CardRole, Quota> roles;

  /// Courbe de mana, sur les seules cartes non-terrain — un terrain coûte zéro
  /// et gonflerait le premier palier de tous les terrains du deck.
  final List<CurveStep> curve;

  final BlueprintReliability reliability;

  /// Gabarit d'un format, ou `null` quand aucun n'a été mesuré.
  ///
  /// **Nul plutôt qu'un gabarit par défaut.** Les trois gabarits Magic viennent
  /// chacun de la médiane de son propre corpus ; le format construit de
  /// Riftbound n'en a pas — ses notions ne sont pas celles de Magic (ni
  /// terrains, ni rampe, mais des runes et des champs de bataille), et lui
  /// prêter des proportions mesurées ailleurs produirait un deck faux avec
  /// l'assurance d'un deck mesuré. La vue le dit plutôt que de le deviner.
  static DeckBlueprint? of(DeckFormat format) => switch (format) {
    DeckFormat.commander => commander,
    DeckFormat.pauper => pauper,
    DeckFormat.modern => modern,
    // **Yu-Gi-Oh est mesuré, et reste pourtant nul.** Ses proportions ont été
    // lues sur ses 3 935 decks (`deck_anatomy --game yugioh`), et elles sont
    // les plus nettes du projet : deck principal de **40 cartes**, écart
    // interquartile de 0 à 1 sur les quatre formats ; Extra Deck de 15 (11 en
    // Goat) ; **3 exemplaires** au maximum, vérifié sur tout le corpus.
    //
    // Ce n'est donc pas le gabarit qui manque, c'est le **constructeur**. Il
    // est bâti sur des notions que ce jeu n'a pas, et la mesure le chiffre :
    // `isCreature` cherche « Creature » et n'en trouve **aucune** sur 13 866
    // cartes, `isLand` non plus, si bien que deux quotas sur cinq seraient
    // introuvables. Pire, `playableIn` filtrerait le pool par identité de
    // couleur — or l'ingestion range l'**Attribut** (DARK, LIGHT, WATER…) dans
    // ce champ, et l'attribut n'impose aucune contrainte de construction en
    // Yu-Gi-Oh. Retenir les deux mieux fournis écarterait **32 % du catalogue**
    // sur une règle qui n'existe pas. Même remarque pour `cmc`, qui porte ici
    // le Niveau : un analogue de forme, pas de sens.
    //
    // Les quatre formats Yu-Gi-Oh ont désormais leurs axes — Monstre, Magie,
    // Piège, paliers de Niveau, deux zones —, mesurés sur leurs propres decks.
    DeckFormat.edison => edison,
    DeckFormat.goat => goat,
    DeckFormat.redu => redu,
    DeckFormat.hat => hat,
    DeckFormat.standard => pokemonStandard,
    // Le format construit de Riftbound n'en a toujours pas : ses notions —
    // runes, champs de bataille — ne sont celles d'aucun des deux autres jeux,
    // et son corpus n'a pas été mesuré sous cet angle.
    DeckFormat.constructed => null,
    // **Wankul connaît sa règle et n'a pourtant pas de gabarit**, ce qui est
    // une situation nouvelle : les règles de tournoi publiées donnent
    // 50 cartes — 10 terrains, 35 personnages, au plus 5 marqueurs — soit des
    // proportions plus sûres qu'une médiane, puisqu'elles sont prescrites et
    // non observées.
    //
    // Il manque pourtant les deux moitiés qui rendraient ce gabarit exécutable.
    // La notion de **marqueur** n'existe dans aucun champ du catalogue : sans
    // elle, le plafond de cinq ne se vérifie sur rien, et un deck construit
    // l'ignorerait en silence. Et la **limite d'exemplaires** n'est pas connue
    // — ni mesurée sur un corpus, qui n'existe pas encore, ni lue dans les
    // règles. La poser au jugé produirait un deck faux avec l'assurance d'un
    // deck mesuré, ce que ce module refuse depuis Riftbound.
    //
    // La vue le dit plutôt que de le deviner. À reprendre quand le catalogue
    // sera en base : les deux manques s'y trouveront ou non, et c'est le
    // catalogue qui tranchera.
    DeckFormat.tournament => wankulTournament,
    DeckFormat.premier => swuPremier,
    DeckFormat.opStandard => onepieceStandard,
    DeckFormat.lorcanaCore => lorcanaCore,
  };

  /// Star Wars Unlimited — **mesuré sur 5 038 listes de tournoi**, le corpus
  /// entier de la fenêtre de trente jours.
  ///
  /// **Vingt-trois fois plus de listes n'ont presque rien changé aux médianes,
  /// et ont ÉLARGI les écarts.** Les unités valent 81,0 % dans les deux mesures,
  /// à un dixième près ; le coût 4 bouge de 0,2 point. Mais l'écart
  /// interquartile du haut de courbe passe de 17,4 à 22,0 points, celui des
  /// améliorations de 4,3 à 6,0.
  ///
  /// Ce n'est pas une mesure moins bonne : **l'écart interquartile décrit la
  /// diversité du méta, non l'incertitude de la mesure.** 220 listes
  /// échantillonnaient une poignée d'archétypes ; 5 038 couvrent tout ce qui se
  /// joue, y compris les archétypes minoritaires qui n'ont ni la même courbe ni
  /// le même dosage. Attendre qu'un grand corpus resserre un gabarit, c'est
  /// confondre les deux.
  ///
  /// Deux affirmations de la mesure précédente sont démenties :
  ///
  /// - **« le coût 0 n'existe pas dans le deck principal »** — il existe, à
  ///   140 exemplaires sur 273 980. C'est 0,05 %, donc invisible sur 220 listes
  ///   et bien réel sur cinq mille. Le palier part de 0.
  /// - **la taille était lue à 51** parce que le banc comptait le Leader et la
  ///   Base dans le corps du deck. Les deux sont dans `deck_cards` — le Leader
  ///   en plus de `commander_oracle_id` —, et le deck jouable en fait 50 tout
  ///   rond : 2 689 listes sur 5 038, soit **53,4 %**, en portent exactement
  ///   cinquante. Le gabarit visait déjà 50 ; il le vise désormais pour la
  ///   bonne raison.
  ///
  /// Riftbound n'a pas le sien parce que ses notions n'ont pas été mesurées ;
  /// Yu-Gi-Oh a fallu refaire le constructeur sur ses axes ; Wankul connaît ses
  /// règles mais manque des champs pour les vérifier. Ici les trois familles
  /// sont **imprimées dans le type**, la taille est un contrat, et le coût est
  /// un vrai coût de mise en jeu.
  ///
  /// **La taille est 50, et c'est à la fois le mode et le minimum
  /// réglementaire.** 2 689 listes sur 5 038 en portent exactement cinquante,
  /// et la médiane vaut 50 elle aussi une fois le Leader et la Base retirés du
  /// compte. Viser le plancher produit le deck le plus accessible, ce qui est la
  /// question que ce produit pose.
  ///
  /// **`usesColorIdentity` est vrai, et c'est mesuré — pas supposé.** Yu-Gi-Oh
  /// a montré qu'un champ ressemblant à une identité de couleur peut n'imposer
  /// aucune contrainte, et y filtrer écartait 32 % de son catalogue. SWU est
  /// l'inverse : **79,1 % des decks tiennent entièrement dans les aspects** de
  /// leur leader et de leur base, la part hors aspect ayant une médiane de
  /// 0,0 % et un écart interquartile de 0,0 point.
  ///
  /// La réserve à connaître : un deck sur cinq joue hors aspect, jusqu'à 22 %
  /// de ses cartes — le jeu le pénalise de deux ressources sans l'interdire.
  /// Le filtre est donc un peu plus strict que le méta réel, dans le sens sûr :
  /// il propose des decks jouables sans surcoût plutôt que des decks que la
  /// collection ne peut pas payer.
  ///
  /// Le leader tient la place du commandant, comme la Légende de Riftbound :
  /// il est à un exemplaire dans 220 listes sur 220, et c'est par lui qu'on
  /// choisit un deck.
  static const swuPremier = DeckBlueprint(
    size: 50,
    // La règle du jeu, et le corpus la confirme sur 5 038 listes : **deux
    // seulement** dépassent trois exemplaires, dont une à 15 qui trahit une
    // saisie fautive plutôt qu'une infraction. Même figure que le deck HAT à
    // six exemplaires chez Yu-Gi-Oh.
    maxCopies: 3,
    needsCommander: true,
    // Aucun terrain : on ne joue pas de carte-ressource dans ce jeu, on
    // défausse une carte de sa main pour en faire une ressource. `null` et non
    // zéro — il n'y a rien à manquer, comme pour Yu-Gi-Oh.
    lands: null,
    curveLabel: 'ressources',
    roles: {
      CardRole.unit: Quota(81.0, 10.0),
      CardRole.event: Quota(14.0, 8.3),
      CardRole.upgrade: Quota(4.0, 6.0),
    },
    // Mesurée sur les mêmes listes. Le palier 6+ reste le plus dispersé, et il
    // l'est **davantage** qu'avant — 22,0 points contre 17,4 : c'est là que les
    // archétypes divergent, et cinq mille listes en montrent plus que deux cent
    // vingt.
    curve: [
      CurveStep(0, 1, Quota(4.0, 11.7)),
      CurveStep(2, 2, Quota(26.0, 7.0)),
      CurveStep(3, 3, Quota(24.0, 9.8)),
      CurveStep(4, 4, Quota(15.5, 6.7)),
      CurveStep(5, 5, Quota(12.0, 7.0)),
      CurveStep(6, 99, Quota(16.0, 22.0)),
    ],
    // Un seul format, mais tous les archétypes du méta y sont mêlés : 10,0
    // points d'écart sur les unités, 22,0 sur le haut de courbe. La médiane
    // décrit un deck plausible, pas un deck existant.
    reliability: BlueprintReliability.averaged,
  );

  /// One Piece — **mesuré sur 1 490 listes**, et le gabarit le plus contraint
  /// du projet après Pokémon.
  ///
  /// **La taille est un contrat, pas une médiane.** 50 cartes, écart
  /// interquartile **0** — la même figure exacte que Pokémon à 60. Le leader
  /// n'en fait pas partie : il occupe `commander_oracle_id`, un exemplaire par
  /// deck, hors du compte.
  ///
  /// **`usesColorIdentity` est vrai, et c'est le chiffre le plus net qu'un jeu
  /// ait rendu sur ce point : 100 % des 2 033 decks tiennent entièrement dans
  /// l'identité de leur leader**, médiane et maximum à 0 % hors identité. SWU
  /// était à 79,1 %, Yu-Gi-Oh à zéro — son Attribut ressemblait à une identité
  /// de couleur sans rien imposer. Ici c'est une règle dure, et le corpus ne la
  /// viole jamais.
  ///
  /// Ce 100 % a d'abord valu 36,5 %, et c'est ce qui a révélé un défaut
  /// d'ingestion : la source sépare les couleurs par un **espace**, le
  /// connecteur découpait sur une barre oblique, et les 66 cartes bicolores
  /// entraient sous une couleur unique nommée « Blue Green ». Rien ne le
  /// signalait — le catalogue paraissait complet. Seule la distribution l'a
  /// trahi : **médiane 100 % hors identité avec 36,5 % des decks à 0 %**, une
  /// forme binaire qu'aucune règle de jeu ne produit.
  static const onepieceStandard = DeckBlueprint(
    size: 50,
    // La règle du jeu, et le corpus la confirme. Les rares listes au-dessus
    // (jusqu'à 20 exemplaires) sont des saisies fautives, même figure que le
    // deck HAT à six exemplaires chez Yu-Gi-Oh.
    maxCopies: 4,
    needsCommander: true,
    // Aucun terrain : la ressource est le DON!!, distribué automatiquement à
    // chaque tour. `null` et non zéro — il n'y a rien à manquer.
    lands: null,
    curveLabel: 'DON!!',
    roles: {
      CardRole.character: Quota(84.0, 12.0),
      CardRole.event: Quota(14.0, 12.0),
      // Médiane nulle : la moitié des decks n'en joue aucun. Le quota reste
      // déclaré parce que l'autre moitié en joue jusqu'à 6 %, et qu'un rôle
      // absent du gabarit ne serait jamais proposé.
      CardRole.stage: Quota(0.0, 6.0),
    },
    // **Un vrai coût de mise en jeu**, contrairement à Pokémon dont le `cmc`
    // porte les points de vie. Le creux à 3 DON!! est authentique et non un
    // artefact : 3,5 % du corpus contre 9,5 % à 2 et 19,2 % à 4 — vérifié en
    // regardant les cartes, les coûts 1 étant les personnages de recherche et
    // les coûts 4 les finisseurs.
    curve: [
      CurveStep(0, 1, Quota(28.0, 20.0)),
      CurveStep(2, 2, Quota(8.0, 16.0)),
      CurveStep(3, 3, Quota(0.0, 6.0)),
      CurveStep(4, 4, Quota(20.0, 10.0)),
      CurveStep(5, 6, Quota(22.0, 12.0)),
      CurveStep(7, 99, Quota(18.0, 16.0)),
    ],
    // Un seul format, tous archétypes mêlés : 12 points d'écart sur les deux
    // familles principales, 20 sur le bas de courbe. La médiane décrit un deck
    // plausible, pas un deck existant.
    reliability: BlueprintReliability.averaged,
  );

  /// Disney Lorcana — **mesuré sur 124 listes**, le plus petit corpus du projet.
  ///
  /// **La taille est un contrat** : 60 cartes, écart interquartile 0 — la même
  /// figure que Pokémon et One Piece. Aucune carte de commandement : un deck
  /// Lorcana n'a ni leader ni général, contrairement à SWU, One Piece et
  /// Commander.
  ///
  /// **`usesColorIdentity` est vrai, et la règle est plus stricte que partout
  /// ailleurs : les 124 decks jouent EXACTEMENT deux encres**, pas moins, pas
  /// plus. One Piece tient à 100 % sur l'inclusion dans l'identité du leader ;
  /// ici c'est un cardinal, et le corpus ne s'en écarte jamais.
  ///
  /// **Le corpus est mince, et il faut le savoir.** 124 listes contre 1 490 pour
  /// One Piece et 17 295 pour Pokémon : les écarts interquartiles sont larges
  /// (21,7 points sur les personnages) parce que le corpus est petit, non parce
  /// que le jeu est libre. Les Lieux y sont à 0,0 % avec un écart nul — aucun
  /// des 124 decks n'en joue —, ce qui décrit ce corpus-là et pas forcément le
  /// jeu. Le gabarit se resserrera à mesure que Limitless publiera.
  static const lorcanaCore = DeckBlueprint(
    size: 60,
    // La règle du jeu, et le corpus ne la dépasse jamais : maximum observé 4,
    // sur 124 listes. C'est le seul corpus du projet sans une seule saisie
    // fautive au-dessus du plafond.
    maxCopies: 4,
    needsCommander: false,
    // Aucun terrain : l'encre se paie en défaussant une carte de sa main.
    // `null` et non zéro — il n'y a rien à manquer.
    lands: null,
    curveLabel: 'encre',
    roles: {
      CardRole.character: Quota(83.3, 21.7),
      CardRole.action: Quota(14.6, 18.3),
      // **La Chanson recouvre l'Action**, elle ne la découpe pas : sa ligne de
      // type vaut « Action Song » et elle compte dans les deux. C'est le même
      // recouvrement volontaire que chez Magic, où une créature qui produit du
      // mana est créature *et* rampe. La somme des parts dépasse donc 100 %,
      // et c'est correct.
      CardRole.song: Quota(10.0, 7.8),
      CardRole.item: Quota(0.0, 5.0),
      // Écart nul sur 124 listes dont aucune n'en joue. Le quota reste déclaré
      // pour que le rôle existe à l'écran ; il ne fera rien proposer tant que
      // le corpus n'en montrera pas.
      CardRole.location: Quota(0.0, 0.0),
    },
    // **Une vraie courbe**, contrairement à Pokémon dont le `cmc` porte les
    // points de vie. Elle est remarquablement plate — de 13,3 % à 20,0 % sur
    // les cinq premiers paliers —, ce qui décrit un jeu où l'on joue une carte
    // par tour du début à la fin.
    curve: [
      CurveStep(0, 1, Quota(13.3, 6.7)),
      CurveStep(2, 2, Quota(20.0, 6.7)),
      CurveStep(3, 3, Quota(18.3, 18.3)),
      CurveStep(4, 4, Quota(18.3, 6.7)),
      CurveStep(5, 6, Quota(18.3, 11.7)),
      CurveStep(7, 99, Quota(8.3, 18.3)),
    ],
    reliability: BlueprintReliability.averaged,
  );

  /// Wankul — **le premier gabarit du projet qui ne vient pas d'un corpus.**
  ///
  /// Les six autres sont mesurés sur des listes de tournoi, de 124 pour Lorcana
  /// à 17 295 pour Pokémon. Wankul n'en a aucune, et ce n'est pas un retard
  /// d'ingestion : **aucune source ne publie de decklists pour ce jeu**, pas
  /// plus qu'aucun index ne le cote carte par carte. Huit pistes ont été
  /// vérifiées — voir `docs/multi-game.md` § 9.
  ///
  /// Ce qui existe en revanche, c'est le **règlement**, publié par le wiki
  /// communautaire et servi par son API MediaWiki :
  ///
  /// - **50 cartes** exactement ;
  /// - **10 terrains** ;
  /// - **40 personnages**, dont cinq scoreurs au maximum ;
  /// - **3 exemplaires** par carte, les variantes ultra-rares et légendaires ne
  ///   comptant pas comme des cartes différentes.
  ///
  /// **Les écarts sont donc nuls, et c'est exact.** « Dix terrains » n'a pas de
  /// variance : ce n'est pas une médiane dont la moitié des decks s'écarte, mais
  /// une contrainte que tout deck légal respecte. D'où
  /// [BlueprintReliability.regulatory], qui existe pour dire précisément ça à
  /// l'écran.
  ///
  /// **Aucune courbe, et aucun coût.** Le catalogue ne porte pas de coût de mise
  /// en jeu pour ce jeu — les personnages se posent, les terrains se défaussent.
  /// Déclarer une courbe vide plutôt qu'une courbe inventée est la même décision
  /// que chez Pokémon, dont le `cmc` porte les points de vie.
  ///
  /// **Ce que ce gabarit ne sait pas** : quelles cartes sont des « scoreurs ».
  /// La source ne le publie pas. C'est un maximum et non un minimum, donc son
  /// ignorance ne produit aucun deck illégal — seulement un deck qui pourrait
  /// en compter plus de cinq sans qu'on le sache.
  static const wankulTournament = DeckBlueprint(
    size: 50,
    maxCopies: 3,
    needsCommander: false,
    // Dix terrains sur cinquante cartes. L'écart est nul parce que c'est une
    // règle : un deck à neuf terrains n'est pas rare, il est illégal.
    lands: Quota(20.0, 0.0),
    // **Ce jeu n'a pas de couleurs**, et le défaut vaut `true`. Sans cette
    // ligne, l'écran annonçait « remplir 50 cases dans ces couleurs » à un
    // joueur Wankul — le filtre ne faisait rien, mais la phrase promettait une
    // contrainte inexistante. Même correction que Yu-Gi-Oh.
    usesColorIdentity: false,
    roles: {
      CardRole.character: Quota(80.0, 0.0),
    },
    // Le catalogue ne porte aucun coût de mise en jeu pour ce jeu. Une courbe
    // vide dit « ce jeu n'en a pas » ; une courbe inventée dirait n'importe
    // quoi avec assurance.
    curve: [],
    reliability: BlueprintReliability.regulatory,
  );

  /// Mesuré sur 190 précons. Le format le plus régulier du corpus.
  static const commander = DeckBlueprint(
    size: 100,
    maxCopies: 1,
    needsCommander: true,
    lands: Quota(38, 2),
    roles: {
      CardRole.creature: Quota(29, 7),
      CardRole.draw: Quota(12, 4),
      CardRole.ramp: Quota(6, 3),
      CardRole.removal: Quota(6, 4),
    },
    curve: [
      CurveStep(0, 1, Quota(4, 2)),
      CurveStep(2, 2, Quota(13, 6)),
      CurveStep(3, 3, Quota(15, 5)),
      CurveStep(4, 4, Quota(12, 5)),
      CurveStep(5, 6, Quota(13, 5)),
      CurveStep(7, 99, Quota(4, 4)),
    ],
    reliability: BlueprintReliability.tight,
  );

  /// Mesuré sur 725 decks de tournoi. Seuls les terrains y sont réguliers
  /// (écart de 3 points) ; tout le reste mêle des archétypes.
  static const pauper = DeckBlueprint(
    size: 60,
    maxCopies: 4,
    needsCommander: false,
    lands: Quota(30, 3),
    roles: {
      CardRole.creature: Quota(30, 15),
      CardRole.draw: Quota(25, 23),
      CardRole.ramp: Quota(7, 7),
      CardRole.removal: Quota(5, 10),
    },
    curve: [
      CurveStep(0, 1, Quota(22, 12)),
      CurveStep(2, 2, Quota(25, 17)),
      CurveStep(3, 3, Quota(7, 12)),
      CurveStep(4, 4, Quota(7, 10)),
      CurveStep(5, 6, Quota(7, 12)),
      CurveStep(7, 99, Quota(0, 3)),
    ],
    reliability: BlueprintReliability.averaged,
  );

  /// Mesuré sur 113 decks de tournoi. Ses terrains sont presque tous
  /// spéciaux — 5 % de terrains de base contre 30 % — ce qu'une collection
  /// ordinaire ne peut pas fournir.
  static const modern = DeckBlueprint(
    size: 60,
    maxCopies: 4,
    needsCommander: false,
    lands: Quota(35, 7),
    roles: {
      CardRole.creature: Quota(27, 17),
      CardRole.draw: Quota(15, 10),
      CardRole.ramp: Quota(2, 2),
      CardRole.removal: Quota(7, 7),
    },
    curve: [
      CurveStep(0, 1, Quota(23, 18)),
      CurveStep(2, 2, Quota(18, 13)),
      CurveStep(3, 3, Quota(8, 7)),
      CurveStep(4, 4, Quota(2, 7)),
      CurveStep(5, 6, Quota(3, 8)),
      CurveStep(7, 99, Quota(0, 7)),
    ],
    reliability: BlueprintReliability.averaged,
  );

  /// Les quatre formats Yu-Gi-Oh, mesurés sur leurs 3 935 decks
  /// (`python -m app.measure.deck_anatomy --game yugioh`).
  ///
  /// **Leur taille est un contrat, pas une tendance** : 40 cartes, écart
  /// interquartile de 0 à 1 sur les quatre formats. Aucun format Magic
  /// n'approche cette régularité. Trois exemplaires au maximum, vérifié sur tout
  /// le corpus.
  ///
  /// **Leur composition, elle, est dispersée** — 12 à 24 points d'écart sur les
  /// monstres. Comme le Pauper et le Modern, ces formats mêlent des archétypes
  /// dont la médiane décrit un deck jouable mais qui ne ressemble à aucun deck
  /// réel. D'où [BlueprintReliability.averaged] partout.
  ///
  /// Les paliers portent le **Niveau** et non un coût de mana : on invoque sans
  /// tribut jusqu'à 4, avec un tribut à 5 et 6, avec deux au-delà. C'est le seul
  /// découpage qui décrive une contrainte réelle du jeu.
  /// Pokémon Standard — mesuré sur **17 295 decks**, le plus gros corpus du
  /// projet (`deck_anatomy --game pokemon`).
  ///
  /// **La taille est le chiffre le plus net qu'on ait mesuré** : 60 cartes,
  /// écart interquartile **0,0**. Pas un deck du corpus ne s'en écarte.
  ///
  /// **Ce jeu ne dose que trois choses**, et elles partitionnent le deck :
  /// Dresseurs 51,7 %, Pokémon 33,3 %, Énergies 15,0 %. Les trois portent le
  /// même écart de 6,7 points — une régularité qu'aucun autre jeu du corpus
  /// n'affiche sur ses familles principales.
  ///
  /// **Aucune courbe, et c'est mesuré plutôt qu'omis.** L'ingestion range les
  /// points de vie dans `cmc` faute d'un champ dédié — 70, 60 et 80 sont les
  /// valeurs les plus fréquentes. Découper les PV en paliers décrirait la
  /// robustesse des créatures, pas une contrainte de construction : rien ne se
  /// paie dans ce jeu, on pose une énergie par tour et c'est tout. C'est le même
  /// piège que le Niveau de Yu-Gi-Oh, en pire — là-bas au moins le Niveau
  /// conditionne l'invocation.
  ///
  /// **Ni terrains ni identité de couleur.** Les Énergies jouent le rôle des
  /// terrains mais sont des cartes du deck, comptées dans les 60 et soumises au
  /// quota ci-dessus — d'où `lands: null`, qui dit « cette notion n'existe pas »
  /// là où un zéro se lirait comme un manque. Les types (Feu, Eau…) n'imposent
  /// aucune contrainte de construction : un deck mélange ce qu'il veut.
  ///
  /// Les sous-familles Dresseur s'ajoutent au lieu de découper — un Supporter
  /// reste un Dresseur —, comme une créature Magic qui produit du mana compte
  /// dans deux rôles.
  static const pokemonStandard = DeckBlueprint(
    size: 60,
    // La règle du jeu, et le corpus la confirme : maximum observé 4 sur les
    // 17 295 decks, énergies de base exclues du décompte puisqu'illimitées.
    maxCopies: 4,
    needsCommander: false,
    lands: null,
    usesColorIdentity: false,
    curveLabel: 'pv',
    roles: {
      CardRole.trainer: Quota(51.7, 6.7),
      CardRole.pokemon: Quota(33.3, 6.7),
      CardRole.energy: Quota(15.0, 6.7),
      CardRole.supporter: Quota(16.7, 3.3),
      CardRole.item: Quota(26.7, 6.7),
      CardRole.stadium: Quota(5.0, 3.3),
    },
    curve: [],
    // Un seul format, un seul archétype ? Non : Standard mêle tous les decks du
    // méta, et ses écarts de 6,7 points le disent. La médiane décrit un deck
    // plausible, pas un deck existant.
    reliability: BlueprintReliability.averaged,
  );

  static const edison = DeckBlueprint(
    size: 40,
    extraSize: 15,
    maxCopies: 3,
    needsCommander: false,
    lands: null,
    usesColorIdentity: false,
    curveLabel: 'niveau',
    roles: {
      CardRole.monster: Quota(52.5, 12.2),
      CardRole.spell: Quota(21.4, 9.8),
      CardRole.trap: Quota(24.4, 16.6),
      CardRole.quickSpell: Quota(4.9, 2.6),
      CardRole.continuousTrap: Quota(0, 2.3),
    },
    curve: [
      CurveStep(1, 4, Quota(37.5, 6.9)),
      CurveStep(5, 6, Quota(7.5, 7.2)),
      CurveStep(7, 99, Quota(5, 5)),
    ],
    reliability: BlueprintReliability.averaged,
  );

  /// L'Extra Deck y compte 11 cartes et non 15, et l'écart est large : 187 des
  /// 484 decks Goat n'en ont **aucune**. C'est l'époque qui parle — seules les
  /// Fusions existaient alors, et beaucoup de decks s'en passaient.
  static const goat = DeckBlueprint(
    size: 40,
    extraSize: 11,
    maxCopies: 3,
    needsCommander: false,
    lands: null,
    usesColorIdentity: false,
    curveLabel: 'niveau',
    roles: {
      CardRole.monster: Quota(45, 15),
      CardRole.spell: Quota(30, 10),
      CardRole.trap: Quota(22.5, 12.5),
      CardRole.quickSpell: Quota(4.9, 4.8),
      CardRole.continuousTrap: Quota(2.4, 2.5),
    },
    curve: [
      CurveStep(1, 4, Quota(35, 2.5)),
      CurveStep(5, 6, Quota(10, 12.5)),
      CurveStep(7, 99, Quota(2.5, 0)),
    ],
    reliability: BlueprintReliability.averaged,
  );

  static const redu = DeckBlueprint(
    size: 40,
    extraSize: 15,
    maxCopies: 3,
    needsCommander: false,
    lands: null,
    usesColorIdentity: false,
    curveLabel: 'niveau',
    roles: {
      CardRole.monster: Quota(43.9, 16.2),
      CardRole.spell: Quota(27.5, 15.8),
      CardRole.trap: Quota(27.5, 16.6),
      CardRole.quickSpell: Quota(7.6, 7.5),
      CardRole.continuousTrap: Quota(2.5, 5),
    },
    curve: [
      CurveStep(1, 4, Quota(40, 16.4)),
      CurveStep(5, 6, Quota(0, 2.5)),
      CurveStep(7, 99, Quota(2.5, 9.8)),
    ],
    reliability: BlueprintReliability.averaged,
  );

  /// 81 decks seulement, et les écarts les plus larges du jeu — 24 points sur
  /// les magies. La médiane y est la plus fragile des quatre.
  static const hat = DeckBlueprint(
    size: 40,
    extraSize: 15,
    maxCopies: 3,
    needsCommander: false,
    lands: null,
    usesColorIdentity: false,
    curveLabel: 'niveau',
    roles: {
      CardRole.monster: Quota(45, 12.2),
      CardRole.spell: Quota(26.8, 24),
      CardRole.trap: Quota(25, 20),
      CardRole.quickSpell: Quota(7.3, 10),
      CardRole.continuousTrap: Quota(5, 7.5),
    },
    curve: [
      CurveStep(1, 4, Quota(37.5, 17.5)),
      CurveStep(5, 6, Quota(0, 7.5)),
      CurveStep(7, 99, Quota(0, 17.5)),
    ],
    reliability: BlueprintReliability.averaged,
  );
}
