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

/// Fraction supérieure de la carte où chercher le nom.
///
/// Un tiers plutôt qu'un dixième : la photo inclut souvent un peu de table
/// au-dessus de la carte, ce qui décale tout vers le bas. Mieux vaut ratisser
/// large et laisser la recherche floue écarter les intrus — un type de carte
/// (« Rituel », « Artefact ») ne ressemble à aucun nom du catalogue.
const double _nameZone = 0.34;

/// Lignes trop courtes pour être un nom : une lettre isolée, un symbole de mana
/// mal interprété, un chiffre de force.
const int _minNameLength = 3;

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
    final text = _clean(line.text);
    if (text.length < _minNameLength) continue;
    if (_noise.hasMatch(text)) continue;
    if (_setMarkers.hasMatch(text)) continue;
    if (_shortCaps.hasMatch(text.replaceAll(' ', ''))) continue;
    if (!seen.add(text.toLowerCase())) continue;
    candidates.add(text);
    if (candidates.length >= limit) break;
  }

  return candidates;
}

/// Nettoie une ligne lue.
///
/// Les caractères parasites viennent surtout des bordures du cadre, que la
/// reconnaissance interprète parfois comme des traits ou des points.
String _clean(String raw) {
  return raw
      .replaceAll(RegExp(r'[|_~^`]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
