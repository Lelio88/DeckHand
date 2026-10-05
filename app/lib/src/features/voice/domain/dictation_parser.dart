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
/// dictée continue (« puis », « ensuite »), le bruit de langage, et ce qui
/// suit le nom — l'édition (« édition M21 numéro 137 ») et la finition
/// (« brillante », « foil »).
///
/// **Chaque mot réservé est aussi un mot de nom de carte.** « Extension de la
/// sphère », « Into the Story: Assassin Edition », « Plan brillant »,
/// « Foil » : relevés dans le catalogue avant de fixer la grammaire, ils en
/// dictent les limites. Un mot-clé d'édition ne compte que s'il a un mot avant
/// lui et un après ; « brillant » ne vaut finition qu'après une extension ou
/// derrière « en » — six cartes françaises finissent par ce mot.
///
/// Grammaire d'un segment :
///
/// ```text
/// [quantité] <carte> [finition] [édition|extension <nom ou code>
///                               [finition] [numéro <n>]] [finition]
/// finition := [en|in] (foil | brillant | brillante | …)
/// ```
library;

import 'spoken_printing.dart';

/// Une carte dictée : ce qu'il faut chercher, en combien d'exemplaires, et ce
/// qui a été dit de son impression.
final class DictatedCard {
  const DictatedCard(
    this.query, {
    this.quantity = 1,
    this.printing = SpokenPrinting.none,
  });

  final String query;
  final int quantity;
  final SpokenPrinting printing;

  @override
  bool operator ==(Object other) =>
      other is DictatedCard &&
      other.query == query &&
      other.quantity == quantity &&
      other.printing == printing;

  @override
  int get hashCode => Object.hash(query, quantity, printing);

  @override
  String toString() =>
      'DictatedCard($query, quantity: $quantity, printing: $printing)';
}

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

/// Mots qui annoncent l'extension. Le moteur rend « édition » avec ou sans
/// accent selon la langue choisie.
const _editionMarkers = {'édition', 'edition', 'extension'};

/// Mots qui annoncent le numéro de collection, dans une extension.
const _numberMarkers = {'numéro', 'numero', 'n°', 'number'};

/// Mots qui annoncent la finition : « en foil », « in foil ». Annoncée, elle
/// se reconnaît même là où « brillant » seul appartiendrait au nom.
const _finishAnnouncers = {'en', 'in'};

/// Finitions dites. « foil » est le mot des joueurs, « brillante » celui de
/// l'application.
const _foilWords = {
  'foil',
  'foils',
  'brillant',
  'brillante',
  'brillants',
  'brillantes',
};

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

  final (name, printing) = _splitPrinting(rest);

  final query = name.join(' ').trim();
  if (query.isEmpty) return null;
  // Un seul caractère ne peut pas désigner une carte ; c'est du bruit.
  if (query.length < 2) return null;

  return DictatedCard(query, quantity: quantity, printing: printing);
}

/// Sépare le nom de la carte de ce qui est dit de son impression.
///
/// La finition se reconnaît à trois places : en fin de segment, juste avant
/// le mot-clé d'édition (« foudre en foil édition m21 ») et juste avant le
/// numéro (« édition m21 brillante numéro 137 »).
(List<String>, SpokenPrinting) _splitPrinting(List<String> words) {
  var rest = words;
  var foil = false;

  final last = rest.isEmpty ? null : rest.sublist(0, rest.length - 1);
  final atEnd = _finishLength(
    rest,
    bareAllowed: last != null && _editionMarkerAt(last) != null,
  );
  if (atEnd > 0) {
    foil = true;
    rest = rest.sublist(0, rest.length - atEnd);
  }

  final marker = _editionMarkerAt(rest);
  if (marker == null) {
    return (rest, SpokenPrinting(foil: foil));
  }

  var name = rest.sublist(0, marker);
  // Devant le mot-clé, « brillant » seul appartient au nom : « Plan brillant
  // édition m21 ».
  final beforeMarker = _finishLength(name, bareAllowed: false);
  if (beforeMarker > 0) {
    foil = true;
    name = name.sublist(0, name.length - beforeMarker);
  }

  var setWords = rest.sublist(marker + 1);
  String? number;
  final numberAt = setWords.indexWhere(_numberMarkers.contains);
  // « édition numéro 137 » : sans extension devant lui, le numéro ne désigne
  // rien et reste dans ce qu'on cherchera — en vain, et la ligne le dira.
  if (numberAt > 0 && numberAt < setWords.length - 1) {
    number = setWords.sublist(numberAt + 1).join();
    setWords = setWords.sublist(0, numberAt);
    final beforeNumber = _finishLength(setWords, bareAllowed: true);
    if (beforeNumber > 0) {
      foil = true;
      setWords = setWords.sublist(0, setWords.length - beforeNumber);
    }
  }

  return (
    name,
    SpokenPrinting(set: setWords.join(' '), number: number, foil: foil),
  );
}

/// Nombre de mots qui, en fin de [words], disent la finition : 0, 1 ou 2.
///
/// Un mot au moins doit rester devant : « foil » seul est une carte. « foil »
/// vaut finition partout, « en » ou « in » l'annoncent toujours, et
/// « brillant » seul ne la dit que si [bareAllowed] — c'est-à-dire derrière
/// une extension, là où aucun nom de carte ne se poursuit.
int _finishLength(List<String> words, {required bool bareAllowed}) {
  if (words.length < 2 || !_foilWords.contains(words.last)) return 0;
  final announced =
      words.length > 2 && _finishAnnouncers.contains(words[words.length - 2]);
  if (announced) return 2;
  if (words.last.startsWith('foil') || bareAllowed) return 1;
  return 0;
}

/// Rang du mot-clé d'édition, s'il en est un qui a une carte avant lui et une
/// extension après lui.
int? _editionMarkerAt(List<String> words) {
  for (var i = 1; i < words.length - 1; i++) {
    if (_editionMarkers.contains(words[i])) return i;
  }
  return null;
}
