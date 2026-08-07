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

/// Une ligne de texte lue sur la photo, avec sa position verticale relative.
class ReadLine {
  const ReadLine(this.text, this.top, this.height);

  final String text;

  /// Position du haut de la ligne, en fraction de la hauteur de l'image.
  final double top;

  /// Hauteur de la ligne, dans la même unité.
  final double height;

  double get bottom => top + height;
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

/// Ligne de type, qui suit immédiatement le nom sur toutes les cartes.
///
/// Sans ce filtre elle deviendrait candidate dès que le nom est mal lu, et
/// « Artefact : véhicule » ou « Creature — Human Wizard » renverrait des cartes
/// au hasard — un résultat plausible, donc plus trompeur qu'un échec franc.
final _typeLine = RegExp(
  r'^(cr[ÉéEe]ature|rituel|[ÉéEe]ph[ÉéEe]m[ÈèEe]re|artefact|enchantement|'
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
bool looksLikeCardName(String text) {
  if (text.length < _minNameLength || text.length > _maxNameLength) return false;
  if (_noise.hasMatch(text)) return false;
  if (_setMarkers.hasMatch(text)) return false;
  if (_shortCaps.hasMatch(text.replaceAll(' ', ''))) return false;
  if (_typeLine.hasMatch(text)) return false;
  return true;
}

/// Nettoie une ligne lue.
///
/// Les caractères parasites viennent surtout des bordures du cadre, que la
/// reconnaissance interprète parfois comme des traits ou des points.
String cleanNameLine(String raw) {
  return raw
      .replaceAll(RegExp(r'[|_~^`]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
