/// Le vrai dos des cartes d'un jeu, quand son éditeur en publie un.
///
/// **Pourquoi ce fichier existe.** Les feuilles qui défilent montraient un dos
/// *dessiné* — un motif générique. Il fait illusion à l'arrêt et ne trompe
/// personne à l'écran : ce qu'on attend d'un classeur Magic, c'est le dos
/// Magic ; d'un classeur Pokémon, le dos Pokémon. Un motif inventé dit
/// « carte » là où il faudrait dire « **cette** carte-là ».
///
/// **On pointe, on ne réhéberge pas.** C'est la règle du projet (§IV.3, §IV.9)
/// et c'est ce que l'application fait déjà de chaque illustration : l'URL est
/// celle de l'éditeur ou de la source qui la sert, et pas un octet n'est copié
/// ailleurs. Le seul jeu dont le projet héberge les images est Wankul, sous
/// autorisation nominative (§IV.10) — et cette autorisation ne porte pas sur un
/// dos, qui n'existe pas dans ce qui a été fourni.
///
/// **Deux jeux sur huit, et c'est une constatation, pas un abandon.** Chaque URL
/// ci-dessous a été vérifiée par une requête réelle ; les six autres jeux sont
/// absents parce qu'**aucune des sources que le projet utilise ne publie leur
/// dos** :
///
/// | Jeu | Source | Dos publié |
/// |---|---|---|
/// | Magic | Scryfall | **oui** — `backs.scryfall.io`, ratio 0,7157 |
/// | Yu-Gi-Oh | YGOPRODeck | **oui**, mais sans CORS — voir plus bas |
/// | Pokémon | TCGdex | non — son schéma d'images est par carte, sans dos commun |
/// | Riftbound | Riftcodex | non — `media.image_url` est par carte |
/// | One Piece | optcgapi | non — `card_image` est par carte |
/// | Lorcana | Lorcast | non — `image_uris` est par carte |
/// | Star Wars Unlimited | SWU-DB | non |
/// | Wankul | Wankuldex | non |
///
/// **Et il ne suffit pas qu'une URL réponde : le calque est un navigateur.**
/// `backs.scryfall.io` envoie `Access-Control-Allow-Origin: *` — le dos
/// Magic se charge donc dans la *browser source* OBS comme dans
/// l'application. `images.ygoprodeck.com` **n'envoie aucun en-tête CORS** :
/// le dos Yu-Gi-Oh se charge sur mobile et se fait **bloquer en silence**
/// sur le web, où il retombe sur le motif dessiné. C'est une limite de la
/// source, pas du code, et elle ne se voit ni dans un code de retour ni à
/// la lecture — il faut la demander à l'hôte, en-tête `Origin` en main. Le
/// calque n'interrogeant que Magic aujourd'hui, elle ne coûte rien ; elle
/// coûtera le jour où il saura son jeu.
///
/// **Deviner une URL serait la faute exacte que ce projet a déjà payée** :
/// aller chercher un fichier au jugé sur le CDN d'un éditeur, c'est au mieux un
/// 404, au pire une ressource qu'on n'a pas le droit de servir. Un jeu dont le
/// dos n'est pas publié garde donc le motif dessiné de `sheet_face.dart` — un
/// repli assumé, pas une panne. Pour en ajouter un : trouver la source qui le
/// publie, vérifier d'une requête, l'inscrire ici.
///
/// **L'image est décodée une fois par session.** Une feuille de classeur en
/// montre neuf, trois feuilles volent, dix lamelles les découpent : la même
/// `ui.Image` est dessinée jusqu'à deux cent soixante-dix fois par image de
/// vidéo, et c'est *moins cher* que le motif dessiné qu'elle remplace.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../common/card_image.dart';
import '../../../config/selected_game.dart';

/// Le dos officiel d'un jeu, ou `null` si aucune source n'en publie.
///
/// Vérifiées le 2026-08-25 : les deux rendent 200 et un rapport de carte.
const Map<Game, String> cardBackUrls = {
  Game.magic:
      'https://backs.scryfall.io/normal/'
      '0/a/0aeebaf5-8c7d-4636-9e82-8c27447861f7.jpg',
  Game.yugioh: 'https://images.ygoprodeck.com/images/cards/back.jpg',
};

/// L'URL du dos d'un jeu, ou `null`.
String? cardBackUrl(Game game) => cardBackUrls[game];

/// Les décodages en cours ou faits, par URL.
///
/// **Un échec est mémorisé lui aussi.** Sans cela, un dos indisponible serait
/// redemandé à chaque apparition — quatre fois par minute sur un direct, pour
/// une réponse qui ne changera pas.
final Map<String, Future<ui.Image?>> _decoded = {};

/// Charge et décode le dos d'un jeu.
///
/// Rend `null` si le jeu n'en a pas ou si le chargement échoue : le calque
/// retombe alors sur le motif dessiné, sans rien afficher d'une erreur.
Future<ui.Image?> loadCardBack(Game game) {
  final url = cardBackUrl(game);
  if (url == null) return Future<ui.Image?>.value();
  return _decoded.putIfAbsent(url, () => _decode(url));
}

/// **Par `CardImageProvider`, comme toute image de carte.** C'est le point de
/// passage unique du projet : il apporte le cache disque, la reprise hors
/// ligne, et le délai de garde. Un `NetworkImage` ici aurait redemandé le dos à
/// chaque démarrage à froid.
Future<ui.Image?> _decode(String url) {
  final completer = Completer<ui.Image?>();
  final flux = CardImageProvider(url).resolve(ImageConfiguration.empty);
  late final ImageStreamListener ecoute;
  ecoute = ImageStreamListener(
    (info, _) {
      flux.removeListener(ecoute);
      if (!completer.isCompleted) completer.complete(info.image);
    },
    onError: (_, _) {
      flux.removeListener(ecoute);
      if (!completer.isCompleted) completer.complete(null);
    },
  );
  flux.addListener(ecoute);
  return completer.future;
}
