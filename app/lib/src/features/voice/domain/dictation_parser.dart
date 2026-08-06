/// Découpage d'une dictée en noms de cartes.
///
/// La reconnaissance vocale rend un flux de texte, pas des cartes. Ce module le
/// transforme en candidats — c'est la seule partie de la saisie vocale qui soit
/// pure, donc la seule vraiment testable, et c'est là que vivent les décisions
/// qui font la différence à l'usage.
///
/// **Le moteur vocal ne connaît pas Magic.** « Sol Ring » revient en « sol
/// ring », « soleil ring », « sole rings » ; les noms français passent mieux
/// mais les accents sautent. On ne cherche donc pas à corriger ici : la
/// recherche du catalogue est déjà tolérante aux fautes, et lui envoyer le texte
/// brut donne de meilleurs résultats qu'une correction naïve appliquée avant.
///
/// Ce qui est traité ici, en revanche, c'est ce que la recherche ne peut pas
/// deviner : les quantités dictées (« quatre foudre »), les séparateurs de
/// dictée continue (« puis », « ensuite »), et le bruit de langage.
library;

/// Une carte dictée : ce qu'il faut chercher, et en combien d'exemplaires.
typedef DictatedCard = ({String query, int quantity});

/// Mots qui séparent deux cartes dans une dictée continue.
const _separators = {
  'puis',
  'ensuite',
  'et',
  'après',
  'apres',
  'virgule',
  'suivant',
};

/// Formules parasites que le locuteur ajoute sans le vouloir.
const _fillers = {'euh', 'alors', 'donc', 'voilà', 'voila', 'bon', 'la carte'};

/// Quantités dictées en toutes lettres, jusqu'à la limite utile : un deck
/// n'autorise que quatre exemplaires, le Commander un seul.
const _spelledNumbers = {
  'un': 1,
  'une': 1,
  'deux': 2,
  'trois': 3,
  'quatre': 4,
  'cinq': 5,
  'six': 6,
  'sept': 7,
  'huit': 8,
  'neuf': 9,
  'dix': 10,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
};

/// Au-delà, il s'agit sûrement d'un nombre entendu dans un nom de carte plutôt
/// que d'une quantité voulue.
const _maxQuantity = 20;

/// Découpe une dictée en cartes.
///
/// Renvoie une liste vide plutôt que de deviner lorsque rien d'exploitable n'est
/// dit : proposer une carte au hasard sur un raclement de gorge serait pire que
/// de ne rien proposer.
List<DictatedCard> parseDictation(String transcript) {
  final normalized = transcript.toLowerCase().trim();
  if (normalized.isEmpty) return const [];

  final segments = <List<String>>[];
  var current = <String>[];

  for (final rawWord in normalized.split(RegExp(r'[\s,;]+'))) {
    final word = rawWord.replaceAll(RegExp(r'[.!?]+$'), '');
    if (word.isEmpty) continue;

    if (_separators.contains(word)) {
      if (current.isNotEmpty) segments.add(current);
      current = <String>[];
      continue;
    }
    if (_fillers.contains(word)) continue;
    current.add(word);
  }
  if (current.isNotEmpty) segments.add(current);

  final cards = <DictatedCard>[];
  for (final words in segments) {
    final card = _toCard(words);
    if (card != null) cards.add(card);
  }
  return cards;
}

DictatedCard? _toCard(List<String> words) {
  var quantity = 1;
  var rest = words;

  // Une quantité n'a de sens qu'en tête : « quatre foudre », jamais « foudre
  // quatre » — qui serait plutôt un nom de carte contenant un nombre.
  final first = words.first;
  final spelled = _spelledNumbers[first];
  final digits = int.tryParse(first);

  if (spelled != null || digits != null) {
    // Un segment réduit à un nombre est une dictée coupée, pas une carte :
    // chercher « quatre » remonterait n'importe quoi.
    if (words.length == 1) return null;

    final value = spelled ?? digits!;
    if (value > 0 && value <= _maxQuantity) {
      quantity = value;
      rest = words.sublist(1);
    }
  }

  final query = rest.join(' ').trim();
  if (query.isEmpty) return null;
  // Un seul caractère ne peut pas désigner une carte ; c'est du bruit.
  if (query.length < 2) return null;

  return (query: query, quantity: quantity);
}
