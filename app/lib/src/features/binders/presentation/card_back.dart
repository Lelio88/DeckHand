/// Le vrai dos des cartes d'un jeu, servi par le dépôt d'images du projet.
///
/// **Pourquoi ce fichier existe.** Les feuilles qui défilent montraient un dos
/// *dessiné* — un motif générique. Il fait illusion à l'arrêt et ne trompe
/// personne à l'écran : ce qu'on attend d'un classeur Magic, c'est le dos
/// Magic ; d'un classeur Pokémon, le dos Pokémon. Un motif inventé dit
/// « carte » là où il faudrait dire « **cette** carte-là ».
///
/// **Le dos est la seule image que le projet ne pointe pas chez sa source, et
/// c'est le calque qui l'impose.** La règle est de pointer l'URL de l'éditeur
/// et de n'en rien garder (§IV.3, §IV.9) — mais le calque est une *browser
/// source* OBS, et une image que son hôte sert sans en-tête CORS s'y fait
/// **bloquer en silence** : pas de code de retour, rien à lire dans le code,
/// il faut le demander à l'hôte, en-tête `Origin` en main. Sur les deux dos
/// publiés par les sources du projet, un seul en envoyait ; et un CDN tiers
/// peut tomber au milieu d'un direct. Les dos vivent donc dans le bucket
/// `card-art`, en `<jeu>/back.jpg`, qui les sert avec CORS à tous — et cette
/// adresse se dérive de `SupabaseConfig.url`, sans rien retenir de tiers.
///
/// **Chaque copie repose sur ce que sa source écrit, et rien d'autre**
/// (§IV.10) : YGOPRODeck *demande* de réhéberger ses images, Scryfall
/// n'interdit que le paywall, le *repackaging* et la déformation. C'est
/// `app.ingestion.card_back_upload` qui verse, et qui **refuse** un jeu dont
/// l'accord n'est pas cité dans sa table — le Dart, lui, ne fait que dire
/// lesquels sont là.
///
/// **Deux jeux sur huit, et c'est une constatation, pas un abandon.** Les six
/// autres sont absents parce qu'**aucune des sources que le projet utilise ne
/// publie leur dos** — vérifié le 2026-09-11, source par source, API, docs et
/// bundles de leurs sites :
///
/// | Jeu | Source | Dos publié |
/// |---|---|---|
/// | Magic | Scryfall | **oui** — `backs.scryfall.io`, 488 × 680 |
/// | Yu-Gi-Oh | YGOPRODeck | **oui** — `images/cards/back.jpg`, 428 × 614 |
/// | Pokémon | TCGdex | non — son schéma d'images est par carte, sans dos commun |
/// | Riftbound | Riftcodex | non — `media.image_url` est par carte ; rien sur les pages publiques de Riot |
/// | One Piece | optcgapi | non — `card_image` est par carte |
/// | Lorcana | Lorcast | non — `image_uris` est par carte |
/// | Star Wars Unlimited | SWU-DB | non — `FrontArt`/`BackArt` sont par carte, le verso des leaders |
/// | Wankul | Wankuldex | non — le droit est acquis, le fichier manque |
///
/// **Deviner une URL serait la faute exacte que ce projet a déjà payée** :
/// aller chercher un fichier au jugé sur le CDN d'un éditeur, c'est au mieux un
/// 404, au pire une ressource qu'on n'a pas le droit de servir. Un jeu dont le
/// dos n'est pas publié garde donc le motif dessiné de `sheet_face.dart` — un
/// repli assumé, pas une panne, et il ne coûte pas un appel. Pour en ajouter
/// un : obtenir le fichier et l'accord écrit de sa source, les inscrire dans la
/// table du module de versement, verser, puis l'ajouter à [hostedCardBacks].
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
import '../../../config/supabase_config.dart';

/// Les jeux dont le dos est dans le bucket — versés et relus avec CORS le
/// 2026-09-11 par `app.ingestion.card_back_upload`.
///
/// **Une liste, et non un appel pour voir.** Demander `<jeu>/back.jpg` pour
/// les huit et laisser le 404 décider coûterait six requêtes par session à
/// notre propre infrastructure pour une réponse connue d'avance ; et la liste
/// dit, à la lecture, ce qui est là.
const Set<Game> hostedCardBacks = {Game.magic, Game.yugioh};

/// Le chemin d'un dos dans le bucket. Jumeau de `back_url`, côté Python :
/// les deux dérivent la même adresse de l'URL du projet, sans se consulter.
///
/// **Sans segment `/normal/`, à dessein** : `previewCardImage` ne tentera pas
/// de lui trouver une vignette qui n'existe pas.
const String _bucketPath = '/storage/v1/object/public/card-art';

/// L'URL du dos d'un jeu, ou `null` s'il n'est pas dans le bucket.
String? cardBackUrl(Game game) => hostedCardBacks.contains(game)
    ? '${SupabaseConfig.url}$_bucketPath/${game.id}/back.jpg'
    : null;

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
