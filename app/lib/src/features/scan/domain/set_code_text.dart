/// Lecture du code d'extension parmi les textes lus sur une photo de carte.
///
/// **Pourquoi le code d'extension et pas le numéro de collection.** Une case de
/// classeur est le couple `(set_code, collector_number)`, et le premier réflexe
/// est de lire la ligne qui les porte tous les deux : « 0412/0853 U • MSH • FR ».
/// Mesuré sur une photo réelle (`test/.../measured_spread.dart`), le numéro en
/// sort mutilé — « C O0O5 », « 02 » — parce qu'il est imprimé deux fois plus
/// petit que le nom : 0,006 de la hauteur de l'image contre 0,016. Le **code**,
/// lui, sort juste : il est en capitales, plus large, et deux fois sur deux dans
/// cette lecture.
///
/// Or le code suffit presque toujours. Mesuré au catalogue
/// (`api/app/measure/edition_from_set.py`) : le couple (carte, extension)
/// désigne **une case unique dans 83,1 %** des cas — 87,9 % en français — et
/// 72 % des exemplaires réellement joués. La carte étant déjà identifiée par son
/// nom, lire son extension précise donc son édition sans jamais lire le numéro,
/// et sans caméra fixe.
///
/// **On ne cherche pas un code dans l'absolu.** L'appelant fournit les
/// extensions où la carte identifiée existe — de une à quelques dizaines sur les
/// 695 du catalogue. Un mot du texte de règles ou un nom d'illustrateur n'a donc
/// aucune chance de désigner une extension par accident : il faudrait qu'il
/// coïncide avec l'une des rares extensions de cette carte précise.
///
/// Logique délibérément séparée du plugin de reconnaissance, comme
/// [card_name_text.dart] : elle s'éprouve sur des lignes figées, sans appareil
/// photo ni service natif.
library;

import 'card_name_text.dart';

/// Ce qui sépare deux mots sur la ligne d'une carte.
///
/// Les puces imprimées entre le numéro, le code et la langue (« • », « · ») sont
/// rendues telles quelles par la reconnaissance, et parfois collées au code.
final _separators = RegExp(r'[^A-Za-z0-9]+');

/// Le code d'extension lu, ou `null` si rien de sûr n'a été trouvé.
///
/// [candidates] est l'ensemble des codes où la carte identifiée existe, tels
/// que le catalogue les écrit — en minuscules.
///
/// Rend `null` dès qu'il y a doute : aucun code trouvé, ou deux codes
/// différents. **Une édition fausse est pire qu'une édition absente** — elle
/// range la carte dans la mauvaise case et fausse le taux de complétion, là où
/// l'absence laisse un état de plein droit, « je possède cette carte, je n'ai
/// pas dit laquelle ».
String? readSetCode(List<ReadLine> lines, Set<String> candidates) {
  if (candidates.isEmpty) return null;

  // Le code est imprimé en capitales ; la comparaison l'exige. Sans cela, le
  // « one » d'un texte de règles anglais désignerait l'extension ONE — et les
  // textes de règles occupent la moitié des lignes lues sur une carte.
  final wanted = {for (final code in candidates) code.toUpperCase(): code};

  String? found;
  for (final line in lines) {
    for (final word in line.text.split(_separators)) {
      final match = wanted[word];
      if (match == null) continue;
      // Deux extensions distinctes : sur un étalement, la ligne d'une carte
      // voisine peut entrer dans le champ. Deviner laquelle est la bonne
      // serait deviner tout court.
      if (found != null && found != match) return null;
      found = match;
    }
  }
  return found;
}
