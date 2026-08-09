/// Choix du nom de carte parmi les textes lus sur une photo.
///
/// La reconnaissance de texte rend tout ce qu'elle voit : le nom, le type, les
/// règles, l'illustrateur, le copyright, le numéro de collection. Il faut en
/// extraire la seule ligne qui identifie la carte.
///
/// **Le nom est en haut, et c'est le seul repère fiable.** Sur toutes les
/// éditions depuis 1993, quel que soit le cadre, le nom occupe la première ligne
/// de la carte. Ni la taille du texte ni sa casse ne sont exploitables — elles
/// varient d'une édition à l'autre — mais la position, si.
///
/// Cette logique est délibérément séparée du plugin de reconnaissance : elle est
/// ainsi éprouvable sans appareil photo ni service natif.
library;

import 'dart:math';

/// Une ligne de texte lue sur la photo, avec sa position verticale relative.
class ReadLine {
  const ReadLine(this.text, this.top, this.height, [this.left = 0, this.width = 0]);

  final String text;

  /// Position du haut de la ligne, en fraction de la hauteur de l'image.
  final double top;

  /// Hauteur des caractères, dans la même unité.
  ///
  /// **Mesurée sur le quadrilatère incliné, jamais sur la boîte droite.** Voir
  /// [textHeightFromCorners] : la différence décide si un nom est reconnu ou
  /// écarté.
  final double height;

  /// Bord gauche de la ligne, en fraction de la largeur de l'image.
  ///
  /// Optionnel : seule la reconnaissance réelle le renseigne, les jeux d'essai
  /// s'en passent. Sert à reconstruire la géométrie d'une carte à partir de son
  /// nom — la ligne du nom étant à une place connue du gabarit.
  final double left;

  /// Largeur de la ligne, dans la même unité.
  final double width;

  double get bottom => top + height;
  double get right => left + width;
}

/// Hauteur réelle des caractères, déduite des quatre coins de la ligne.
///
/// **Pourquoi ne pas prendre la hauteur de la boîte englobante.** Celle-ci est
/// alignée sur les axes de l'image, alors que la ligne, elle, est inclinée dès
/// que la carte n'est pas parfaitement parallèle au capteur — ce qui est le cas
/// de toute photo à main levée. Sa hauteur vaut alors *hauteur des caractères +
/// longueur de la ligne × sinus de l'angle*, et le second terme écrase le
/// premier : mesuré sur une photo d'étalement réelle, la hauteur de boîte
/// corrèle à **0,965** avec le nombre de caractères. Autrement dit elle ne
/// mesurait pas la taille du texte, mais sa longueur.
///
/// La conséquence était l'exact contraire du but recherché. Le filtre censé
/// distinguer le nom — imprimé gros — de son texte de règles retenait les
/// lignes longues, donc les règles, et écartait les noms : « Agent d'Atlas »
/// (13 caractères) tombait à 0,82 fois la médiane quand « A chaque fois qu'une
/// creature que vous » (38 caractères) montait à 2,47.
///
/// Les coins suivent l'inclinaison du texte : la distance entre le coin haut et
/// le coin bas d'un même côté donne la hauteur des caractères, quelle que soit
/// l'orientation. Les deux côtés sont moyennés, la perspective les rendant
/// rarement égaux.
///
/// [fallback] sert quand la reconnaissance ne fournit pas les quatre coins.
double textHeightFromCorners(List<Point<int>> corners, double fallback) {
  if (corners.length < 4) return fallback;
  final left = _distance(corners[0], corners[3]);
  final right = _distance(corners[1], corners[2]);
  // Une ligne dégénérée — coins confondus — rendrait toutes les lignes égales
  // et neutraliserait le filtre en silence. Mieux vaut la boîte, même fausse.
  if (left + right <= 0) return fallback;
  return (left + right) / 2;
}

double _distance(Point<int> a, Point<int> b) {
  final dx = (a.x - b.x).toDouble();
  final dy = (a.y - b.y).toDouble();
  return sqrt(dx * dx + dy * dy);
}

/// Fraction supérieure de l'image où chercher le nom.
///
/// **Large, parce que la photo n'est plus recadrée.** Le tiers supérieur
/// supposait que l'image soit exactement la carte ; depuis que le recadrage est
/// facultatif, la carte peut n'occuper que la moitié de la photo et son nom se
/// retrouver au milieu. Ratisser jusqu'aux deux tiers ne coûte rien : les
/// candidats sont essayés de haut en bas et le premier qui correspond à une
/// carte gagne, si bien qu'une ligne de texte de règles n'est atteinte que
/// lorsque tout le reste a échoué — et elle ne ressemble à aucun nom.
const double _nameZone = 0.66;

/// Lignes trop courtes pour être un nom : une lettre isolée, un symbole de mana
/// mal interprété, un chiffre de force.
const int _minNameLength = 3;

/// Au-delà, c'est une phrase, pas un nom.
///
/// Le nom le plus long du catalogue tient en une quarantaine de caractères ;
/// une ligne de texte de règles en fait couramment le double. Ce plafond est ce
/// qui permet d'élargir la zone de recherche sans laisser les règles devenir
/// candidates — élargissement rendu nécessaire par les photos non recadrées.
const int _maxNameLength = 48;

/// Motifs qui ne sont jamais un nom de carte, même en haut de l'image.
///
/// Le bloc d'identification imprimé en marge (« C 0679 », « MSC★FR ») est le
/// piège principal : il précède parfois le nom dans l'ordre de lecture, et rien
/// dans sa forme ne le distingue d'un mot.
final _noise = RegExp(
  r'^\s*(\d+\s*/\s*\d+|[\d\s.,/#*]+|[A-Z]{1,3}\s*\d+|©.*|™.*)\s*$',
);

/// Symboles d'édition et de rareté, absents de tout nom de carte.
final _setMarkers = RegExp(r'[★☆✦●◆]');

/// Sigles en capitales : codes d'extension, mentions de langue.
final _shortCaps = RegExp(r'^[A-Z]{2,6}$');

/// Mots-clés de capacité, imprimés sur presque toute carte.
///
/// **Une ligne de capacités ressemble à un nom, et c'est le dernier faux positif
/// qui résistait.** « Vol, vigilance » est courte, bien formée, sans parasite :
/// le score y répond *Vigilance*, qui existe vraiment, et ni la longueur ni le
/// filtre des lignes de type ne peuvent la démasquer.
///
/// **Seuls les mots-clés permanents figurent ici.** Ce sont ceux qu'on croise
/// sur presque toutes les cartes, donc ceux qui produisent des faux positifs.
/// Les mots-clés propres à une extension sont trop rares pour valoir la charge
/// d'entretien de la liste.
const _keywords = <String>[
  // Français
  'vol', 'vigilance', 'piétinement', 'célérité', 'lien de vie', 'initiative',
  'double initiative', 'menace', 'portée', 'défenseur', 'indestructible',
  'contact mortel', 'prouesse', 'protection', 'linceul', 'persistance',
  'traverser', 'flash', 'hâte',
  // Anglais
  'flying', 'trample', 'haste', 'lifelink', 'first strike', 'double strike',
  'reach', 'defender', 'deathtouch', 'hexproof', 'ward', 'shroud', 'prowess',
  'persist', 'annihilator',
];

/// Vrai si la ligne énumère **plusieurs** capacités.
///
/// **Deux et non un, et l'écart n'est pas cosmétique.** Une carte peut
/// s'appeler *Vigilance*, *Vol* (Flight), *Lien de vie*, *Menace* ou
/// *Persistance* — écarter toute ligne faite d'un seul mot-clé les rendrait
/// invisibles au scan. Mais **aucun** des 62 959 noms du catalogue n'en contient
/// deux : un nom de carte n'énumère pas des capacités. Le pluriel est
/// exactement ce qui sépare la ligne de capacités du nom, et la règle ne coûte
/// donc rien.
///
/// Le mot doit être entier : « portée » ne doit pas se déclencher sur
/// « Emportée », ni « vol » sur « Volcan ».
bool listsKeywords(String text) {
  final low = text.toLowerCase();
  var found = 0;
  for (final keyword in _keywords) {
    if (RegExp(
      r'(^|[\s,;.])' + RegExp.escape(keyword) + r'($|[\s,;.])',
    ).hasMatch(low)) {
      found++;
      if (found >= 2) return true;
    }
  }
  return false;
}

/// Tirets ouvrant une attribution de texte d'ambiance.
///
/// La reconnaissance rend indifféremment le trait d'union, le tiret demi-cadratin
/// ou cadratin selon la police et la netteté ; les trois signent la même chose.
const _attributionDashes = '-‐‑‒–—―−';

/// Vrai si la ligne attribue un texte d'ambiance à un personnage.
///
/// **Le personnage qui parle porte souvent le nom d'une carte.** En bas d'une
/// carte, le texte d'ambiance se termine par « —Ka-Zar of the Savage Land » :
/// une citation, pas une carte posée sur la table. Le nom est pourtant exact,
/// donc le score vaut 1,00 et aucune règle de longueur ni de score ne peut s'en
/// apercevoir. Sur deux photos, cette seule cause a fabriqué trois cartes
/// fantômes.
///
/// Le tiret d'ouverture est le seul indice, et il suffit : **aucun des 63 220
/// noms indexés ne commence par un tiret**, le coût est donc nul. Mesuré sur
/// trois photos, les huit lignes ainsi ouvertes étaient toutes des attributions,
/// et aucun vrai nom n'en portait.
bool isFlavourAttribution(String text) {
  final trimmed = text.trimLeft();
  return trimmed.isNotEmpty && _attributionDashes.contains(trimmed[0]);
}

/// Vrai si la ligne commence par une minuscule.
///
/// **Un nom de carte est capitalisé, un fragment de règles ne l'est pas.** Les
/// lignes « down. » et « of turn. », arrachées à un texte de règles anglais,
/// trouvaient les cartes *Down* et *Turn* — qui existent — avec un score
/// parfait. Ni la longueur ni le score ne les distinguent : ce sont de vrais
/// noms, simplement pas ceux d'une carte présente.
///
/// Coût mesuré : **5 noms sur 63 220** commencent par une minuscule (0,008 %),
/// et ce sont des faces secondaires dont la face principale reste trouvable. Sur
/// trois photos et trente-deux cartes réelles, aucune n'a été lue en commençant
/// par une minuscule.
///
/// La première lettre est cherchée, et non le premier caractère : un nom peut
/// s'ouvrir sur un chiffre ou une ponctuation.
bool startsLowercase(String text) {
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final upper = char.toUpperCase();
    final lower = char.toLowerCase();
    if (upper == lower) continue; // ni lettre, ni casse — on poursuit
    return char == lower;
  }
  return false;
}

/// Ligne de type, qui suit immédiatement le nom sur toutes les cartes.
///
/// Sans ce filtre elle deviendrait candidate dès que le nom est mal lu, et
/// « Artefact : véhicule » ou « Creature — Human Wizard » renverrait des cartes
/// au hasard — un résultat plausible, donc plus trompeur qu'un échec franc.
final _typeLine = RegExp(
  // `legendary` et `basic` ouvrent la ligne de type en anglais, là où le
  // français place le nom du type en tête (« Créature légendaire »). Sans eux,
  // « Legendary Creature — Kree Soldier » passait pour un nom de carte.
  r'^(legendary\s+|basic\s+|snow\s+|artifact\s+)?'
  r'(cr[ÉéEe]ature|rituel|[ÉéEe]ph[ÉéEe]m[ÈèEe]re|artefact|enchantement|'
  r'terrain|planeswalker|bataille|creature|sorcery|instant|artifact|'
  r'enchantment|land|battle|kindred|tribal)',
  caseSensitive: false,
);

/// Renvoie les noms candidats, le plus probable en tête.
///
/// Plusieurs sont proposés plutôt qu'un seul : la lecture confond régulièrement
/// des caractères, et une seconde ligne permet de rattraper un nom mal lu. La
/// recherche floue côté serveur départagera.
List<String> cardNameCandidates(List<ReadLine> lines, {int limit = 3}) {
  final zone = lines.where((line) => line.top < _nameZone).toList()
    // Du plus haut au plus bas : le nom précède le type, qui précède les règles.
    ..sort((a, b) => a.top.compareTo(b.top));

  final seen = <String>{};
  final candidates = <String>[];

  for (final line in zone) {
    final text = cleanNameLine(line.text);
    if (!looksLikeCardName(text)) continue;
    if (!seen.add(text.toLowerCase())) continue;
    candidates.add(text);
    if (candidates.length >= limit) break;
  }

  return candidates;
}

/// Vrai si la ligne peut être un nom de carte.
///
/// Écarte tout ce qu'une carte porte d'autre : coût en mana, force et
/// endurance, numéro de collection, sigle d'extension, ligne de type, mention
/// de copyright, et les phrases trop longues pour être un nom.
///
/// Partagé avec le repérage d'étalements, qui applique les mêmes exclusions à
/// des lignes réparties dans toute l'image.
bool looksLikeCardName(String text, {int minLength = _minNameLength}) {
  if (text.length < minLength || text.length > _maxNameLength) return false;
  if (_noise.hasMatch(text)) return false;
  if (_setMarkers.hasMatch(text)) return false;
  if (_shortCaps.hasMatch(text.replaceAll(' ', ''))) return false;
  if (_typeLine.hasMatch(text)) return false;
  if (listsKeywords(text)) return false;
  if (isFlavourAttribution(text)) return false;
  if (startsLowercase(text)) return false;
  return true;
}

/// Nettoie une ligne lue.
///
/// Les caractères parasites viennent surtout des bordures du cadre, que la
/// reconnaissance interprète parfois comme des traits ou des points.
String cleanNameLine(String raw) {
  return raw
      .replaceAll(RegExp(r'[|_~^`]'), '')
      // **Les bordures se lisent comme des crochets.** Le cadre de la carte et
      // les symboles en marge sont parfois interprétés comme une parenthèse ou
      // un crochet collé au texte. Un tel préfixe met la ligne à l'abri de tous
      // les filtres qui s'ancrent en début de ligne : la ligne de type
      // « Éphémère », lue « [Ephémere », a ainsi produit une carte fantôme.
      // On ne les retire qu'aux extrémités — au milieu d'un nom, une
      // parenthèse peut être légitime.
      .replaceAll(RegExp(r'^[\(\[\{<«»/\\\s]+'), '')
      .replaceAll(RegExp(r'[\)\]\}>«»/\\\s]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
